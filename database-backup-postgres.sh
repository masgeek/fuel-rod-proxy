#!/bin/bash
set -euo pipefail

# ===============================
# Logging & error handling
# ===============================
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

handle_error() {
    log "ERROR: $1"
    exit 1
}

# ===============================
# Load environment variables
# ===============================
dir="$(dirname "$(realpath "$0")")"
[[ -f "$dir/.backup" ]] && source "$dir/.backup"

# ===============================
# Parse arguments
# ===============================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user) shift; user="$1" ;;
        -p|--pass) shift; pass="$1" ;;
        -h|--host) shift; host="$1" ;;
        --port) shift; port="$1" ;;
        -s|--service) shift; service="$1" ;;
        -db|--databases) shift; databases="$1" ;;
        --schemas) shift; selected_schemas="$1" ;;
        --exclude) shift; exclude_schemas="$1" ;;
        --docker) use_docker=true ;;
        --compress) compress=true ;;
        --keep-days) shift; days_to_keep="$1" ;;
        --all-databases) backup_all_databases=true ;;
        *) handle_error "Invalid argument: $1" ;;
    esac
    shift
done

# ===============================
# Defaults
# ===============================
user="${user:-${PG_USERNAME:-postgres}}"
pass="${pass:-${PG_PASSWORD:-}}"
host="${host:-127.0.0.1}"
port="${port:-5432}"
service="${service:-${SERVICE:-postgres}}"
use_docker="${use_docker:-${USE_DOCKER:-true}}"
compress="${compress:-${COMPRESS_FILE:-false}}"
days_to_keep="${days_to_keep:-7}"
backup_all_databases="${backup_all_databases:-true}"

IFS=',' read -ra databases_array <<< "${databases:-}"
IFS=',' read -ra selected_schemas_array <<< "${selected_schemas:-}"
IFS=',' read -ra exclude_schemas_array <<< "${exclude_schemas:-}"

timestamp="$(date +%Y%m%d_%H%M%S)"
base_dir="${BASE_DIR:-$dir/db-backup}"
mkdir -p "$base_dir"

pg_dump_cmd="pg_dump"
psql_cmd="psql"

system_schemas=(pg_catalog information_schema pg_toast)

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

dump_exec() {
    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" "$pg_dump_cmd" "$@"
    else
        PGPASSWORD="$pass" "$pg_dump_cmd" "$@"
    fi
}

# ===============================
# Get all databases
# ===============================
get_all_databases() {
    psql_exec -U "$user" -h "$host" -p "$port" -d postgres -At \
        -c "SELECT datname FROM pg_database WHERE datistemplate = false"
}

# ===============================
# Backup a database
# ===============================
backup_database() {
    local db="$1"
    local db_dir="$base_dir/$db"
    mkdir -p "$db_dir"

    local dump_file="$db_dir/${db}_${timestamp}.dump"
    local manifest="$db_dir/manifest_${timestamp}.txt"

    log "Backing up database: $db"

    # Manifest
    {
        echo "Database: $db"
        echo "Timestamp: $timestamp"
        echo "Format: custom"
        [[ ${#selected_schemas_array[@]} -gt 0 ]] && echo "Included schemas: ${selected_schemas_array[*]}"
        [[ ${#exclude_schemas_array[@]} -gt 0 ]] && echo "Excluded schemas: ${exclude_schemas_array[*]}"
    } > "$manifest"

    # Schema arguments
    declare -a schema_args=()

    if [[ ${#selected_schemas_array[@]} -gt 0 ]]; then
        for s in "${selected_schemas_array[@]}"; do
            schema_args+=("-n" "$s")
        done
    else
        for s in "${exclude_schemas_array[@]}" "${system_schemas[@]}"; do
            schema_args+=("-N" "$s")
        done
    fi

    # Dump (stdout → host file, Docker-safe)
    dump_exec -U "$user" -h "$host" -p "$port" \
        -F c -b \
        "${schema_args[@]}" \
        "$db" > "$dump_file"

    # Optional compression
    if [[ "$compress" == "true" ]]; then
        gzip -9 "$dump_file"
    fi
}

# ===============================
# Main
# ===============================
declare -a databases_to_backup

if [[ "$backup_all_databases" == "true" ]]; then
    while IFS= read -r db; do
        databases_to_backup+=("$db")
    done < <(get_all_databases)
else
    databases_to_backup=("${databases_array[@]}")
fi

for db in "${databases_to_backup[@]}"; do
    backup_database "$db"
done

# ===============================
# Cleanup
# ===============================
if [[ "$days_to_keep" -gt 0 ]]; then
    log "Cleaning backups older than $days_to_keep days"
    find "$base_dir" -type f \( -name "*.dump*" -o -name "manifest_*.txt" \) \
        -mtime "+$days_to_keep" -delete
fi

log "=== DATABASE BACKUP COMPLETE ==="
