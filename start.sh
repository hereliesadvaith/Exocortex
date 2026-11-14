#!/usr/bin/env bash
# Start the exocortex MCP server (server.py on 127.0.0.1:$MCP_PORT) and the ngrok
# agent that publishes it at https://$NGROK_DOMAIN.
#   ./start.sh          ngrok in the background, server in the foreground (Ctrl+C stops the server)
#   ./start.sh -d       both in the background, logging to server.log and ngrok.log
#   ./start.sh stop     stop both
#   ./start.sh restart  stop, then start both in the background
#   ./start.sh status   show whether each is up
#   ./start.sh update   git pull --ff-only, then restart the server; rolls back if the
#                       new code doesn't come up. Logs to update.log when run by the MCP tool.
set -euo pipefail
cd "$(dirname "$0")"

[[ -f .env ]] || { echo "no .env: cp .env.example .env, fill it in, chmod 600 .env" >&2; exit 1; }
set -a; source ./.env; set +a

PORT="${MCP_PORT:-8000}"
PYTHON=.venv/bin/python; [[ -x $PYTHON ]] || PYTHON=python3
NGROK_BIN="${NGROK_BIN:-ngrok}"
NGROK_API=127.0.0.1:4040   # the agent's local status API

LOG_MAX_BYTES=$((1024 * 1024))
LOG_KEEP=3

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# Keep a log across restarts; once it passes LOG_MAX_BYTES, shift it to .1
# (older ones to .2 .. .LOG_KEEP, the oldest is dropped).
rotate_log() {
  local f=$1
  [[ -f $f && $(stat -c %s "$f") -ge $LOG_MAX_BYTES ]] || return 0
  for ((i = LOG_KEEP - 1; i >= 1; i--)); do
    [[ -f $f.$i ]] && mv -f "$f.$i" "$f.$((i + 1))"
  done
  mv -f "$f" "$f.1"
}

alive() { [[ -f $1 ]] && kill -0 "$(cat "$1")" 2>/dev/null; }

stop_pid() {  # stop_pid <pidfile> <name>
  local pidfile=$1 name=$2 pid
  if [[ -f $pidfile ]] && pid=$(cat "$pidfile") && kill "$pid" 2>/dev/null; then
    # Wait for it to actually exit so a quick restart doesn't hit a busy port.
    for _ in $(seq 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    if kill -0 "$pid" 2>/dev/null; then
      echo "$name (pid $pid) didn't exit after 10s, sending SIGKILL" >&2
      kill -9 "$pid" 2>/dev/null || true
    fi
    echo "$name stopped (pid $pid)"
  else
    echo "$name not running"
  fi
  rm -f "$pidfile"
}

# ---- MCP server ---------------------------------------------------------------

# True once the server process is alive and answers HTTP on its port (any status, e.g. 401).
server_up() {
  alive server.pid || return 1
  "$PYTHON" - "$PORT" <<'EOF' 2>/dev/null
import sys, urllib.request, urllib.error
try:
    urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/mcp", timeout=3)
except urllib.error.HTTPError:
    pass  # any HTTP answer means the server is up
except Exception:
    sys.exit(1)
EOF
}

start_server() {
  rotate_log server.log
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') starting server ($(git rev-parse --short HEAD 2>/dev/null || echo unknown)) =====" >> server.log
  nohup "$PYTHON" server.py >> server.log 2>&1 &
  echo $! > server.pid
  for _ in $(seq 30); do
    if server_up; then
      echo "server running (pid $(cat server.pid), port $PORT). logs: tail -f server.log"
      return 0
    fi
    alive server.pid || break
    sleep 1
  done
  echo "server didn't come up, see server.log" >&2
  tail -20 server.log >&2 || true
  stop_pid server.pid server >/dev/null
  return 1
}

# ---- ngrok agent --------------------------------------------------------------

# Prints the public URL once the agent's tunnel is online.
ngrok_url() {
  alive ngrok.pid || return 1
  "$PYTHON" - "$NGROK_API" <<'EOF' 2>/dev/null
import json, sys, urllib.request
tunnels = json.load(urllib.request.urlopen(f"http://{sys.argv[1]}/api/tunnels", timeout=3))["tunnels"]
if not tunnels:
    sys.exit(1)
print(tunnels[0]["public_url"])
EOF
}

start_ngrok() {
  if ngrok_url >/dev/null; then return 0; fi
  stop_pid ngrok.pid ngrok >/dev/null
  if [[ -z ${NGROK_AUTHTOKEN:-} || -z ${NGROK_DOMAIN:-} ]]; then
    echo "NGROK_AUTHTOKEN or NGROK_DOMAIN not set in .env; not starting ngrok" >&2
    return 1
  fi
  command -v "$NGROK_BIN" >/dev/null || { echo "ngrok not found ($NGROK_BIN); see README" >&2; return 1; }
  rotate_log ngrok.log
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') starting ngrok =====" >> ngrok.log
  # NGROK_AUTHTOKEN is read from the environment.
  nohup "$NGROK_BIN" http "127.0.0.1:$PORT" --url "https://$NGROK_DOMAIN" \
    --log stdout --log-format logfmt >> ngrok.log 2>&1 &
  echo $! > ngrok.pid
  local url
  for _ in $(seq 20); do
    if url=$(ngrok_url); then
      echo "ngrok tunnel: $url -> 127.0.0.1:$PORT"
      return 0
    fi
    alive ngrok.pid || break
    sleep 1
  done
  echo "ngrok didn't come up, see ngrok.log" >&2
  tail -10 ngrok.log >&2 || true
  stop_pid ngrok.pid ngrok >/dev/null
  return 1
}

# ---- update -------------------------------------------------------------------

# Install dependencies if requirements.txt changed between two commits.
sync_deps() {
  if ! git diff --quiet "$1" "$2" -- requirements.txt; then
    log "requirements.txt changed, installing"
    "$PYTHON" -m pip install -q -r requirements.txt
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
  if ! git pull --ff-only; then
    log "git pull failed; server not restarted" >&2
    return 1
  fi
  new=$(git rev-parse HEAD)
  if [[ $old == "$new" && "${FORCE_RESTART:-}" != 1 ]]; then
    log "already up to date, not restarting"
    return 0
  fi
  [[ $old != "$new" ]] && git log --oneline "$old..$new"

  if ! sync_deps "$old" "$new" || ! "$PYTHON" -m py_compile server.py; then
    # The running server is untouched; just put the code back.
    log "new code failed to install or compile; resetting to ${old:0:7}, server not restarted" >&2
    git reset --hard "$old"
    sync_deps "$new" "$old" || true
    return 1
  fi

  # ngrok keeps running; only the server restarts.
  stop_pid server.pid server
  if start_server; then
    start_ngrok || true
    log "update ok: now at ${new:0:7}"
    return 0
  fi

  log "rolling back to ${old:0:7}" >&2
  git reset --hard "$old"
  sync_deps "$new" "$old" || true
  if start_server; then
    start_ngrok || true
    log "rolled back; running ${old:0:7}"
  else
    log "ROLLBACK FAILED: server is down, fix it on the phone" >&2
  fi
  return 1
}

# ---- commands -----------------------------------------------------------------

# Keep Android from killing us when the screen is off (Termux only).
wake_lock() { command -v termux-wake-lock >/dev/null && termux-wake-lock || true; }

case "${1:-}" in
  stop)
    stop_pid server.pid server
    stop_pid ngrok.pid ngrok
    ;;
  restart)
    stop_pid server.pid server
    stop_pid ngrok.pid ngrok
    wake_lock
    start_server
    start_ngrok
    ;;
  status)
    server_up && echo "server: up (pid $(cat server.pid), port $PORT)" || echo "server: down"
    if url=$(ngrok_url); then echo "ngrok: up (pid $(cat ngrok.pid)) $url"; else echo "ngrok: down"; fi
    ;;
  update)
    update
    ;;
  -d|"")
    if alive server.pid; then
      echo "server already running (pid $(cat server.pid)); use ./start.sh restart" >&2
      start_ngrok || true
      exit 1
    fi
    wake_lock
    if [[ ${1:-} == -d ]]; then
      start_server
      start_ngrok
    else
      start_ngrok || true
      exec "$PYTHON" server.py
    fi
    ;;
  *)
    echo "usage: $0 [-d|stop|restart|status|update]" >&2
    exit 2
    ;;
esac
