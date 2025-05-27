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
    # Source the file to load variables into current script only
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

# Assign variables with priority: Command-line args > .backup file > Defaults
user="${user:-${PG_USERNAME:-postgres}}"
pass="${pass:-${PG_PASSWORD:-}}"
service="${service:-${SERVICE:-postgres}}"
host="${host:-${HOST:-127.0.0.1}}"
port="${port:-${PORT:-5432}}"
use_docker="${use_docker:-${USE_DOCKER:-true}}"
database="${database:-${PG_SCHEMA:-postgres}}"
list_only="${list_only:-false}"
use_latest="${use_latest:-false}"
# Set base directory and backup directory
base_dir="${RESTORE_DIR:-$dir/db-restore}"  # Default to $dir/db-backup if RESTORE_DIR is not set
backup_dir="${base_dir}/postgres"  # Use provided backup_dir, or default to RESTORE_DIR/postgres, or use fallback path


# Check for PG_USERNAME/PG_PASSWORD if user/pass not provided
if [[ -z "$user" && -n "$PG_USERNAME" ]]; then
    user="$PG_USERNAME"
    log "Using DB_USERNAME from .backup file"
fi

if [[ -z "$pass" && -n "$PG_PASSWORD" ]]; then
    pass="$PG_PASSWORD"
    log "Using PG_PASSWORD from .backup file"
fi

# Validate required parameters
if [[ -z "$pass" ]]; then
    handle_error "Database password not provided. Set with -p/--pass or in .backup file"
fi

# Set up commands and paths
psql_cmd="psql"
temp_dir="/tmp/pg_restore_$$"

# Function to list available backups
list_backups() {
    log "Available backups for database '$database':"
    
    # Look for compressed archives
    archives=$(find "$backup_dir" -name "${database}_*.tar.gz" -type f | sort)

    # Look for uncompressed backup directories
    directories=$(find "$backup_dir" -name "${database}_*" -type d | sort)

    if [[ -z "$archives" && -z "$directories" ]]; then
        log "No backups found in $backup_dir"
        exit 0
    fi

    # Store all backups in an array
    backups=()
    echo "Available backups:"
    index=0

    if [[ -n "$archives" ]]; then
        echo "Compressed archives:"
        for archive in $archives; do
            filename=$(basename "$archive")
            echo "  [$index] $filename"
            backups+=("$archive")
            ((index++))
        done
    fi

    if [[ -n "$directories" ]]; then
        echo "Uncompressed directories:"
        for directory in $directories; do
            dirname=$(basename "$directory")
            echo "  [$index] $dirname"
            backups+=("$directory")
            ((index++))
        done
    fi

    # Prompt the user to select a backup by index
    echo -n "Enter the number of the backup to select: "
    read -r selected_index

    if ! [[ "$selected_index" =~ ^[0-9]+$ ]] || (( selected_index < 0 || selected_index >= ${#backups[@]} )); then
        echo "Invalid selection."
        exit 1
    fi

    selected_backup="${backups[$selected_index]}"
    echo "You selected: $selected_backup"
    
    backup_file="$selected_backup"
}


# Function to get the latest backup
get_latest_backup() {
    # Check for latest compressed archive first
    latest_archive=$(find "$backup_dir" -name "${database}_*.tar.gz" -type f -print0 | xargs -0 ls -t | head -n 1)
    
    # If no compressed archive, check for latest directory
    if [[ -z "$latest_archive" ]]; then
        latest_dir=$(find "$backup_dir" -name "${database}_*" -type d -print0 | xargs -0 ls -t | head -n 1)
        echo "$latest_dir"
    else
        echo "$latest_archive"
    fi
}

# Function to extract schemas from a manifest file
get_schemas_from_manifest() {
    local manifest="$1"
    
    # Extract schema names from manifest file
    grep "^- " "$manifest" | sed 's/^- //'
}

# Function to restore a single schema
restore_schema() {
    local schema="$1"
    local sql_file="$2"
    
    log "Restoring schema: $schema from $sql_file"
    
  # Drop schema if it exists, then create it (CASCADE will remove all objects in the schema)
    create_schema_sql="DROP SCHEMA IF EXISTS $schema CASCADE; CREATE SCHEMA $schema;"
    
    if [[ "$use_docker" == "true" ]]; then
        echo "$create_schema_sql" | docker exec -i -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database"
        docker exec -i -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" < "$sql_file"
    else
        echo "$create_schema_sql" | PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" 
        PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -f "$sql_file"
    fi
    
    # Check if restore was successful
    if [[ $? -ne 0 ]]; then
        log "WARNING: Failed to restore schema '$schema'"
        return 1
    fi
    
    return 0
}

# Start of main script
if [[ "$list_only" == "true" ]]; then
    list_backups
    exit 0
fi

# Get backup to restore
if [[ "$use_latest" == "true" ]]; then
    backup_file=$(get_latest_backup)
    [[ -z "$backup_file" ]] && handle_error "No backups found for database '$database'"
    log "Using latest backup: $(basename "$backup_file")"
elif [[ -z "$backup_file" ]]; then
    list_backups
fi

# Check if backup file exists
[[ ! -e "$backup_file" ]] && handle_error "Backup file or directory does not exist: $backup_file"

# Prepare temporary directory
mkdir -p "$temp_dir" || handle_error "Failed to create temporary directory"
log "Created temporary directory: $temp_dir"

# Extract or copy backup files
if [[ -f "$backup_file" && "$backup_file" == *.tar.gz ]]; then
    # Extract compressed archive
    log "Extracting archive: $backup_file"
    tar -xzf "$backup_file" -C "$temp_dir" || handle_error "Failed to extract archive"
    
    # Find the extracted directory
    extracted_dir=$(find "$temp_dir" -type d -name "${database}_*" | head -n 1)
    [[ -z "$extracted_dir" ]] && handle_error "Failed to find extracted backup directory"
    
    restore_dir="$extracted_dir"
elif [[ -d "$backup_file" ]]; then
    # Copy directory contents
    log "Using uncompressed backup directory: $backup_file"
    cp -r "$backup_file"/* "$temp_dir/" || handle_error "Failed to copy backup files"
    restore_dir="$temp_dir"
else
    handle_error "Unsupported backup format: $backup_file"
fi

# Check Docker environment if needed
if [[ "$use_docker" == "true" ]]; then
    command -v docker &>/dev/null || handle_error "Docker is not available"
    docker ps | grep -q "$service" || handle_error "PostgreSQL container '$service' is not running"
fi

# Check for manifest file
manifest="$restore_dir/manifest.txt"
[[ ! -f "$manifest" ]] && handle_error "Manifest file not found in backup"

# Get list of schemas to restore
if [[ -n "$specific_schemas" ]]; then
    # User specified schemas to restore
    log "Will restore only these schemas: $specific_schemas"
    schemas_to_restore=$specific_schemas
else
    # Restore all schemas from the manifest
    schemas_to_restore=$(get_schemas_from_manifest "$manifest")
    log "Will restore all schemas found in manifest"
fi

# Ensure database exists
if [[ "$use_docker" == "true" ]]; then
    docker exec -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -c "CREATE DATABASE $database;" || true
else
    PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -c "CREATE DATABASE $database;" || true
fi

# Restore each schema
success_count=0
failure_count=0

for schema in $schemas_to_restore; do
    # Find the SQL file for this schema
    sql_file=$(find "$restore_dir" -name "${database}_${schema}_*.sql*" | head -n 1)
    
    # Handle gzipped SQL files
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
    
    # Restore the schema
    restore_schema "$schema" "$sql_file"
    
    if [[ $? -eq 0 ]]; then
        ((success_count++))
    else
        ((failure_count++))
    fi
done

# Clean up temporary directory
log "Cleaning up temporary files"
rm -rf "$temp_dir"

# Report results
log "Restore complete: $success_count schemas restored successfully, $failure_count schemas failed"

if [[ $failure_count -gt 0 ]]; then
    log "WARNING: Some schemas failed to restore"
    exit 1
else
    log "PostgreSQL database restore completed successfully"
    exit 0
fi