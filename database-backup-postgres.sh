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

# Assign variables with priority: Command-line args > .backup file > Defaults
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

# Convert comma-separated lists to arrays
IFS=',' read -ra exclude_schemas_array <<< "$exclude_schemas"
IFS=',' read -ra selected_schemas_array <<< "$selected_schemas"

# Set base and backup directories
base_dir="${BASE_DIR:-$dir/db-backup}"
backup_dir="${base_dir}/postgres"

# Check if Docker service is running
if [[ "$use_docker" == "true" ]]; then
    log "Checking if ${service} service is running..."
    if ! docker ps --filter "name=${service}" --filter "status=running" | grep -q "${service}"; then
        log "ERROR: ${service} service is not running. Exiting script."
        exit 1
    fi
fi

# Create directories
mkdir -p "$base_dir"
log "Base directory set to: ${base_dir}"
mkdir -p "$backup_dir"
log "Backup directory set to: ${backup_dir}"

# System schemas to exclude
system_schemas_array=("pg_catalog" "information_schema" "pg_toast")

# Combine all excluded schemas
declare -a all_exclude_schemas_array
all_exclude_schemas_array+=("${system_schemas_array[@]}")
all_exclude_schemas_array+=("${exclude_schemas_array[@]}")

# Log excluded schemas
if [[ ${#all_exclude_schemas_array[@]} -gt 0 ]]; then
    log "Excluding schemas: ${all_exclude_schemas_array[*]}"
fi

# Validate required parameters
[[ -z "$pass" ]] && handle_error "Database password not provided"

pg_dump_cmd="pg_dump"
psql_cmd="psql"
timestamp=$(date +%Y%m%d_%H%M%S)

# Function to check if a schema should be excluded
should_exclude() {
    local schema="$1"
    for exclude in "${all_exclude_schemas_array[@]}"; do
        if [[ "$schema" == "$exclude" ]]; then
            echo "true"
            return
        fi
    done
    echo "false"
}

# Function to backup a single schema
backup_schema() {
    local schema="$1"
    local output_dir="$2"
    local filename="$3"

    [[ -z "$schema" ]] && return

    log "Backing up schema: $schema to $filename.sql"

    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" "$pg_dump_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -n "$schema" > "${output_dir}/${filename}.sql"
    else
        PGPASSWORD="$pass" "$pg_dump_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -n "$schema" -f "${output_dir}/${filename}.sql"
    fi

    if [[ $? -ne 0 ]]; then
        log "WARNING: Failed to backup schema '$schema'"
        return 1
    fi

    return 0
}

# Function to validate schema exists
validate_schema_exists() {
    local schema="$1"
    local query="SELECT EXISTS(SELECT 1 FROM information_schema.schemata WHERE schema_name = '$schema')"
    local exists

    if [[ "$use_docker" == "true" ]]; then
        exists=$(docker exec -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -t -c "$query")
    else
        exists=$(PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -t -c "$query")
    fi

    exists=$(echo "$exists" | tr -d '[:space:]')
    [[ "$exists" == "t" ]] && echo "true" || echo "false"
}

# Create backup directory for schemas
schema_dir="${backup_dir}/${database}_${timestamp}"
mkdir -p "$schema_dir"

# Create manifest
manifest="${schema_dir}/manifest.txt"
echo "Database: $database" > "$manifest"
echo "Backup date: $(date)" >> "$manifest"
echo "Excluded schemas: ${all_exclude_schemas_array[*]}" >> "$manifest"
echo "Schemas to backup:" >> "$manifest"

# Track success/failure
success_count=0
failure_count=0
declare -a missing_schemas_array

# Determine which schemas to backup
declare -a schemas_to_backup_array

if [[ ${#selected_schemas_array[@]} -gt 0 ]]; then
    log "Backing up selected schemas from database '$database'"
    schemas_to_backup_array=("${selected_schemas_array[@]}")
else
    log "Backing up all non-system schemas from database '$database'"
    # Get all schemas from database
    query="SELECT schema_name FROM information_schema.schemata"
    if [[ "$use_docker" == "true" ]]; then
        all_schemas=$(docker exec -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -t -c "$query")
    else
        all_schemas=$(PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -t -c "$query")
    fi

    # Read all schemas into array
    while IFS= read -r schema; do
        schema=$(echo "$schema" | tr -d '[:space:]')
        [[ -z "$schema" ]] && continue

        # Check if schema should be excluded
        excluded=$(should_exclude "$schema")
        if [[ "$excluded" == "false" ]]; then
            schemas_to_backup_array+=("$schema")
        fi
    done <<< "$all_schemas"
fi

# Backup each schema
for schema in "${schemas_to_backup_array[@]}"; do
    # Validate schema exists
    exists=$(validate_schema_exists "$schema")

    if [[ "$exists" == "false" ]]; then
        log "WARNING: Schema '$schema' does not exist in database '$database'"
        missing_schemas_array+=("$schema")
        echo "- $schema" >> "$manifest"
        echo "  Status: MISSING" >> "$manifest"
        ((failure_count++))
        continue
    fi

    log "Backing up schema: $schema"
    echo "- $schema" >> "$manifest"
    backup_schema "$schema" "$schema_dir" "${database}_${schema}_${timestamp}"

    if [[ $? -eq 0 ]]; then
        echo "  Status: SUCCESS" >> "$manifest"
        ((success_count++))
    else
        echo "  Status: FAILED" >> "$manifest"
        ((failure_count++))
    fi
done

log "Schema backup complete: $success_count schemas backed up successfully, $failure_count schemas failed"

# Add summary to manifest
echo "" >> "$manifest"
echo "=== SUMMARY ===" >> "$manifest"
echo "Total schemas attempted: ${#schemas_to_backup_array[@]}" >> "$manifest"
echo "Successfully backed up: $success_count" >> "$manifest"
echo "Failed: $failure_count" >> "$manifest"

if [[ ${#missing_schemas_array[@]} -gt 0 ]]; then
    echo "Missing schemas: ${missing_schemas_array[*]}" >> "$manifest"
fi

# Compress if requested
if [[ "$compress" == "true" ]]; then
    archive_file="${backup_dir}/${database}_${timestamp}.tar.gz"
    log "Compressing backup directory to ${archive_file}"
    tar -czf "$archive_file" -C "$backup_dir" "$(basename "$schema_dir")"
    if [[ $? -eq 0 ]]; then
        log "Compression successful, removing original backup directory"
        rm -rf "$schema_dir"
    else
        log "WARNING: Compression failed, keeping original backup directory"
    fi
fi

# Cleanup old backups
if [[ -n "$days_to_keep" && "$days_to_keep" -gt 0 ]]; then
    log "Removing backups older than $days_to_keep days"
    find "$backup_dir" -name "${database}_*" -type d -mtime "+$days_to_keep" -exec rm -rf {} \; 2>/dev/null || true
    find "$backup_dir" -name "${database}_*.tar.gz" -type f -mtime "+$days_to_keep" -delete 2>/dev/null || true
fi

# Final exit
if [[ $failure_count -gt 0 ]]; then
    log "WARNING: Some schemas failed to backup. Check manifest for details."
    exit 1
else
    log "PostgreSQL schema backup completed successfully"
    exit 0
fi