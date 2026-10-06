#!/usr/bin/env bash
# Restore a pg_backup.sh dump into a NEW database on the accessory container.
#
#   script/backup/pg_restore.sh [--replace-scratch] DUMP_FILE NEW_DATABASE
#
# It never writes to the live database. The dump is restored with --single-transaction
# into NEW_DATABASE, which must not exist (a failed restore leaves nothing behind).
# --replace-scratch drops and recreates NEW_DATABASE if it already exists; use it only
# for a drill database such as restore_test. Putting the restored copy into service is
# a separate, manual step (stop the app, rename the databases, start it): see "Restore
# over the live database" in docs/deploy/RUNBOOK.md.
#
# Overridable via environment: PG_CONTAINER (whatsapp-integration-db),
# PG_USER (whatsapp_integration), LIVE_DATABASE (whatsapp_integration_production).
set -euo pipefail

PG_CONTAINER="${PG_CONTAINER:-whatsapp-integration-db}"
PG_USER="${PG_USER:-whatsapp_integration}"
LIVE_DATABASE="${LIVE_DATABASE:-whatsapp_integration_production}"

log() { printf '%s pg_restore: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

replace_scratch=0
args=()
for arg in "$@"; do
  case "$arg" in
    --replace-scratch) replace_scratch=1 ;;
    --force-live) die "--force-live no longer exists: nothing restores over the live database in place. Restore into a new database, then swap by hand (docs/deploy/RUNBOOK.md, 'Restore over the live database')" ;;
    -h|--help) usage ;;
    -*) die "unknown option $arg" ;;
    *) args+=("$arg") ;;
  esac
done
[[ ${#args[@]} -eq 2 ]] || usage
dump="${args[0]}"
target="${args[1]}"

[[ -f "$dump" && -s "$dump" ]] || die "dump file not found or empty: $dump"
[[ "$target" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "invalid database name: $target"
[[ "$target" != "$LIVE_DATABASE" ]] \
  || die "$target is the live database; restore into a NEW name (for example ${LIVE_DATABASE}_restored) and swap by hand, see docs/deploy/RUNBOOK.md"
case "$target" in
  postgres|template0|template1) die "refusing to restore into system database $target" ;;
esac
[[ "$(docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null)" == "true" ]] \
  || die "container $PG_CONTAINER is not running"

psql_in() { docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d postgres -v ON_ERROR_STOP=1 -qAt "$@"; }

created=0
finished=0
cleanup() {
  if [[ $created -eq 1 && $finished -ne 1 ]]; then
    log "restore did not finish; dropping the incomplete database $target"
    psql_in -c "DROP DATABASE IF EXISTS \"$target\"" || log "WARNING: could not drop $target; remove it by hand"
  fi
}
trap cleanup EXIT

exists="$(psql_in -c "SELECT 1 FROM pg_database WHERE datname = '$target'")"
if [[ "$exists" == "1" ]]; then
  [[ $replace_scratch -eq 1 ]] || die "database $target already exists; pick a new name, or pass --replace-scratch if it is a scratch database"
  log "dropping existing scratch database $target"
  psql_in -c "DROP DATABASE \"$target\""
fi

log "creating database $target"
psql_in -c "CREATE DATABASE \"$target\" OWNER \"$PG_USER\""
created=1

log "restoring $dump into $target (single transaction)"
docker exec -i "$PG_CONTAINER" pg_restore -U "$PG_USER" -d "$target" \
  --single-transaction --no-owner --exit-on-error < "$dump"

tables="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$target" -qAt \
  -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")"
version="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$target" -qAt \
  -c "SELECT max(version) FROM schema_migrations")"
finished=1
log "restored into $target: $tables public tables, latest migration $version"
log "the live database $LIVE_DATABASE was not touched; to put $target into service follow docs/deploy/RUNBOOK.md"
