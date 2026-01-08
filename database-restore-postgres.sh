#!/bin/bash
set -euo pipefail

# ===============================
# Logging
# ===============================
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*"; exit 1; }

# ===============================
# Load environment
# ===============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/.backup" ]] && source "$SCRIPT_DIR/.backup"

# ===============================
# Defaults
# ===============================
PG_USER="${PG_USERNAME:-postgres}"
PG_PASS="${PG_PASSWORD:-}"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
SERVICE="${SERVICE:-postgres}"
USE_DOCKER="${USE_DOCKER:-true}"
BASE_DIR="${BASE_DIR:-$SCRIPT_DIR/db-restore}"

[[ -z "$PG_PASS" ]] && die "PG_PASSWORD is required"
[[ ! -d "$BASE_DIR" ]] && die "Restore base directory not found: $BASE_DIR"

# ===============================
# Helpers
# ===============================
psql_exec() {
    if [[ "$USE_DOCKER" == "true" ]]; then
        docker exec -e PGPASSWORD="$PG_PASS" "$SERVICE" psql "$@"
    else
        PGPASSWORD="$PG_PASS" psql "$@"
    fi
}

restore_stream() {
    if [[ "$USE_DOCKER" == "true" ]]; then
        docker exec -i -e PGPASSWORD="$PG_PASS" "$SERVICE" pg_restore "$@"
    else
        PGPASSWORD="$PG_PASS" pg_restore "$@"
    fi
}

# ===============================
# Select database folder
# ===============================
mapfile -t DB_DIRS < <(find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
[[ ${#DB_DIRS[@]} -eq 0 ]] && die "No database folders found in $BASE_DIR"

log "Available databases:"
for i in "${!DB_DIRS[@]}"; do
    echo "[$i] $(basename "${DB_DIRS[$i]}")"
done

read -rp "Select database: " DB_CHOICE
[[ "$DB_CHOICE" =~ ^[0-9]+$ ]] || die "Invalid input"
(( DB_CHOICE < ${#DB_DIRS[@]} )) || die "Out of range"

DB_DIR="${DB_DIRS[$DB_CHOICE]}"
DATABASE="$(basename "$DB_DIR")"

# ===============================
# Select backup (oldest → newest)
# ===============================
mapfile -t BACKUPS < <(find "$DB_DIR" -type f -name "${DATABASE}_*.dump*" | sort)
[[ ${#BACKUPS[@]} -eq 0 ]] && die "No backups found for $DATABASE"

log "Available backups (oldest → newest):"
for i in "${!BACKUPS[@]}"; do
    echo "[$i] $(basename "${BACKUPS[$i]}")"
done

read -rp "Select backup (Enter = latest): " BACKUP_CHOICE
if [[ -z "$BACKUP_CHOICE" ]]; then
    BACKUP_FILE="${BACKUPS[-1]}"
else
    [[ "$BACKUP_CHOICE" =~ ^[0-9]+$ ]] || die "Invalid input"
    (( BACKUP_CHOICE < ${#BACKUPS[@]} )) || die "Out of range"
    BACKUP_FILE="${BACKUPS[$BACKUP_CHOICE]}"
fi

[[ -f "$BACKUP_FILE" ]] || die "Backup file missing"
log "Selected backup: $(basename "$BACKUP_FILE")"

# ===============================
# Ensure database exists
# ===============================
log "Ensuring database '$DATABASE' exists"

psql_exec -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres \
    -tc "SELECT 1 FROM pg_database WHERE datname='${DATABASE}'" \
    | grep -q 1 || \
psql_exec -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres \
    -c "CREATE DATABASE \"$DATABASE\""

# ===============================
# Build restore arguments
# ===============================
RESTORE_ARGS=(
    -U "$PG_USER"
    -h "$PG_HOST"
    -p "$PG_PORT"
    -d "$DATABASE"
    --clean
    --if-exists
    -v
)

# ===============================
# Restore (streaming, handles .gz)
# ===============================
log "Starting restore..."

if [[ "$BACKUP_FILE" == *.gz ]]; then
    log "Backup is gzipped. Using gunzip pipe."
    gunzip -c "$BACKUP_FILE" | restore_stream "${RESTORE_ARGS[@]}"
else
    log "Backup is uncompressed. Using cat pipe."
    cat "$BACKUP_FILE" | restore_stream "${RESTORE_ARGS[@]}"
fi

log "✅ Restore completed successfully for '$DATABASE'"
