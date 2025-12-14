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
        -db|--databases) shift; restore_databases="$1" ;;  # Changed from --database to --databases
        --docker) use_docker=true ;;
        --backup) shift; backup_file="$1" ;;
        --schemas) shift; specific_schemas="$1" ;;
        --list) list_only=true ;;
        --latest) use_latest=true ;;
        --all-databases) restore_all_databases=true ;;  # New flag
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
restore_databases="${restore_databases:-${PG_DATABASES:-}}"  # Changed from database to restore_databases
list_only="${list_only:-false}"
use_latest="${use_latest:-false}"
restore_all_databases="${restore_all_databases:-true}"
base_dir="${base_dir:-${RESTORE_DIR:-$dir/db-restore}}"  # Changed from db-restore to db-backup
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

# Convert comma-separated lists to arrays
IFS=',' read -ra restore_databases_array <<< "$restore_databases"
IFS=',' read -ra specific_schemas_array <<< "$specific_schemas"

# Set up
psql_cmd="psql"
temp_dir="/tmp/pg_restore_$$"

# Function to list available databases in backups
list_available_databases() {
    log "Available databases in backups:"

    # Find all database names from backup files/directories
    databases=()

    # Check for compressed backups
    for archive in "$backup_dir"/*.tar.gz; do
        [[ -f "$archive" ]] || continue
        db_name=$(basename "$archive" | grep -o '^[^_]*')
        if [[ -n "$db_name" && ! " ${databases[*]} " =~ " ${db_name} " ]]; then
            databases+=("$db_name")
        fi
    done

    # Check for uncompressed directories
    for dir in "$backup_dir"/*/; do
        [[ -d "$dir" ]] || continue
        db_name=$(basename "$dir" | grep -o '^[^_]*')
        if [[ -n "$db_name" && ! " ${databases[*]} " =~ " ${db_name} " ]]; then
            databases+=("$db_name")
        fi
    done

    if [[ ${#databases[@]} -eq 0 ]]; then
        log "No backup databases found in $backup_dir"
        exit 0
    fi

    echo "Available database backups:"
    for i in "${!databases[@]}"; do
        echo "  [$i] ${databases[$i]}"
    done
}

# Function to list available backups for a specific database
list_backups_for_database() {
    local database="$1"

    log "Available backups for database '$database':"

    archives=$(find "$backup_dir" -name "${database}_*.tar.gz" -type f | sort -r)
    directories=$(find "$backup_dir" -name "${database}_*" -type d | sort -r)

    if [[ -z "$archives" && -z "$directories" ]]; then
        log "No backups found for database '$database' in $backup_dir"
        return 1
    fi

    backups=()
    echo "Available backups for '$database':"
    index=0

    if [[ -n "$archives" ]]; then
        echo "Compressed archives:"
        for archive in $archives; do
            backup_name=$(basename "$archive")
            backup_date=$(echo "$backup_name" | grep -o '[0-9]\{8\}_[0-9]\{6\}')
            echo "  [$index] $backup_name (Date: ${backup_date:-unknown})"
            backups+=("$archive")
            ((index++))
        done
    fi

    if [[ -n "$directories" ]]; then
        echo "Uncompressed directories:"
        for directory in $directories; do
            backup_name=$(basename "$directory")
            backup_date=$(echo "$backup_name" | grep -o '[0-9]\{8\}_[0-9]\{6\}')
            echo "  [$index] $backup_name (Date: ${backup_date:-unknown})"
            backups+=("$directory")
            ((index++))
        done
    fi

    echo ""
    read -rp "Enter the number of the backup to select: " selected_index

    if ! [[ "$selected_index" =~ ^[0-9]+$ ]] || (( selected_index < 0 || selected_index >= ${#backups[@]} )); then
        echo "Invalid selection."
        return 1
    fi

    selected_backup="${backups[$selected_index]}"
    echo "Selected: $selected_backup"
    echo "$selected_backup"
}

# Function to get the latest backup for a database
get_latest_backup_for_database() {
    local database="$1"
    latest_archive=$(find "$backup_dir" -name "${database}_*.tar.gz" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -n 1)
    if [[ -z "$latest_archive" ]]; then
        latest_dir=$(find "$backup_dir" -name "${database}_*" -type d -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -n 1)
        echo "$latest_dir"
    else
        echo "$latest_archive"
    fi
}

# Function to get all databases from backup files
get_all_databases_from_backups() {
    declare -a databases

    # Check for compressed backups
    for archive in "$backup_dir"/*.tar.gz; do
        [[ -f "$archive" ]] || continue
        db_name=$(basename "$archive" | grep -o '^[^_]*')
        if [[ -n "$db_name" && ! " ${databases[*]} " =~ " ${db_name} " ]]; then
            databases+=("$db_name")
        fi
    done

    # Check for uncompressed directories
    for dir in "$backup_dir"/*/; do
        [[ -d "$dir" ]] || continue
        db_name=$(basename "$dir" | grep -o '^[^_]*')
        if [[ -n "$db_name" && ! " ${databases[*]} " =~ " ${db_name} " ]]; then
            databases+=("$db_name")
        fi
    done

    echo "${databases[@]}"
}

# Extract schemas from manifest
get_schemas_from_manifest() {
    local manifest_file="$1"
    grep "^- " "$manifest_file" | sed 's/^- //' | cut -d' ' -f1
}

# Restore schema
restore_schema() {
    local database="$1"
    local schema="$2"
    local sql_file="$3"

    log "Restoring database '$database', schema: $schema from $sql_file"
    local create_schema_sql="DROP SCHEMA IF EXISTS $schema CASCADE;"

    if [[ "$use_docker" == "true" ]]; then
        echo "$create_schema_sql" | docker exec -i -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database"
        docker exec -i -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" < "$sql_file"
    else
        echo "$create_schema_sql" | PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database"
        PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -f "$sql_file"
    fi

    return $?
}

# Restore a single database
restore_database() {
    local database="$1"
    local backup_path="$2"

    log "Starting restore for database: $database from $backup_path"

    local temp_db_dir="${temp_dir}/${database}_$(basename "$backup_path")"
    mkdir -p "$temp_db_dir"

    # Extract or copy backup
    if [[ -f "$backup_path" && "$backup_path" == *.tar.gz ]]; then
        log "Extracting archive for database '$database': $backup_path"
        tar -xzf "$backup_path" -C "$temp_db_dir" || {
            log "ERROR: Failed to extract archive for database '$database'"
            return 1
        }
        local extracted_dir=$(find "$temp_db_dir" -type d -name "${database}_*" | head -n 1)
        [[ -z "$extracted_dir" ]] && {
            log "ERROR: Failed to find extracted backup directory for database '$database'"
            return 1
        }
        local restore_dir="$extracted_dir"
    elif [[ -d "$backup_path" ]]; then
        log "Using uncompressed backup directory for database '$database': $backup_path"
        cp -r "$backup_path"/* "$temp_db_dir/" || {
            log "ERROR: Failed to copy backup files for database '$database'"
            return 1
        }
        local restore_dir="$temp_db_dir"
    else
        log "ERROR: Unsupported backup format for database '$database': $backup_path"
        return 1
    fi

    # Check for manifest
    local manifest="$restore_dir/manifest.txt"
    [[ ! -f "$manifest" ]] && {
        log "ERROR: Manifest file not found for database '$database'"
        return 1
    }

    # Create database if it doesn't exist
    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -c "DROP DATABASE IF EXISTS $database; CREATE DATABASE $database;" || {
            log "WARNING: Failed to drop/create database '$database', attempting to continue"
        }
    else
        PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -c "DROP DATABASE IF EXISTS $database; CREATE DATABASE $database;" || {
            log "WARNING: Failed to drop/create database '$database', attempting to continue"
        }
    fi

    # Determine which schemas to restore
    local schemas_to_restore
    if [[ ${#specific_schemas_array[@]} -gt 0 ]]; then
        log "Will restore only these schemas in database '$database': ${specific_schemas_array[*]}"
        schemas_to_restore="${specific_schemas_array[*]}"
    else
        schemas_to_restore=$(get_schemas_from_manifest "$manifest")
        log "Will restore all schemas from backup for database '$database'"
    fi

    local success_count=0
    local failure_count=0

    # Restore each schema
    for schema in $schemas_to_restore; do
        # Find SQL file for this schema
        local sql_file=$(find "$restore_dir" -name "${database}_${schema}_*.sql*" | head -n 1)

        if [[ -z "$sql_file" ]]; then
            log "WARNING: No backup file found for database '$database', schema '$schema'"
            ((failure_count++))
            continue
        fi

        # Handle compressed SQL files
        if [[ "$sql_file" == *.gz ]]; then
            log "Decompressing $sql_file"
            local decompressed_file="${sql_file%.gz}"
            gunzip -c "$sql_file" > "$decompressed_file" || {
                log "WARNING: Failed to decompress $sql_file"
                ((failure_count++))
                continue
            }
            sql_file="$decompressed_file"
        fi

        restore_schema "$database" "$schema" "$sql_file"
        if [[ $? -eq 0 ]]; then
            log "Successfully restored database '$database', schema '$schema'"
            ((success_count++))
        else
            log "ERROR: Failed to restore database '$database', schema '$schema'"
            ((failure_count++))
        fi
    done

    # Clean up temporary files for this database
    rm -rf "$temp_db_dir"

    echo "$success_count $failure_count"
}

# Main execution
if [[ "$list_only" == "true" ]]; then
    list_available_databases
    exit 0
fi

# Determine which databases to restore
declare -a databases_to_restore_array

if [[ "$restore_all_databases" == "true" ]]; then
    log "Restoring all databases from backups"
    databases_to_restore_array=($(get_all_databases_from_backups))
    if [[ ${#databases_to_restore_array[@]} -eq 0 ]]; then
        handle_error "No databases found in backups"
    fi
elif [[ ${#restore_databases_array[@]} -gt 0 ]]; then
    databases_to_restore_array=("${restore_databases_array[@]}")
else
    # Interactive mode: let user select database(s)
    list_available_databases
    echo ""
    read -rp "Enter database names (comma-separated) or 'all' for all databases: " db_input

    if [[ "$db_input" == "all" ]]; then
        databases_to_restore_array=($(get_all_databases_from_backups))
    else
        IFS=',' read -ra databases_to_restore_array <<< "$db_input"
    fi
fi

log "Databases to restore: ${databases_to_restore_array[*]}"

# Create temporary directory
mkdir -p "$temp_dir" || handle_error "Failed to create temporary directory"
log "Created temporary directory: $temp_dir"

# Validate docker is running if using docker
if [[ "$use_docker" == "true" ]]; then
    command -v docker &>/dev/null || handle_error "Docker is not available"
    docker ps | grep -q "$service" || handle_error "PostgreSQL container '$service' is not running"
fi

# Track overall restore results
total_success_databases=0
total_failure_databases=0
total_success_schemas=0
total_failure_schemas=0

# Restore each database
for database in "${databases_to_restore_array[@]}"; do
    database=$(echo "$database" | tr -d '[:space:]')
    [[ -z "$database" ]] && continue

    # Get backup for this database
    local selected_backup
    if [[ "$use_latest" == "true" ]]; then
        selected_backup=$(get_latest_backup_for_database "$database")
        if [[ -z "$selected_backup" ]]; then
            log "ERROR: No backups found for database '$database'"
            ((total_failure_databases++))
            continue
        fi
        log "Using latest backup for database '$database': $(basename "$selected_backup")"
    elif [[ -n "$backup_file" ]]; then
        selected_backup="$backup_file"
    else
        selected_backup=$(list_backups_for_database "$database")
        if [[ -z "$selected_backup" ]]; then
            log "ERROR: No backup selected for database '$database'"
            ((total_failure_databases++))
            continue
        fi
    fi

    [[ ! -e "$selected_backup" ]] && {
        log "ERROR: Backup file/directory does not exist for database '$database': $selected_backup"
        ((total_failure_databases++))
        continue
    }

    # Restore the database
    restore_result=$(restore_database "$database" "$selected_backup")
    db_success=$(echo "$restore_result" | awk '{print $1}')
    db_failure=$(echo "$restore_result" | awk '{print $2}')

    if [[ -z "$db_success" && -z "$db_failure" ]]; then
        log "ERROR: Failed to restore database '$database'"
        ((total_failure_databases++))
    else
        log "Database '$database' restore complete: $db_success schemas restored, $db_failure schemas failed"
        total_success_schemas=$((total_success_schemas + db_success))
        total_failure_schemas=$((total_failure_schemas + db_failure))

        if [[ $db_failure -eq 0 ]]; then
            ((total_success_databases++))
        else
            ((total_failure_databases++))
        fi
    fi
done

# Clean up
log "Cleaning up temporary files"
rm -rf "$temp_dir"

# Final summary
log "=== RESTORE COMPLETED ==="
log "Total databases attempted: ${#databases_to_restore_array[@]}"
log "Successfully restored databases: $total_success_databases"
log "Failed databases: $total_failure_databases"
log "Total schemas restored: $total_success_schemas"
log "Total schemas failed: $total_failure_schemas"

if [[ $total_failure_databases -gt 0 ]] || [[ $total_failure_schemas -gt 0 ]]; then
    log "WARNING: Some databases/schemas failed to restore"
    exit 1
else
    log "All PostgreSQL database restores completed successfully"
    exit 0
fi