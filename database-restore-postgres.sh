#!/bin/bash
set -e

# -------------------------------
# Logging & error handling
# -------------------------------
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

handle_error() {
    log "ERROR: $1"
    exit 1
}

# -------------------------------
# Load env
# -------------------------------
dir="$(dirname "$(realpath "$0")")"
[[ -f "$dir/.backup" ]] && source "$dir/.backup"

# -------------------------------
# Parse args
# -------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user) shift; user="$1" ;;
        -p|--pass) shift; pass="$1" ;;
        -s|--service) shift; service="$1" ;;
        -h|--host) shift; host="$1" ;;
        --port) shift; port="$1" ;;
        -b|--base-dir) shift; base_dir="$1" ;;
        -db|--database) shift; database="$1" ;;
        --docker) use_docker=true ;;
        --backup) shift; backup_file="$1" ;;
        --schemas) shift; schemas="$1" ;;
        --list) list_only=true ;;
        --latest) use_latest=true ;;
        *) handle_error "Invalid argument: $1" ;;
    esac
    shift
done

# -------------------------------
# Defaults
# -------------------------------
user="${user:-${PG_USERNAME:-postgres}}"
pass="${pass:-${PG_PASSWORD:-}}"
service="${service:-${SERVICE:-postgres}}"
host="${host:-127.0.0.1}"
port="${port:-5432}"
database="${database:-postgres}"
use_docker="${use_docker:-true}"
list_only="${list_only:-false}"
use_latest="${use_latest:-false}"

base_dir="${base_dir:-$dir/db-backup/postgres}"
backup_dir="${base_dir}/${database}"

[[ -z "$pass" ]] && handle_error "Database password is required"

pg_restore_cmd="pg_restore"
psql_cmd="psql"

# -------------------------------
# Helpers
# -------------------------------
psql_exec() {
    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" "$psql_cmd" "$@"
    else
        PGPASSWORD="$pass" "$psql_cmd" "$@"
    fi
}

restore_exec() {
    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" "$pg_restore_cmd" "$@"
    else
        PGPASSWORD="$pass" "$pg_restore_cmd" "$@"
    fi
}

# -------------------------------
# List backups
# -------------------------------
list_backups() {
    log "Available backups for database '$database':"
    find "$backup_dir" -type f -name "${database}_*.dump*" | sort
    exit 0
}

get_latest_backup() {
    find "$backup_dir" -type f -name "${database}_*.dump*" -print0 \
        | xargs -0 ls -t 2>/dev/null | head -n 1
}

# -------------------------------
# Main
# -------------------------------
[[ "$list_only" == "true" ]] && list_backups

if [[ "$use_latest" == "true" ]]; then
    backup_file="$(get_latest_backup)"
elif [[ -z "$backup_file" ]]; then
    list_backups
fi

[[ -z "$backup_file" || ! -f "$backup_file" ]] && handle_error "Backup file not found"

log "Using backup: $(basename "$backup_file")"

# -------------------------------
# Ensure database exists
# -------------------------------
log "Ensuring database '$database' exists"
psql_exec -U "$user" -h "$host" -p "$port" -c "CREATE DATABASE $database;" || true

# -------------------------------
# Build pg_restore args
# -------------------------------
declare -a restore_args=(
    -U "$user"
    -h "$host"
    -p "$port"
    -d "$database"
    -v
    --clean
    --if-exists
)

IFS=',' read -ra schema_array <<< "${schemas:-}"

for s in "${schema_array[@]}"; do
    restore_args+=("-n" "$s")
done

# -------------------------------
# Restore
# -------------------------------
log "Starting restore for database '$database'"

if [[ "$backup_file" == *.gz ]]; then
    gunzip -c "$backup_file" | restore_exec "${restore_args[@]}"
else
    restore_exec "${restore_args[@]}" "$backup_file"
fi

log "Restore completed successfully for database '$database'"
