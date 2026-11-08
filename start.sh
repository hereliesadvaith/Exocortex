#!/usr/bin/env bash
# Job tracker: FastAPI (uvicorn) on 127.0.0.1:8004 behind nginx on 127.0.0.1:80,
# so it opens at http://localhost/jobs/ on the phone.
# nginx's localhost site comes from the exocortex repo; this only adds /jobs/ to it.
#   ./start.sh start     start Postgres (if down), the app, and nginx (if down)
#   ./start.sh stop      stop the app (nginx and Postgres keep running for other apps)
#   ./start.sh restart   stop, then start
#   ./start.sh status    show whether each part is up
#   ./start.sh update    git pull --ff-only, reinstall requirements, restart
set -euo pipefail
cd "$(dirname "$0")"

PIDFILE=jobs.pid
LOG=jobs.log
PORT=8004
SNIPPETS=/etc/nginx/localhost.d   # `location` blocks the localhost site includes
APPS=/etc/exocortex/apps          # app.json files the home page lists
export TZ="${TZ:-Asia/Kolkata}"   # proot's Debian runs on UTC; log in local time

app_up() {
  [[ -f $PIDFILE ]] && kill -0 "$(cat $PIDFILE)" 2>/dev/null || return 1
  .venv/bin/python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$PORT/api/state', timeout=3)" 2>/dev/null
}

nginx_up() { [[ -f /run/nginx.pid ]] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; }

# Is there a server that pulls in $SNIPPETS? (The exocortex localhost site does.)
snippets_included() { grep -RqsE "include\s+$SNIPPETS/" /etc/nginx/sites-enabled/ /etc/nginx/conf.d/; }

link_to() { [[ -L $2 && $(readlink -f "$2") == "$1" ]] || ln -sfn "$1" "$2"; }

check_setup() {
  [[ -x .venv/bin/python ]] || { echo "no .venv: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt" >&2; exit 1; }
  [[ -f .env ]] || { echo "no .env: cp .env.example .env, then fill it in" >&2; exit 1; }
  command -v nginx >/dev/null || { echo "nginx isn't installed: apt install -y nginx" >&2; exit 1; }
}

ensure_postgres() {
  # Postgres doesn't come back on its own after a phone restart.
  if ! pg_lsclusters -h 2>/dev/null | grep -q " online"; then
    echo "starting postgres..."
    # Run as postgres: under PRoot every file looks root-owned to root.
    su postgres -c "pg_ctlcluster 17 main start"
  fi
}

start_app() {
  if app_up; then echo "app already running (pid $(cat $PIDFILE))"; return 0; fi
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') starting ($(git rev-parse --short HEAD 2>/dev/null || echo unknown)) =====" >> $LOG
  nohup .venv/bin/python -m uvicorn app:app --host 127.0.0.1 --port $PORT --no-server-header >> $LOG 2>&1 &
  echo $! > $PIDFILE
  for _ in $(seq 20); do
    app_up && return 0
    kill -0 "$(cat $PIDFILE)" 2>/dev/null || break
    sleep 1
  done
  echo "app didn't come up, see $LOG" >&2
  tail -15 $LOG >&2 || true
  stop_app
  return 1
}

stop_app() {
  if [[ -f $PIDFILE ]] && pid=$(cat $PIDFILE) && kill "$pid" 2>/dev/null; then
    for _ in $(seq 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f $PIDFILE
}

start_nginx() {
  mkdir -p $SNIPPETS $APPS
  link_to "$PWD/nginx.conf" $SNIPPETS/jobs.conf
  link_to "$PWD/app.json" $APPS/jobs.json
  if ! snippets_included; then
    echo "warning: no nginx site includes $SNIPPETS/*.conf yet, so /jobs/ isn't served." >&2
    echo "         Start the exocortex server (its start.sh sets up http://localhost/)." >&2
  fi
  nginx -t -q
  if nginx_up; then nginx -s reload; else nginx; fi   # no systemd under PRoot
}

start_all() {
  check_setup
  ensure_postgres
  command -v termux-wake-lock >/dev/null && termux-wake-lock || true
  start_app
  start_nginx
  echo "jobs: http://localhost/jobs/  (logs: tail -f $PWD/$LOG)"
}

case "${1:-}" in
  start)
    start_all
    ;;
  stop)
    stop_app
    echo "jobs stopped"
    ;;
  restart)
    stop_app
    start_all
    ;;
  status)
    app_up && echo "app: up (pid $(cat $PIDFILE), port $PORT)" || echo "app: down"
    nginx_up && echo "nginx: up (pid $(cat /run/nginx.pid))" || echo "nginx: down"
    snippets_included && echo "nginx: serves $SNIPPETS/*.conf" || echo "nginx: no site includes $SNIPPETS/*.conf"
    ;;
  update)
    old=$(git rev-parse HEAD)
    git pull --ff-only
    git diff --quiet "$old" HEAD -- requirements.txt || .venv/bin/pip install -q -r requirements.txt
    stop_app
    start_all
    ;;
  *)
    echo "usage: $0 start|stop|restart|status|update" >&2
    exit 2
    ;;
esac
