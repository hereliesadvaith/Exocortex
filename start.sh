#!/usr/bin/env bash
# Start the exocortex FastMCP server with its ngrok tunnel.
#   ./start.sh          run in the foreground (Ctrl+C to stop)
#   ./start.sh -d       run in the background, appending to server.log (rotated at 1 MB)
#   ./start.sh stop     stop a background instance
#   ./start.sh restart  stop, then start in the background and wait until it answers
#   ./start.sh update   git pull --ff-only, then restart; rolls back if the new code
#                       doesn't come up. Logs to update.log when run by the MCP tool.
set -euo pipefail
cd "$(dirname "$0")"

PIDFILE=server.pid
PORT="${MCP_PORT:-$(grep -E '^MCP_PORT=' .env 2>/dev/null | cut -d= -f2 || true)}"
PORT="${PORT:-8000}"

# proot's Debian runs on UTC; show log timestamps in local time. Override with TZ=... ./start.sh
export TZ="${TZ:-Asia/Kolkata}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

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

  if ! sync_deps "$old" "$new" || ! .venv/bin/python -m py_compile server.py; then
    # The running server is untouched; just put the code back.
    log "new code failed to install or compile; resetting to ${old:0:7}, server not restarted" >&2
    git reset --hard "$old"
    sync_deps "$new" "$old" || true
    return 1
  fi

  stop_server
  if start_background; then
    log "update ok: now at ${new:0:7}"
    return 0
  fi

  log "rolling back to ${old:0:7}" >&2
  git reset --hard "$old"
  sync_deps "$new" "$old" || true
  if start_background; then
    log "rolled back; running ${old:0:7}"
  else
    log "ROLLBACK FAILED: server is down, fix it on the phone" >&2
  fi
  return 1
}

case "${1:-}" in
  stop)
    stop_server
    exit 0
    ;;
  restart)
    stop_server
    ensure_postgres
    start_background
    exit $?
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
  start_background
else
  exec .venv/bin/python server.py
fi
