#!/usr/bin/env bash
# Set up (or update) the home page: PostgREST, nginx config, the "home" schema, and
# the boot script. Safe to run again; start.sh update runs it when home/ changes.
#   home/install.sh
set -euo pipefail
HOME_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HOME_DIR")
cd "$REPO"

[[ -n ${PREFIX:-} && -d $PREFIX ]] || { echo "run this in Termux (PREFIX isn't set)" >&2; exit 1; }
for cmd in pg_ctl psql nginx curl; do
  command -v $cmd >/dev/null || { echo "missing $cmd: pkg install postgresql nginx curl" >&2; exit 1; }
done
[[ -f $PREFIX/var/lib/postgresql/PG_VERSION ]] || { echo "no Postgres cluster yet: see README (Postgres)" >&2; exit 1; }

log() { echo "== $*"; }

# ---- PL/Python (the schema's functions need it) -----------------------------------
if [[ ! -f $(pg_config --pkglibdir)/plpython3.so ]]; then
  log "PL/Python isn't built yet; building it"
  "$REPO/postgres/plpython/build.sh"
fi

# ---- PostgREST ----------------------------------------------------------------------
PGRST_VERSION=16.5
PGRST_SHA256=96d75a34c7c095d5f97b87f88042f898192724350861328db9e1509e696ea057
if ! postgrest --version 2>/dev/null | grep -q "PostgREST $PGRST_VERSION\$"; then
  log "installing PostgREST $PGRST_VERSION"
  tmp=$(mktemp -d)
  curl -fsSL --retry 5 -o "$tmp/p.tar.xz" \
    "https://github.com/PostgREST/postgrest/releases/download/v$PGRST_VERSION/postgrest-v$PGRST_VERSION-linux-static-aarch64.tar.xz"
  echo "$PGRST_SHA256  $tmp/p.tar.xz" | sha256sum -c --quiet
  tar xJf "$tmp/p.tar.xz" -C "$tmp"
  install -m 755 "$tmp/postgrest" "$PREFIX/bin/postgrest"
  rm -rf "$tmp"
fi

# ---- nginx --------------------------------------------------------------------------
log "nginx config"
NGINX_DIR=$PREFIX/etc/nginx
mkdir -p "$NGINX_DIR/apps.d" "$PREFIX/var/log/nginx"
[[ -f $NGINX_DIR/nginx.conf.orig ]] || cp "$NGINX_DIR/nginx.conf" "$NGINX_DIR/nginx.conf.orig"
sed -e "s|@REPO@|$REPO|g" -e "s|@PREFIX@|$PREFIX|g" "$HOME_DIR/nginx.conf.in" > "$NGINX_DIR/exocortex.conf"
cat > "$NGINX_DIR/nginx.conf" <<EOF
# Written by $REPO/home/install.sh; the site itself is exocortex.conf.
# Termux's original is nginx.conf.orig.
worker_processes 1;
events { worker_connections 256; }
http {
    include mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;
    include exocortex.conf;
}
EOF

# ---- services + schema --------------------------------------------------------------
log "starting Postgres"
bash "$HOME_DIR/services.sh" start-postgres
log "applying home/schema.sql"
PGOPTIONS="-c client_min_messages=warning" psql -U postgres -X -q -v ON_ERROR_STOP=1 -f "$HOME_DIR/schema.sql"
log "restarting PostgREST, reloading nginx"
bash "$HOME_DIR/services.sh" restart-postgrest
bash "$HOME_DIR/services.sh" start

# ---- boot ---------------------------------------------------------------------------
BOOT=$HOME/.termux/boot
mkdir -p "$BOOT"
install -m 700 "$REPO/termux-boot/exocortex" "$BOOT/exocortex"
rm -f "$BOOT/10-services"   # replaced by the exocortex boot script
log "boot script installed at $BOOT/exocortex"

echo
bash "$HOME_DIR/services.sh" status
echo "home page: http://localhost/"
