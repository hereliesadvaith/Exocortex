#!/usr/bin/env bash
# Start the exocortex FastMCP server with its ngrok tunnel.
#   ./start.sh       run in the foreground (Ctrl+C to stop)
#   ./start.sh -d    run in the background, logging to server.log
#   ./start.sh stop  stop a background instance
set -euo pipefail
cd "$(dirname "$0")"

PIDFILE=server.pid

if [[ "${1:-}" == "stop" ]]; then
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
  exit 0
fi

if [[ -f $PIDFILE ]] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
  echo "already running (pid $(cat $PIDFILE)); use ./start.sh stop first" >&2
  exit 1
fi

# Postgres doesn't come back on its own after a phone restart.
if ! pg_lsclusters -h 2>/dev/null | grep -q " online"; then
  echo "starting postgres..."
  pg_ctlcluster 17 main start
fi

# Keep Android from killing us when the screen is off (only exists in Termux).
command -v termux-wake-lock >/dev/null && termux-wake-lock || true

if [[ "${1:-}" == "-d" ]]; then
  nohup .venv/bin/python server.py > server.log 2>&1 &
  echo $! > $PIDFILE
  for _ in $(seq 30); do
    grep -q "ngrok tunnel:" server.log 2>/dev/null && break
    kill -0 "$(cat $PIDFILE)" 2>/dev/null || { echo "server exited, see server.log" >&2; tail -5 server.log; exit 1; }
    sleep 1
  done
  grep "ngrok tunnel:" server.log || echo "started (pid $!), tunnel not up yet; check server.log"
  echo "running in background (pid $!). logs: tail -f server.log  stop: ./start.sh stop"
else
  exec .venv/bin/python server.py
fi
