#!/usr/bin/env bash
# Point PostgREST at "home" plus every app schema registered in home.apps, then
# reload its schema cache. App installers run this after adding or removing their
# row in home.apps:
#   bash ~/exocortex/home/sync-api.sh
set -euo pipefail
schemas=$(psql -U postgres -X -q -At -c "select home.sync_api_schemas()")
# The config reload has to land before the schema reload, or the cache misses the
# new schemas.
sleep 1
psql -U postgres -X -q -c "notify pgrst, 'reload schema'"
echo "PostgREST schemas: $schemas"
