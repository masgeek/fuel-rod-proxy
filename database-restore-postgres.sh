#!/bin/bash

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Function to handle errors
handle_error() {
    log "ERROR: $1"
    exit 1
}

# Load environment variables from .backup file if present
dir="$(dirname "$(realpath "$0")")"
if [[ -f "$dir/.backup" ]]; then
    source "$dir/.backup"
    log "Loaded environment variables from .backup file"
fi

# Parse command-line arguments
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
        --schemas) shift; specific_schemas="$1" ;;
        --list) list_only=true ;;
        --latest) use_latest=true ;;
        *) handle_error "Invalid argument: $1" ;;
    esac
    shift
done

# Assign variables with fallback priorities
user="${user:-${PG_USERNAME:-postgres}}"
pass="${pass:-${PG_PASSWORD:-}}"
service="${service:-${SERVICE:-postgres}}"
host="${host:-${PG_HOST:-127.0.0.1}}"
port="${port:-${PG_PORT:-5432}}"
use_docker="${use_docker:-${USE_DOCKER:-true}}"
database="${database:-${PG_SCHEMA:-postgres}}"
list_only="${list_only:-false}"
use_latest="${use_latest:-false}"
base_dir="${base_dir:-${RESTORE_DIR:-$dir/db-restore}}"
backup_dir="${base_dir}/postgres"

# Check for PG_USERNAME/PG_PASSWORD if user/pass not provided
if [[ -z "$user" && -n "$PG_USERNAME" ]]; then
    user="$PG_USERNAME"
    log "Using PG_USERNAME from .backup file"
fi

if [[ -z "$pass" && -n "$PG_PASSWORD" ]]; then
    pass="$PG_PASSWORD"
    log "Using PG_PASSWORD from .backup file"
fi

# Validate required parameters
[[ -z "$pass" ]] && handle_error "Database password not provided. Set with -p/--pass or in .backup file"

# Set up
psql_cmd="psql"
temp_dir="/tmp/pg_restore_$$"

# Function to list available backups
list_backups() {
    log "Available backups for database '$database':"

    archives=$(find "$backup_dir" -name "${database}_*.tar.gz" -type f | sort)
    directories=$(find "$backup_dir" -name "${database}_*" -type d | sort)

    if [[ -z "$archives" && -z "$directories" ]]; then
        log "No backups found in $backup_dir"
        exit 0
    fi

    backups=()
    echo "Available backups:"
    index=0

    if [[ -n "$archives" ]]; then
        echo "Compressed archives:"
        for archive in $archives; do
            echo "  [$index] $(basename "$archive")"
            backups+=("$archive")
            ((index++))
        done
    fi

    if [[ -n "$directories" ]]; then
        echo "Uncompressed directories:"
        for directory in $directories; do
            echo "  [$index] $(basename "$directory")"
            backups+=("$directory")
            ((index++))
        done
    fi

    read -rp "Enter the number of the backup to select: " selected_index

    if ! [[ "$selected_index" =~ ^[0-9]+$ ]] || (( selected_index < 0 || selected_index >= ${#backups[@]} )); then
        echo "Invalid selection."
        exit 1
    fi

    backup_file="${backups[$selected_index]}"
    echo "You selected: $backup_file"
}

# Function to get the latest backup
get_latest_backup() {
    latest_archive=$(find "$backup_dir" -name "${database}_*.tar.gz" -type f -print0 | xargs -0 ls -t 2>/dev/null | head -n 1)
    if [[ -z "$latest_archive" ]]; then
        latest_dir=$(find "$backup_dir" -name "${database}_*" -type d -print0 | xargs -0 ls -t 2>/dev/null | head -n 1)
        echo "$latest_dir"
    else
        echo "$latest_archive"
    fi
}

# Extract schemas from manifest
get_schemas_from_manifest() {
    grep "^- " "$1" | sed 's/^- //'
}

# Restore schema
restore_schema() {
    local schema="$1"
    local sql_file="$2"

    log "Restoring schema: $schema from $sql_file"
    local create_schema_sql="DROP SCHEMA IF EXISTS $schema CASCADE; CREATE SCHEMA $schema;"

    if [[ "$use_docker" == "true" ]]; then
        echo "$create_schema_sql" | docker exec -i -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database"
        docker exec -i -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" < "$sql_file"
    else
        echo "$create_schema_sql" | PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database"
        PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -f "$sql_file"
    fi

    return $?
}

# Main execution
[[ "$list_only" == "true" ]] && { list_backups; exit 0; }

if [[ "$use_latest" == "true" ]]; then
    backup_file=$(get_latest_backup)
    [[ -z "$backup_file" ]] && handle_error "No backups found for database '$database'"
    log "Using latest backup: $(basename "$backup_file")"
elif [[ -z "$backup_file" ]]; then
    list_backups
fi

[[ ! -e "$backup_file" ]] && handle_error "Backup file or directory does not exist: $backup_file"

mkdir -p "$temp_dir" || handle_error "Failed to create temporary directory"
log "Created temporary directory: $temp_dir"

if [[ -f "$backup_file" && "$backup_file" == *.tar.gz ]]; then
    log "Extracting archive: $backup_file"
    tar -xzf "$backup_file" -C "$temp_dir" || handle_error "Failed to extract archive"
    extracted_dir=$(find "$temp_dir" -type d -name "${database}_*" | head -n 1)
    [[ -z "$extracted_dir" ]] && handle_error "Failed to find extracted backup directory"
    restore_dir="$extracted_dir"
elif [[ -d "$backup_file" ]]; then
    log "Using uncompressed backup directory: $backup_file"
    cp -r "$backup_file"/* "$temp_dir/" || handle_error "Failed to copy backup files"
    restore_dir="$temp_dir"
else
    handle_error "Unsupported backup format: $backup_file"
fi

if [[ "$use_docker" == "true" ]]; then
    command -v docker &>/dev/null || handle_error "Docker is not available"
    docker ps | grep -q "$service" || handle_error "PostgreSQL container '$service' is not running"
fi

manifest="$restore_dir/manifest.txt"
[[ ! -f "$manifest" ]] && handle_error "Manifest file not found in backup"

if [[ -n "$specific_schemas" ]]; then
    log "Will restore only these schemas: $specific_schemas"
    schemas_to_restore="$specific_schemas"
else
    schemas_to_restore=$(get_schemas_from_manifest "$manifest")
    log "Will restore all schemas found in manifest"
fi

if [[ "$use_docker" == "true" ]]; then
    docker exec -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -c "CREATE DATABASE $database;" || true
else
    PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -c "CREATE DATABASE $database;" || true
fi

success_count=0
failure_count=0

for schema in $schemas_to_restore; do
    sql_file=$(find "$restore_dir" -name "${database}_${schema}_*.sql*" | head -n 1)

    if [[ "$sql_file" == *.gz ]]; then
        log "Decompressing $sql_file"
        gunzip -c "$sql_file" > "${sql_file%.gz}"
        sql_file="${sql_file%.gz}"
    fi

    if [[ -z "$sql_file" ]]; then
        log "WARNING: No backup file found for schema '$schema'"
        ((failure_count++))
        continue
    fi

    restore_schema "$schema" "$sql_file" && ((success_count++)) || ((failure_count++))
done

log "Cleaning up temporary files"
rm -rf "$temp_dir"

log "Restore complete: $success_count schemas restored successfully, $failure_count schemas failed"

if [[ $failure_count -gt 0 ]]; then
    log "WARNING: Some schemas failed to restore"
    exit 1
else
    log "PostgreSQL database restore completed successfully"
    exit 0
fi
