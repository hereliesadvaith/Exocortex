#!/usr/bin/env bash
# Postgres, nginx and PostgREST: the services behind the home page.
#   home/services.sh start     start whichever aren't running (safe to repeat)
#   home/services.sh stop      stop PostgREST and nginx, then Postgres
#   home/services.sh restart   stop, then start
#   home/services.sh status    one line each
# Logs: $PREFIX/var/log/postgresql.log, $PREFIX/var/log/nginx/, home/postgrest.log
set -uo pipefail
HOME_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$HOME_DIR"

: "${PREFIX:=/data/data/com.termux/files/usr}"
PGDATA=$PREFIX/var/lib/postgresql
PGLOG=$PREFIX/var/log/postgresql.log
NGINX_PID=$PREFIX/tmp/nginx.pid
PGRST_PID=$HOME_DIR/postgrest.pid
PGRST_LOG=$HOME_DIR/postgrest.log
PGRST_PORT=3000

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# True if the pid in $1 is alive and its command line contains $2 (PIDs get reused
# after a reboot, so a live pid alone proves nothing).
pid_is() {
  local pid
  pid=$(head -1 "$1" 2>/dev/null) || return 1
  [[ -n $pid ]] && grep -qa "$2" "/proc/$pid/cmdline" 2>/dev/null
}

rotate() {  # rotate <file>: keep .1-.3 once it passes 1 MB
  [[ -f $1 && $(stat -c %s "$1") -ge 1048576 ]] || return 0
  for i in 2 1; do [[ -f $1.$i ]] && mv -f "$1.$i" "$1.$((i + 1))"; done
  mv -f "$1" "$1.1"
}

# ---- Postgres -------------------------------------------------------------------
pg_up() { pg_ctl -D "$PGDATA" status >/dev/null 2>&1; }

pg_start() {
  if pg_up; then echo "postgres: already running"; return 0; fi
  # After an unclean shutdown postmaster.pid can name a PID another process now has,
  # and Postgres then refuses to start. Drop it if that PID isn't Postgres.
  if [[ -f $PGDATA/postmaster.pid ]] && ! pid_is "$PGDATA/postmaster.pid" postgres; then
    rm -f "$PGDATA/postmaster.pid" && echo "postgres: removed stale postmaster.pid"
  fi
  rotate "$PGLOG"
  pg_ctl -D "$PGDATA" -l "$PGLOG" -w start >/dev/null && echo "postgres: started"
}

pg_stop() { pg_up && pg_ctl -D "$PGDATA" -m fast -w stop >/dev/null && echo "postgres: stopped"; return 0; }

# ---- nginx ----------------------------------------------------------------------
nginx_up() { pid_is "$NGINX_PID" nginx; }

nginx_start() {
  if ! nginx -t -q; then echo "nginx: config test failed, see: nginx -t" >&2; return 1; fi
  if nginx_up; then nginx -s reload && echo "nginx: reloaded"; else nginx && echo "nginx: started"; fi
}

nginx_stop() { nginx_up && nginx -s quit && echo "nginx: stopped"; return 0; }

# ---- PostgREST ------------------------------------------------------------------
pgrst_up() { pid_is "$PGRST_PID" postgrest; }

pgrst_start() {
  if pgrst_up; then echo "postgrest: already running"; return 0; fi
  command -v postgrest >/dev/null || { echo "postgrest isn't installed: run home/install.sh" >&2; return 1; }
  rotate "$PGRST_LOG"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') starting postgrest =====" >> "$PGRST_LOG"
  # Logs in over the local socket as home_api (trust auth: only Termux can reach the
  # socket) and serves schema "home" as role home_web.
  PGRST_DB_URI="postgres://home_api@/postgres?host=$PREFIX/tmp" \
  PGRST_DB_SCHEMAS=home \
  PGRST_DB_ANON_ROLE=home_web \
  PGRST_DB_POOL=4 \
  PGRST_SERVER_HOST=127.0.0.1 \
  PGRST_SERVER_PORT=$PGRST_PORT \
  PGRST_SERVER_CORS_ALLOWED_ORIGINS="http://localhost:8080,http://127.0.0.1:8080" \
  PGRST_OPENAPI_MODE=disabled \
  PGRST_LOG_LEVEL=warn \
    nohup postgrest >> "$PGRST_LOG" 2>&1 < /dev/null &
  echo $! > "$PGRST_PID"
  for _ in $(seq 15); do
    if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PGRST_PORT/apps"; then
      echo "postgrest: started"
      return 0
    fi
    pgrst_up || break
    sleep 1
  done
  echo "postgrest: didn't come up, see $PGRST_LOG" >&2
  tail -5 "$PGRST_LOG" >&2
  return 1
}

pgrst_stop() {
  if pgrst_up; then
    local pid; pid=$(cat "$PGRST_PID")
    kill "$pid"
    for _ in $(seq 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$pid" 2>/dev/null
    echo "postgrest: stopped"
  fi
  rm -f "$PGRST_PID"
}

# ---- commands -------------------------------------------------------------------
start_all() {
  local rc=0
  pg_start || rc=1
  pgrst_start || rc=1   # needs Postgres
  nginx_start || rc=1
  return $rc
}

stop_all() {
  pgrst_stop
  nginx_stop
  pg_stop
}

case "${1:-}" in
  start) start_all ;;
  stop) stop_all ;;
  restart) stop_all; start_all ;;
  status)
    pg_up && echo "postgres: up" || echo "postgres: down"
    pgrst_up && echo "postgrest: up (pid $(cat "$PGRST_PID"))" || echo "postgrest: down"
    nginx_up && echo "nginx: up (pid $(cat "$NGINX_PID")) http://localhost:8080/" || echo "nginx: down"
    ;;
  start-postgres) pg_start ;;
  restart-postgrest) pgrst_stop; pgrst_start ;;
  *) echo "usage: $0 start|stop|restart|status|start-postgres|restart-postgrest" >&2; exit 2 ;;
esac
