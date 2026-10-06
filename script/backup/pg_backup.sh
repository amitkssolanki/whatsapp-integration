#!/usr/bin/env bash
# Nightly PostgreSQL backup. Runs on the VPS host (cron), dumps through `docker exec`
# on the Kamal accessory container, keeps 7 days, exits non-zero on any failure.
#
#   script/backup/pg_backup.sh
#
# Overridable via environment:
#   PG_CONTAINER    accessory container   (default: whatsapp-integration-db)
#   PG_USER         database role         (default: whatsapp_integration)
#   PG_DATABASE     database to dump      (default: whatsapp_integration_production)
#   BACKUP_DIR      dump directory        (default: /var/backups/whatsapp-integration)
#   RETENTION_DAYS  days to keep          (default: 7)
#   HEARTBEAT_URL   optional; curl'd only after a fully successful run
#                   (e.g. a Healthchecks.io / Better Stack heartbeat), so a silent
#                   cron failure becomes an alert.
set -euo pipefail
umask 077

PG_CONTAINER="${PG_CONTAINER:-whatsapp-integration-db}"
PG_USER="${PG_USER:-whatsapp_integration}"
PG_DATABASE="${PG_DATABASE:-whatsapp_integration_production}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/whatsapp-integration}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

log() { printf '%s pg_backup: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[[ "$RETENTION_DAYS" =~ ^[0-9]+$ && "$RETENTION_DAYS" -ge 1 ]] || die "RETENTION_DAYS must be a positive integer"
command -v docker >/dev/null || die "docker not found"
[[ "$(docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null)" == "true" ]] \
  || die "container $PG_CONTAINER is not running"

mkdir -p "$BACKUP_DIR"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
final="$BACKUP_DIR/${PG_DATABASE}_${stamp}.dump"
partial="$final.partial"
trap 'rm -f "$partial"' EXIT

# Custom format (-Fc): compressed, restorable selectively with pg_restore.
docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -Fc "$PG_DATABASE" > "$partial" \
  || die "pg_dump failed"
[[ -s "$partial" ]] || die "dump is empty"

# Prove the archive is readable before it replaces anything.
docker exec -i "$PG_CONTAINER" pg_restore --list < "$partial" > /dev/null \
  || die "dump failed the pg_restore --list check"

mv "$partial" "$final"
log "wrote $final ($(wc -c < "$final" | tr -d ' ') bytes)"

# Rotation runs only after a verified new dump exists.
find "$BACKUP_DIR" -maxdepth 1 -type f -name "${PG_DATABASE}_*.dump" \
  -mmin +"$((RETENTION_DAYS * 1440))" -print -delete \
  | sed 's/^/pg_backup: rotated out /'

if [[ -n "${HEARTBEAT_URL:-}" ]]; then
  curl -fsS --max-time 10 --retry 2 -o /dev/null "$HEARTBEAT_URL" || log "WARN: heartbeat ping failed"
fi
log "ok"
