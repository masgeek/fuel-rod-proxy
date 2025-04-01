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
    export $(grep -v '^#' "$dir/.backup" | xargs)
    log "Exported environment variables from .backup file"
    
    # Print exported variables for verification (masking password)
    echo "DB_USERNAME=$DB_USERNAME"
    echo "DB_PASSWORD=****"  # Mask password for security
    echo "BACKUP_DIR=$BACKUP_DIR"
fi

# Parse command-line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -u|--user) shift; user="$1" ;;
        -p|--pass) shift; pass="$1" ;;
        -s|--service) shift; service="$1" ;;
        -h|--host) shift; host="$1" ;;
        --port) shift; port="$1" ;;
        -b|--backup-dir) shift; backup_dir="$1" ;;
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
user="${user:-${DB_USERNAME:-postgres}}"
pass="${pass:-${DB_PASSWORD:-}}"
service="${service:-${SERVICE:-postgres}}"
host="${host:-${HOST:-127.0.0.1}}"
port="${port:-${PORT:-5432}}"
backup_dir="${backup_dir:-${BACKUP_DIR:-$dir/db-backup/postgres}}"
use_docker="${use_docker:-${USE_DOCKER:-true}}"
database="${database:-${DB_SCHEMA:-postgres}}"
list_only="${list_only:-false}"
use_latest="${use_latest:-false}"

# Check for DB_USERNAME/DB_PASSWORD if user/pass not provided
if [[ -z "$user" && -n "$DB_USERNAME" ]]; then
    user="$DB_USERNAME"
    log "Using DB_USERNAME from .backup file"
fi

if [[ -z "$pass" && -n "$DB_PASSWORD" ]]; then
    pass="$DB_PASSWORD"
    log "Using DB_PASSWORD from .backup file"
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
    
    # List archives
    if [[ -n "$archives" ]]; then
        echo "Compressed archives:"
        for archive in $archives; do
            filename=$(basename "$archive")
            echo "  $filename"
        done
    fi
    
    # List directories
    if [[ -n "$directories" ]]; then
        echo "Uncompressed directories:"
        for directory in $directories; do
            dirname=$(basename "$directory")
            echo "  $dirname"
        done
    fi
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
    
    # Create schema if it doesn't exist
    create_schema_sql="CREATE SCHEMA IF NOT EXISTS $schema;"
    
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
    read -p "Enter backup name to restore: " backup_choice
    
    # Check if it's a compressed archive
    if [[ -f "$backup_dir/$backup_choice" ]]; then
        backup_file="$backup_dir/$backup_choice"
    # Check if it's a directory
    elif [[ -d "$backup_dir/$backup_choice" ]]; then
        backup_file="$backup_dir/$backup_choice"
    else
        handle_error "Invalid backup selection: $backup_choice"
    fi
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