#!/bin/bash
set -euo pipefail

# ===============================
# Logging & error handling
# ===============================
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*"; exit 1; }

# ===============================
# Load env
# ===============================
dir="$(dirname "$(realpath "$0")")"
[[ -f "$dir/.backup" ]] && source "$dir/.backup"

# ===============================
# Parse args
# ===============================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user) shift; user="$1" ;;
        -p|--pass) shift; pass="$1" ;;
        -s|--service) shift; service="$1" ;;
        -h|--host) shift; host="$1" ;;
        --port) shift; port="$1" ;;
        -b|--base-dir) shift; base_dir="$1" ;;
        --docker) use_docker=true ;;
        --schemas) shift; schemas="$1" ;;
        --list) list_only=true ;;
        *) die "Invalid argument: $1" ;;
    esac
    shift
done

# ===============================
# Defaults
# ===============================
user="${user:-${PG_USERNAME:-postgres}}"
pass="${pass:-${PG_PASSWORD:-}}"
service="${service:-${SERVICE:-postgres}}"
host="${host:-127.0.0.1}"
port="${port:-5432}"
use_docker="${use_docker:-true}"
list_only="${list_only:-false}"
base_dir="${base_dir:-$dir/db-restore}"

[[ -z "$pass" ]] && die "Database password is required"
[[ ! -d "$base_dir" ]] && die "Backup base directory not found: $base_dir"

pg_restore_cmd="pg_restore"
psql_cmd="psql"

# ===============================
# Helpers
# ===============================
psql_exec() {
    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" "$psql_cmd" "$@"
    else
        PGPASSWORD="$pass" "$psql_cmd" "$@"
    fi
}

restore_exec() {
    if [[ "$use_docker" == "true" ]]; then
        docker exec -i -e PGPASSWORD="$pass" "$service" "$pg_restore_cmd" "$@"
    else
        PGPASSWORD="$pass" "$pg_restore_cmd" "$@"
    fi
}

# ===============================
# List backups across subfolders
# ===============================
list_backups() {
    mapfile -t backups < <(find "$base_dir" -type f -name "*.dump*" | sort)

    if [[ ${#backups[@]} -eq 0 ]]; then
        die "No backups found under $base_dir"
    fi

    log "Available backups:"
    for i in "${!backups[@]}"; do
        rel_path="${backups[$i]#$base_dir/}"
        echo "[$i] $rel_path"
    done

    if [[ "$list_only" == "true" ]]; then exit 0; fi

    # Prompt user to select
    while true; do
        read -rp "Enter the number of the backup to restore: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 0 && choice < ${#backups[@]} )); then
            backup_file="${backups[$choice]}"
            # Extract database from folder name
            database="$(basename "$(dirname "$backup_file")")"
            break
        else
            echo "Invalid selection. Enter 0-$((${#backups[@]}-1))"
        fi
    done
}

# ===============================
# Main
# ===============================
list_backups

log "Selected backup: $(basename "$backup_file") (database: $database)"

# Ensure database exists
log "Ensuring database '$database' exists"
psql_exec -U "$user" -h "$host" -p "$port" -d postgres \
    -tc "SELECT 1 FROM pg_database WHERE datname = '$database'" \
    | grep -q 1 || \
psql_exec -U "$user" -h "$host" -p "$port" -d postgres \
    -c "CREATE DATABASE \"$database\""

# Build pg_restore args
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
if [[ ${#schema_array[@]} -gt 0 && -n "${schema_array[0]}" ]]; then
    for s in "${schema_array[@]}"; do
        restore_args+=("-n" "$s")
    done
    log "Restoring schemas: ${schema_array[*]}"
else
    log "Restoring all schemas"
fi

# ===============================
# Restore
# ===============================
log "Starting restore into database '$database'"

if [[ "$backup_file" == *.gz ]]; then
    gunzip -c "$backup_file" | restore_exec "${restore_args[@]}"
else
    if [[ "$use_docker" == "true" ]]; then
        # Stream into container (host path not accessible)
        cat "$backup_file" | restore_exec "${restore_args[@]}"
    else
        restore_exec "${restore_args[@]}" "$backup_file"
    fi
fi

log "Restore completed successfully for database '$database'"
