#!/usr/bin/env bash
# Install (or update) Todos at http://localhost/todos/. Safe to run again.
#   ./install.sh          apply schema.sql, serve public/ through nginx, list it on the home page
#   ./install.sh remove   take it off nginx and the home page (the data stays in schema "todos")
# Needs the exocortex home page set up first (~/exocortex, home/install.sh).
set -euo pipefail
APP=todos
NAME="Todos"
DESCRIPTION="Tasks & lists"
SORT=20   # order of the tiles on the home page
ICON="<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2.4' stroke-linecap='round' stroke-linejoin='round'><path d='M4 6.5l1.6 1.6L8.5 5.2M4 12.5l1.6 1.6 2.9-2.9M4 18.5l1.6 1.6 2.9-2.9M12 6.5h8M12 12.5h8M12 18.5h5'/></svg>"

DIR=$(cd "$(dirname "$0")" && pwd)
EXO=${EXOCORTEX:-$HOME/exocortex}
: "${PREFIX:?run this in Termux}"
NGINX_CONF=$PREFIX/etc/nginx/apps.d/$APP.conf
[[ -x $EXO/home/sync-api.sh || -f $EXO/home/sync-api.sh ]] || {
  echo "needs the exocortex home page first: ~/exocortex, then home/install.sh" >&2; exit 1; }

psql_q() { PGOPTIONS="-c client_min_messages=warning" psql -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

if [[ ${1:-} == remove ]]; then
  psql_q -c "delete from home.apps where id = '$APP'"
  bash "$EXO/home/sync-api.sh"
  rm -f "$NGINX_CONF" && nginx -s reload
  echo "$NAME removed from nginx and the home page; its data is still in schema \"$APP\"."
  exit 0
fi

echo "== schema"
psql_q -f "$DIR/schema.sql"

echo "== nginx: http://localhost/$APP/"
mkdir -p "$(dirname "$NGINX_CONF")"
cat > "$NGINX_CONF" <<EOF
# Written by $DIR/install.sh
location = /$APP { return 301 /$APP/; }
location /$APP/ {
    alias $DIR/public/;
    index index.html;
    add_header Cache-Control "no-cache";
}
EOF
nginx -t -q
nginx -s reload

echo "== home page"
psql_q -v id="$APP" -v sort="$SORT" -v name="$NAME" -v description="$DESCRIPTION" -v icon="$ICON" <<'SQL'
insert into home.apps (id, name, description, path, health_url, icon, api_schema, sort)
values (:'id', :'name', :'description', '/' || :'id' || '/', 'http://127.0.0.1/' || :'id' || '/', :'icon', :'id', :sort)
on conflict (id) do update set name = excluded.name, description = excluded.description, path = excluded.path,
  health_url = excluded.health_url, icon = excluded.icon, api_schema = excluded.api_schema, sort = excluded.sort;
SQL
bash "$EXO/home/sync-api.sh"

# Check it end to end: the page through nginx, and the API with this app's profile.
sleep 1
page=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost/$APP/")
api=$(curl -s -o /dev/null -w '%{http_code}' -H "Accept-Profile: $APP" "http://localhost/api/rpc/state")
echo "page $page, api $api"
[[ $page == 200 && $api == 200 ]] || { echo "something isn't answering; see home/services.sh status" >&2; exit 1; }
echo "$NAME: http://localhost/$APP/"
