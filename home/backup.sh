#!/usr/bin/env bash
# Postgres backup: a full pg_dumpall (every database, and the roles), gzipped, into
# $BACKUP_DIR, keeping the newest $BACKUP_KEEP. If BACKUP_REMOTE is set in .env, the
# dumps are also copied there with rclone.
#   home/backup.sh
# cron runs it every night at 05:00 (home/install.sh adds the crontab line); output
# goes to home/backup.log. The dumps contain role password hashes: they're written
# readable by the Termux user only, and the remote gets them as they are.
#
# Restore: zcat <dump> | psql -U postgres -X -f - postgres
set -euo pipefail
HOME_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HOME_DIR")
: "${PREFIX:=/data/data/com.termux/files/usr}"
export PATH=$PREFIX/bin:$PATH   # cron's PATH doesn't always have it

if [[ -f $REPO/.env ]]; then set -a; source "$REPO/.env"; set +a; fi
DIR=${BACKUP_DIR:-$HOME/backups/postgres}
KEEP=${BACKUP_KEEP:-7}
REMOTE=${BACKUP_REMOTE:-}

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

umask 077
mkdir -p "$DIR" || { log "FAILED: cannot create $DIR"; exit 1; }
out=$DIR/postgres-all-$(date +%Y-%m-%d-%H%M).sql.gz
tmp=$out.tmp
trap 'rm -f "$tmp"' EXIT

# ---- dump -------------------------------------------------------------------------
# Check the dump before it counts: a truncated one would otherwise push a good one out.
if ! pg_dumpall -U postgres | gzip -9 > "$tmp"; then log "FAILED: pg_dumpall"; exit 1; fi
if ! gzip -t "$tmp"; then log "FAILED: the archive is corrupt"; exit 1; fi
if ! zcat "$tmp" | tail -5 | grep -q 'database cluster dump complete'; then
  log "FAILED: the dump is incomplete"; exit 1
fi
mv "$tmp" "$out"
log "ok: $(basename "$out") ($(stat -c %s "$out") bytes)"

# Old dumps go only now, after a good new one, so a failing backup never eats them.
ls -1 "$DIR"/postgres-all-*.sql.gz | sort -r | tail -n +$((KEEP + 1)) | while read -r old; do
  rm -f "$old"; log "removed old: $(basename "$old")"
done

# ---- copy off the phone -----------------------------------------------------------
# A failed upload doesn't fail the backup: the local dump is safe, and the next run
# uploads whatever is missing. Remote dumps are removed by age, not mirrored, so a
# wiped or broken phone can't empty the remote. Google Drive sometimes answers very
# slowly, hence the time limits.
[[ -n $REMOTE ]] || exit 0
command -v rclone >/dev/null || { log "UPLOAD FAILED: BACKUP_REMOTE is set but rclone isn't installed"; exit 0; }
if timeout 900 rclone copy "$DIR" "$REMOTE" --include 'postgres-all-*.sql.gz' -q --retries 3 2>&1; then
  log "uploaded to $REMOTE"
  timeout 300 rclone delete "$REMOTE" --include 'postgres-all-*.sql.gz' --min-age "${KEEP}d" -q 2>&1 \
    || log "WARNING: couldn't remove old dumps from $REMOTE"
else
  log "UPLOAD FAILED: $REMOTE (the local dump is fine)"
fi
