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
[[ -f "$dir/.backup" ]] && export $(grep -v '^#' "$dir/.backup" | xargs)

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
        *) handle_error "Invalid argument: $1" ;;
    esac
    shift
done

# Assign variables with priority: Command-line args > .backup file > Defaults
user="${user:-${DB_USERNAME:-postgres}}"
pass="${pass:-${DB_PASSWORD:-}}"
service="${service:-${SERVICE:-postgres}}"
host="${host:-${HOST:-127.0.0.1}}"
port="${port:-${PORT:-5432}}"
use_docker="${use_docker:-${USE_DOCKER:-true}}"
database="${database:-${DB_SCHEMA:-postgres}}"
compress="${compress:-${COMPRESS:-true}}"  # Default to true for compression
days_to_keep="${days_to_keep:-${DAYS_TO_KEEP:-7}}"
exclude_schemas="${exclude_schemas:-${EXCLUDE_SCHEMAS:-}}"

# Set base directory and backup directory
base_dir="${BASE_DIR:-$dir/db-backup}"  # Default to $dir/db-backup if BASE_DIR is not set
backup_dir="${backup_dir:-${BASE_DIR:-$dir/db-backup}/postgres}"  # Use provided backup_dir, or default to BASE_DIR/n8n, or use fallback path

# Create base directory if it doesn't exist
mkdir -p "$base_dir"
log "Base directory set to: ${base_dir}"

# Create backup directory if it doesn't exist
mkdir -p "$backup_dir"
log "Backup directory set to: ${backup_dir}"

# Default system schemas to exclude
system_schemas="pg_catalog information_schema pg_toast"

# Combine system schemas with user-specified schemas to exclude
all_exclude_schemas="$system_schemas $exclude_schemas"

# Validate required parameters
[[ -z "$pass" ]] && handle_error "Database password not provided"

pg_dump_cmd="pg_dump"
psql_cmd="psql"
timestamp=$(date +%Y%m%d_%H%M%S)


# Check Docker environment if needed
if [[ "$use_docker" == "true" ]]; then
    command -v docker &>/dev/null || handle_error "Docker is not available"
    docker ps | grep -q "$service" || handle_error "PostgreSQL container '$service' is not running"
fi

# Function to list schemas
get_schemas() {
    local query="SELECT schema_name FROM information_schema.schemata"
    
    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -t -c "$query"
    else
        PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -t -c "$query"
    fi
}

# Function to check if a schema should be excluded
should_exclude() {
    local schema="$1"
    local excluded=false
    
    for exclude in $all_exclude_schemas; do
        if [[ "$schema" == "$exclude" ]]; then
            excluded=true
            break
        fi
    done
    
    echo "$excluded"
}

# Backup function for a single schema
backup_schema() {
    local schema=$(echo "$1" | tr -d '[:space:]')
    local output_dir="$2"
    local filename="$3"
    
    [[ -z "$schema" ]] && return
    
    log "Backing up schema: $schema to $filename"
    
    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" "$pg_dump_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -n "$schema" > "${output_dir}/${filename}.sql"
    else
        PGPASSWORD="$pass" "$pg_dump_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -n "$schema" -f "${output_dir}/${filename}.sql"
    fi
    
    # Check if backup was successful
    if [[ $? -ne 0 ]]; then
        log "WARNING: Failed to backup schema '$schema'"
        return 1
    fi
    
    return 0
}

# Create backup directory for schemas
schema_dir="${backup_dir}/${database}_${timestamp}"
mkdir -p "$schema_dir"
log "Backing up all schemas from database '$database'"

# Create manifest
manifest="${schema_dir}/manifest.txt"
echo "Database: $database" > "$manifest"
echo "Backup date: $(date)" >> "$manifest"
echo "Excluded schemas: $all_exclude_schemas" >> "$manifest" 
echo "Schemas:" >> "$manifest"

# Track success/failure
success_count=0
failure_count=0

# Backup each schema
while IFS= read -r schema; do
    schema=$(echo "$schema" | tr -d '[:space:]')
    [[ -z "$schema" ]] && continue
    
    # Check if this schema should be excluded
    excluded=$(should_exclude "$schema")
    if [[ "$excluded" == "true" ]]; then
        log "Skipping excluded schema: $schema"
        continue
    fi
    
    echo "- $schema" >> "$manifest"
    backup_schema "$schema" "$schema_dir" "${database}_${schema}_${timestamp}"
    
    if [[ $? -eq 0 ]]; then
        echo "  Status: SUCCESS" >> "$manifest"
        ((success_count++))
    else
        echo "  Status: FAILED" >> "$manifest"
        ((failure_count++))
    fi
done <<< "$(get_schemas)"

# Report results
log "Schema backup complete: $success_count schemas backed up successfully, $failure_count schemas failed"

# Archive the entire backup directory
if [[ "$compress" == "true" ]]; then
    archive_file="${backup_dir}/${database}_${timestamp}.tar.gz"
    log "Compressing backup directory to ${archive_file}"
    
    # Create tar.gz archive of the entire schema directory
    tar -czf "$archive_file" -C "$backup_dir" "$(basename "$schema_dir")"
    
    # Check if compression was successful
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
    # Remove old directories (in case compression failed)
    find "$backup_dir" -name "${database}_*" -type d -mtime "+$days_to_keep" -exec rm -rf {} \; 2>/dev/null || true
    # Remove old archives
    find "$backup_dir" -name "${database}_*.tar.gz" -type f -mtime "+$days_to_keep" -delete 2>/dev/null || true
fi

if [[ $failure_count -gt 0 ]]; then
    log "WARNING: Some schemas failed to backup. Check manifest for details."
    exit 1
else
    log "PostgreSQL schema backup completed successfully"
    exit 0
fi