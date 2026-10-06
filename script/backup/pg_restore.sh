#!/usr/bin/env bash
# Restore a pg_backup.sh dump into a named database on the accessory container.
#
#   script/backup/pg_restore.sh DUMP_FILE TARGET_DB
#   script/backup/pg_restore.sh --force-live [--yes] DUMP_FILE whatsapp_integration_production
#
# A scratch TARGET_DB is dropped and recreated, so the drill never touches live data.
# The live database is refused unless --force-live is given; stop the app first
# (`kamal app stop`) and start it again afterwards (`kamal app boot`).
#
# Overridable via environment: PG_CONTAINER (whatsapp-integration-db),
# PG_USER (whatsapp_integration), LIVE_DATABASE (whatsapp_integration_production).
set -euo pipefail

PG_CONTAINER="${PG_CONTAINER:-whatsapp-integration-db}"
PG_USER="${PG_USER:-whatsapp_integration}"
LIVE_DATABASE="${LIVE_DATABASE:-whatsapp_integration_production}"

log() { printf '%s pg_restore: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

force_live=0
assume_yes=0
args=()
for arg in "$@"; do
  case "$arg" in
    --force-live) force_live=1 ;;
    --yes) assume_yes=1 ;;
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
case "$target" in
  postgres|template0|template1) die "refusing to restore into system database $target" ;;
esac
[[ "$(docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null)" == "true" ]] \
  || die "container $PG_CONTAINER is not running"

psql_in() { docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d postgres -v ON_ERROR_STOP=1 -qAt "$@"; }

if [[ "$target" == "$LIVE_DATABASE" ]]; then
  [[ $force_live -eq 1 ]] || die "$target is the live database; pass --force-live to overwrite it"
  if [[ $assume_yes -ne 1 ]]; then
    read -r -p "This OVERWRITES live database $target with $dump. Type the database name to continue: " answer
    [[ "$answer" == "$target" ]] || die "confirmation did not match; nothing changed"
  fi
  log "restoring into LIVE database $target (clean + if-exists)"
  docker exec -i "$PG_CONTAINER" pg_restore -U "$PG_USER" -d "$target" \
    --clean --if-exists --no-owner --exit-on-error < "$dump"
else
  log "recreating scratch database $target"
  psql_in -c "DROP DATABASE IF EXISTS \"$target\"" -c "CREATE DATABASE \"$target\" OWNER \"$PG_USER\""
  docker exec -i "$PG_CONTAINER" pg_restore -U "$PG_USER" -d "$target" \
    --no-owner --exit-on-error < "$dump"
fi

tables="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$target" -qAt \
  -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")"
version="$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$target" -qAt \
  -c "SELECT max(version) FROM schema_migrations")"
log "restored into $target: $tables public tables, latest migration $version"
