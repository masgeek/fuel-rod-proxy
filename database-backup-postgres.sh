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
while [ $# -gt 0 ]; do
    case "$1" in
        -u|--user) shift; user="$1" ;;
        -p|--pass) shift; pass="$1" ;;
        -s|--service) shift; service="$1" ;;
        -h|--host) shift; host="$1" ;;
        --port) shift; port="$1" ;;
        -d|--base-dir) shift; base_dir="$1" ;;
        -db|--database) shift; database="$1" ;;
        --docker) use_docker=true ;;
        --compress) compress=true ;;
        --keep-days) shift; days_to_keep="$1" ;;
        --exclude) shift; exclude_schemas="$1" ;;
        --schemas) shift; selected_schemas="$1" ;;
        *) handle_error "Invalid argument: $1" ;;
    esac
    shift
done

# Assign defaults
user="${user:-${PG_USERNAME:-postgres}}"
pass="${pass:-${PG_PASSWORD:-}}"
service="${service:-${SERVICE:-postgres}}"
host="${host:-${HOST:-127.0.0.1}}"
port="${port:-${PORT:-5432}}"
use_docker="${use_docker:-${USE_DOCKER:-true}}"
database="${database:-${PG_SCHEMA:-postgres}}"
compress="${compress:-${COMPRESS:-true}}"
days_to_keep="${days_to_keep:-${DAYS_TO_KEEP:-7}}"
exclude_schemas="${exclude_schemas:-${EXCLUDE_SCHEMAS:-}}"
selected_schemas="${selected_schemas:-${SELECTED_SCHEMAS:-}}"

exclude_schemas="${exclude_schemas//,/ }"
selected_schemas="${selected_schemas//,/ }"

base_dir="${BASE_DIR:-$dir/db-backup}"
backup_dir="${base_dir}/postgres"
mkdir -p "$backup_dir"

log "Base directory: $base_dir"
log "Backup directory: $backup_dir"

# Check Docker container status
if [[ "$use_docker" == "true" ]]; then
    log "Checking Docker service: $service"
    if ! docker ps --filter "name=${service}" --filter "status=running" | grep -q "${service}"; then
        handle_error "Docker container '$service' is not running"
    fi
fi

# Internal schema exclusions
system_schemas="pg_catalog information_schema pg_toast pg_temp%"
all_exclude_schemas="$exclude_schemas $system_schemas"

pg_dump_cmd="pg_dump"
psql_cmd="psql"
timestamp=$(date +%Y%m%d_%H%M%S)

get_schemas() {
    local query="SELECT schema_name FROM information_schema.schemata"
    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -t -c "$query"
    else
        PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -t -c "$query"
    fi
}

should_exclude() {
    local schema="$1"
    for pattern in $all_exclude_schemas; do
        local regex="^${pattern//\*/.*}"
        [[ "$schema" =~ $regex ]] && echo "true" && return
    done
    echo "false"
}

match_schema_patterns() {
    local patterns="$1"
    local all="$2"
    local result=""
    for pattern in $patterns; do
        local regex="^${pattern//\*/.*}"
        while IFS= read -r schema; do
            [[ "$schema" =~ $regex ]] && result+="$schema"$'\n'
        done <<< "$all"
    done
    echo "$result" | sort -u
}

backup_schema() {
    local schema="$1"
    local output_dir="$2"
    local filename="${schema}_${timestamp}"
    log "Backing up schema: $schema -> $filename.sql"

    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" "$pg_dump_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -n "$schema" > "${output_dir}/${filename}.sql"
    else
        PGPASSWORD="$pass" "$pg_dump_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -n "$schema" -f "${output_dir}/${filename}.sql"
    fi

    if [[ $? -ne 0 ]]; then
        log "WARNING: Backup failed for schema '$schema'"
        return 1
    fi

    # Compress individual schema file if enabled
    if [[ "$compress" == "true" ]]; then
        gzip -f "${output_dir}/${filename}.sql"
        log "Compressed ${filename}.sql"
    fi
    return 0
}

# Begin backup
schema_dir="${backup_dir}/${database}_${timestamp}"
mkdir -p "$schema_dir"

all_schemas="$(get_schemas)"

# Schema selection
if [[ -n "$selected_schemas" ]]; then
    log "Filtering for selected schemas: $selected_schemas"
    schema_list="$(match_schema_patterns "$selected_schemas" "$all_schemas")"
else
    schema_list="$all_schemas"
fi

manifest="${schema_dir}/manifest.txt"
echo "Database: $database" > "$manifest"
echo "Date: $(date)" >> "$manifest"
echo "Excluded: $all_exclude_schemas" >> "$manifest"
echo "Schemas:" >> "$manifest"

success_count=0
failure_count=0

while IFS= read -r schema; do
    schema="$(echo "$schema" | xargs)"
    [[ -z "$schema" ]] && continue
    [[ "$(should_exclude "$schema")" == "true" ]] && log "Skipping excluded schema: $schema" && continue

    echo "- $schema" >> "$manifest"
    if backup_schema "$schema" "$schema_dir"; then
        echo "  Status: SUCCESS" >> "$manifest"
        ((success_count++))
    else
        echo "  Status: FAILED" >> "$manifest"
        ((failure_count++))
    fi
done <<< "$schema_list"

log "Backed up $success_count schema(s), $failure_count failed"

# Compress entire directory if enabled
if [[ "$compress" == "true" ]]; then
    archive_file="${backup_dir}/${database}_${timestamp}.tar.gz"
    log "Compressing full backup to $archive_file"
    tar -czf "$archive_file" -C "$backup_dir" "$(basename "$schema_dir")" && rm -rf "$schema_dir"
fi

# Cleanup
if [[ "$days_to_keep" -gt 0 ]]; then
    log "Cleaning old backups > $days_to_keep days"
    find "$backup_dir" -name "${database}_*" -type f -mtime "+$days_to_keep" -delete 2>/dev/null || true
    find "$backup_dir" -type d -mtime "+$days_to_keep" -exec rm -rf {} \; 2>/dev/null || true
fi

[[ "$failure_count" -gt 0 ]] && log "Some schemas failed to backup." && exit 1
log "All schema backups completed successfully."
exit 0
