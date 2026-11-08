#!/usr/bin/env bash
# Start the exocortex FastMCP server with its ngrok tunnel, plus the home page
# (home/app.py on 127.0.0.1:8003) and nginx in front of it at http://localhost/.
#   ./start.sh          run the MCP server in the foreground (Ctrl+C to stop)
#   ./start.sh -d       run in the background, appending to server.log (rotated at 1 MB)
#   ./start.sh stop     stop the MCP server and the home page (nginx keeps serving the apps)
#   ./start.sh restart  stop, then start in the background and wait until it answers
#   ./start.sh update   git pull --ff-only, then restart; rolls back if the new code
#                       doesn't come up. Logs to update.log when run by the MCP tool.
#   ./start.sh status   show whether each part is up
set -euo pipefail
cd "$(dirname "$0")"

PIDFILE=server.pid
PORT="${MCP_PORT:-$(grep -E '^MCP_PORT=' .env 2>/dev/null | cut -d= -f2 || true)}"
PORT="${PORT:-8000}"

# proot's Debian runs on UTC; show log timestamps in local time. Override with TZ=... ./start.sh
export TZ="${TZ:-Asia/Kolkata}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

HOME_PIDFILE=home/home.pid
HOME_LOG=home/home.log
HOME_PORT="${HOME_PORT:-$(grep -E '^HOME_PORT=' .env 2>/dev/null | cut -d= -f2 || true)}"
HOME_PORT="${HOME_PORT:-8003}"
NGINX_SITE=/etc/nginx/sites-enabled/exocortex
SNIPPETS=/etc/nginx/localhost.d   # each app's `location` blocks for http://localhost/<app>/
APPS=/etc/exocortex/apps          # each app's app.json, for the home page

stop_server() {
  if [[ -f $PIDFILE ]] && pid=$(cat $PIDFILE) && kill "$pid" 2>/dev/null; then
    # Wait for it to actually exit so a quick restart doesn't hit a busy port.
    for _ in $(seq 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    if kill -0 "$pid" 2>/dev/null; then
      echo "pid $pid didn't exit after 10s, sending SIGKILL" >&2
      kill -9 "$pid" 2>/dev/null || true
    fi
    echo "stopped (pid $pid)"
  else
    echo "not running"
  fi
  rm -f $PIDFILE
}

ensure_postgres() {
  # Postgres doesn't come back on its own after a phone restart.
  if ! pg_lsclusters -h 2>/dev/null | grep -q " online"; then
    echo "starting postgres..."
    # Run as postgres: under PRoot every file looks root-owned to root, and chown is a no-op.
    su postgres -c "pg_ctlcluster 17 main start"
  fi
}

# True once the server process is alive and answers HTTP on its port (any status, e.g. 401).
healthy() {
  [[ -f $PIDFILE ]] && kill -0 "$(cat $PIDFILE)" 2>/dev/null || return 1
  .venv/bin/python - "$PORT" <<'EOF' 2>/dev/null
import sys, urllib.request, urllib.error
try:
    urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/mcp", timeout=3)
except urllib.error.HTTPError:
    pass  # any HTTP answer means the server is up
except Exception:
    sys.exit(1)
EOF
}

# ---- home page and nginx ----------------------------------------------------
# These sit beside the MCP server: if they fail, the MCP server still runs.

home_healthy() {
  [[ -f $HOME_PIDFILE ]] && kill -0 "$(cat $HOME_PIDFILE)" 2>/dev/null || return 1
  .venv/bin/python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$HOME_PORT/', timeout=3)" 2>/dev/null
}

stop_home() {
  if [[ -f $HOME_PIDFILE ]] && pid=$(cat $HOME_PIDFILE) && kill "$pid" 2>/dev/null; then
    for _ in $(seq 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f $HOME_PIDFILE
}

start_home() {
  if home_healthy; then return 0; fi
  stop_home
  [[ -f $HOME_LOG && $(stat -c %s $HOME_LOG) -ge $((1024 * 1024)) ]] && mv -f $HOME_LOG $HOME_LOG.1
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') starting home ($(git rev-parse --short HEAD 2>/dev/null || echo unknown)) =====" >> $HOME_LOG
  nohup .venv/bin/python -m uvicorn home.app:app --host 127.0.0.1 --port "$HOME_PORT" \
    --no-server-header --no-access-log >> $HOME_LOG 2>&1 &
  echo $! > $HOME_PIDFILE
  for _ in $(seq 15); do
    home_healthy && { echo "home page: http://localhost/"; return 0; }
    kill -0 "$(cat $HOME_PIDFILE)" 2>/dev/null || break
    sleep 1
  done
  echo "home page didn't come up, see $HOME_LOG" >&2
  tail -10 $HOME_LOG >&2 || true
  stop_home
  return 1
}

nginx_up() { [[ -f /run/nginx.pid ]] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; }

# nginx's one server on 127.0.0.1:80 lives here (nginx/localhost.conf); apps only add
# their own files to $SNIPPETS and $APPS.
start_nginx() {
  command -v nginx >/dev/null || { echo "nginx isn't installed (apt install -y nginx); skipping the home page proxy" >&2; return 1; }
  mkdir -p $SNIPPETS $APPS
  if [[ ! -L $NGINX_SITE || $(readlink -f $NGINX_SITE) != "$PWD/nginx/localhost.conf" ]]; then
    ln -sfn "$PWD/nginx/localhost.conf" $NGINX_SITE
  fi
  # Debian's default site and the old habits site also wanted port 80.
  rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/habits
  if ! nginx -t -q; then
    echo "nginx config test failed; nginx left as it was" >&2
    return 1
  fi
  if nginx_up; then nginx -s reload; else nginx; fi   # no systemd under PRoot
}

# Home page and nginx, after the MCP server.
start_front() {
  start_home || true
  start_nginx || true
}

LOG=server.log
LOG_MAX_BYTES=$((1024 * 1024))
LOG_KEEP=3

# Keep server.log across restarts; once it passes LOG_MAX_BYTES, shift it to
# server.log.1 (older ones to .2 .. .LOG_KEEP, the oldest is dropped).
rotate_log() {
  [[ -f $LOG && $(stat -c %s $LOG) -ge $LOG_MAX_BYTES ]] || return 0
  for ((i = LOG_KEEP - 1; i >= 1; i--)); do
    [[ -f $LOG.$i ]] && mv -f "$LOG.$i" "$LOG.$((i + 1))"
  done
  mv -f $LOG $LOG.1
}

start_background() {
  rotate_log
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') starting server ($(git rev-parse --short HEAD 2>/dev/null || echo unknown)) =====" >> $LOG
  nohup .venv/bin/python server.py >> $LOG 2>&1 &
  echo $! > $PIDFILE
  for _ in $(seq 30); do
    if healthy; then
      grep "ngrok tunnel:" $LOG | tail -1 || true
      echo "running in background (pid $(cat $PIDFILE)). logs: tail -f server.log  stop: ./start.sh stop"
      return 0
    fi
    kill -0 "$(cat $PIDFILE)" 2>/dev/null || break
    sleep 1
  done
  echo "server didn't come up, see server.log" >&2
  tail -20 $LOG >&2 || true
  stop_server >/dev/null
  return 1
}

# Install dependencies if requirements.txt changed between two commits.
sync_deps() {
  if ! git diff --quiet "$1" "$2" -- requirements.txt; then
    log "requirements.txt changed, installing"
    .venv/bin/pip install -q -r requirements.txt
  fi
}

update() {
  if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
    log "refusing to update: uncommitted changes in tracked files" >&2
    git status --short --untracked-files=no >&2
    return 1
  fi
  local old new
  old=$(git rev-parse HEAD)
  log "pulling $(git rev-parse --abbrev-ref HEAD) (at ${old:0:7})"
  git pull --ff-only
  new=$(git rev-parse HEAD)
  if [[ $old == "$new" && "${FORCE_RESTART:-}" != 1 ]]; then
    log "already up to date, not restarting"
    return 0
  fi
  [[ $old != "$new" ]] && git log --oneline "$old..$new"

  if ! sync_deps "$old" "$new" || ! .venv/bin/python -m py_compile server.py home/app.py; then
    # The running server is untouched; just put the code back.
    log "new code failed to install or compile; resetting to ${old:0:7}, server not restarted" >&2
    git reset --hard "$old"
    sync_deps "$new" "$old" || true
    return 1
  fi

  stop_server
  stop_home
  if start_background; then
    start_front
    log "update ok: now at ${new:0:7}"
    return 0
  fi

  log "rolling back to ${old:0:7}" >&2
  git reset --hard "$old"
  sync_deps "$new" "$old" || true
  if start_background; then
    start_front
    log "rolled back; running ${old:0:7}"
  else
    log "ROLLBACK FAILED: server is down, fix it on the phone" >&2
  fi
  return 1
}

case "${1:-}" in
  stop)
    stop_server
    stop_home
    exit 0
    ;;
  restart)
    stop_server
    stop_home
    ensure_postgres
    start_background || exit 1
    start_front
    exit 0
    ;;
  status)
    healthy && echo "mcp server: up (pid $(cat $PIDFILE), port $PORT)" || echo "mcp server: down"
    grep "ngrok tunnel:" $LOG 2>/dev/null | tail -1 | sed 's/^/  /' || true
    home_healthy && echo "home page: up (pid $(cat $HOME_PIDFILE), port $HOME_PORT)" || echo "home page: down"
    nginx_up && echo "nginx: up (pid $(cat /run/nginx.pid))" || echo "nginx: down"
    pg_lsclusters -h 2>/dev/null | grep -q " online" && echo "postgres: up" || echo "postgres: down"
    for f in "$APPS"/*.json; do [[ -e $f ]] && echo "app: $(basename "$f" .json) -> $(readlink -f "$f")"; done
    exit 0
    ;;
  update)
    ensure_postgres
    update
    exit $?
    ;;
esac

if [[ -f $PIDFILE ]] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
  echo "already running (pid $(cat $PIDFILE)); use ./start.sh stop first" >&2
  exit 1
fi

ensure_postgres

# Keep Android from killing us when the screen is off (only exists in Termux).
command -v termux-wake-lock >/dev/null && termux-wake-lock || true

if [[ "${1:-}" == "-d" ]]; then
  start_background || exit 1
  start_front
else
  start_front
  exec .venv/bin/python server.py
fi
