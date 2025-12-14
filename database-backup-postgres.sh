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
while [ $# -gt 0 ]; do
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

# -------------------------------
# Defaults
# -------------------------------
user="${user:-postgres}"
pass="${pass:-${PG_PASSWORD:-}}"
host="${host:-127.0.0.1}"
port="${port:-5432}"
service="${service:-postgres}"
use_docker="${use_docker:-true}"
compress="${compress:-false}"
days_to_keep="${days_to_keep:-7}"
backup_all_databases="${backup_all_databases:-true}"

IFS=',' read -ra databases_array <<< "${databases:-}"
IFS=',' read -ra selected_schemas_array <<< "${selected_schemas:-}"
IFS=',' read -ra exclude_schemas_array <<< "${exclude_schemas:-}"

timestamp="$(date +%Y%m%d_%H%M%S)"

base_dir="${BASE_DIR:-$dir/db-backup/postgres}"
mkdir -p "$base_dir"

pg_dump_cmd="pg_dump"
psql_cmd="psql"

system_schemas=(pg_catalog information_schema pg_toast)

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

dump_exec() {
    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" "$pg_dump_cmd" "$@"
    else
        PGPASSWORD="$pass" "$pg_dump_cmd" "$@"
    fi
}

should_exclude() {
    local s="$1"
    for e in "${system_schemas[@]}" "${exclude_schemas_array[@]}"; do
        [[ "$s" == "$e" ]] && return 0
    done
    return 1
}

# -------------------------------
# Get databases
# -------------------------------
get_all_databases() {
    psql_exec -U "$user" -h "$host" -p "$port" -d postgres -At \
        -c "SELECT datname FROM pg_database WHERE datistemplate=false"
}

get_schemas() {
    local db="$1"
    psql_exec -U "$user" -h "$host" -p "$port" -d "$db" -At \
        -c "SELECT schema_name FROM information_schema.schemata"
}

# -------------------------------
# Backup schema → individual file 🔧
# -------------------------------
backup_schema() {
    local db="$1"
    local schema="$2"
    local outdir="$3"

    local file="${outdir}/${db}_${schema}_${timestamp}.sql"

    log "Backing up $db.$schema → $(basename "$file")"

    dump_exec -U "$user" -h "$host" -p "$port" \
        -d "$db" -n "$schema" \
        --format=plain \
        --no-owner --no-acl \
        > "$file"
}

# -------------------------------
# Backup database (schemas only)
# -------------------------------
backup_database() {
    local db="$1"
    local db_dir="${base_dir}/${db}"
    mkdir -p "$db_dir"

    local manifest="${db_dir}/manifest_${timestamp}.txt"
    {
        echo "Database: $db"
        echo "Timestamp: $timestamp"
        echo "Schemas:"
    } > "$manifest"

    declare -a schemas

    if [[ ${#selected_schemas_array[@]} -gt 0 ]]; then
        schemas=("${selected_schemas_array[@]}")
    else
        while IFS= read -r s; do
            should_exclude "$s" || schemas+=("$s")
        done < <(get_schemas "$db")
    fi

    for schema in "${schemas[@]}"; do
        echo "- $schema" >> "$manifest"
        backup_schema "$db" "$schema" "$db_dir"
    done

    # 🔧 Optional per-database archive
    if [[ "$compress" == "true" ]]; then
        local archive="${db_dir}/${db}_${timestamp}.tar.gz"
        log "Compressing schemas for $db"
        tar -czf "$archive" -C "$db_dir" \
            $(ls "$db_dir" | grep "_${timestamp}.sql") \
            "manifest_${timestamp}.txt"
    fi
}

# -------------------------------
# Main
# -------------------------------
declare -a databases_to_backup

if [[ "$backup_all_databases" == "true" ]]; then
    while IFS= read -r db; do databases_to_backup+=("$db"); done < <(get_all_databases)
else
    databases_to_backup=("${databases_array[@]}")
fi

for db in "${databases_to_backup[@]}"; do
    log "Starting backup for database: $db"
    backup_database "$db"
done

# -------------------------------
# Cleanup old files 🔧
# -------------------------------
if [[ "$days_to_keep" -gt 0 ]]; then
    log "Cleaning backups older than $days_to_keep days"
    find "$base_dir" -type f \( -name "*.sql" -o -name "*.tar.gz" -o -name "manifest_*.txt" \) \
        -mtime "+$days_to_keep" -delete
fi

log "=== SCHEMA BACKUP COMPLETE ==="
