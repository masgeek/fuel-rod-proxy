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
        -db|--databases) shift; databases="$1" ;;  # Changed from --database to --databases
        --docker) use_docker=true ;;
        --compress) compress=true ;;
        --keep-days) shift; days_to_keep="$1" ;;
        --exclude) shift; exclude_schemas="$1" ;;
        --schemas) shift; selected_schemas="$1" ;;
        --all-databases) backup_all_databases=true ;;
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
databases="${databases:-${PG_DATABASES:-}}"  # Changed from database to databases
compress="${compress:-${COMPRESS:-true}}"
days_to_keep="${days_to_keep:-${DAYS_TO_KEEP:-7}}"
exclude_schemas="${exclude_schemas:-${EXCLUDE_SCHEMAS:-}}"
selected_schemas="${selected_schemas:-${SELECTED_SCHEMAS:-}}"
backup_all_databases="${backup_all_databases:-${BACKUP_ALL_DATABASES:-false}}"

# Convert comma-separated lists to arrays
IFS=',' read -ra databases_array <<< "$databases"
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

# Validate required parameters
[[ -z "$pass" ]] && handle_error "Database password not provided"

# Check if we have databases to backup
if [[ "$backup_all_databases" != "true" && ${#databases_array[@]} -eq 0 ]]; then
    handle_error "No databases specified. Use --databases or --all-databases"
fi

pg_dump_cmd="pg_dump"
psql_cmd="psql"
timestamp=$(date +%Y%m%d_%H%M%S)

# Function to list all databases
get_all_databases() {
    local query="SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres'"

    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "postgres" -t -c "$query"
    else
        PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "postgres" -t -c "$query"
    fi
}

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

# Function to backup a single schema in a database
backup_schema() {
    local database="$1"
    local schema="$2"
    local output_dir="$3"
    local filename="$4"

    [[ -z "$schema" ]] && return

    log "Backing up database '$database', schema: $schema to $filename.sql"

    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" "$pg_dump_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -n "$schema" > "${output_dir}/${filename}.sql"
    else
        PGPASSWORD="$pass" "$pg_dump_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -n "$schema" -f "${output_dir}/${filename}.sql"
    fi

    if [[ $? -ne 0 ]]; then
        log "WARNING: Failed to backup database '$database', schema '$schema'"
        return 1
    fi

    return 0
}

# Function to validate database exists
validate_database_exists() {
    local database="$1"
    local query="SELECT 1 FROM pg_database WHERE datname = '$database'"
    local exists

    if [[ "$use_docker" == "true" ]]; then
        exists=$(docker exec -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "postgres" -t -c "$query")
    else
        exists=$(PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "postgres" -t -c "$query")
    fi

    exists=$(echo "$exists" | tr -d '[:space:]')
    [[ -n "$exists" ]] && echo "true" || echo "false"
}

# Function to validate schema exists in database
validate_schema_exists() {
    local database="$1"
    local schema="$2"
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

# Function to list schemas in a database
get_schemas_in_database() {
    local database="$1"
    local query="SELECT schema_name FROM information_schema.schemata"

    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -t -c "$query"
    else
        PGPASSWORD="$pass" "$psql_cmd" -U "$user" -h "$host" -p "$port" -d "$database" -t -c "$query"
    fi
}

# Function to backup a single database
backup_database() {
    local database="$1"

    # Create database-specific backup directory
    local db_backup_dir="${backup_dir}/${database}_${timestamp}"
    mkdir -p "$db_backup_dir"

    # Create manifest for this database
    local manifest="${db_backup_dir}/manifest.txt"
    echo "Database: $database" > "$manifest"
    echo "Backup date: $(date)" >> "$manifest"
    echo "Excluded schemas: ${all_exclude_schemas_array[*]}" >> "$manifest"
    echo "Schemas to backup:" >> "$manifest"

    # Track success/failure for this database
    local db_success_count=0
    local db_failure_count=0
    local -a db_missing_schemas_array

    # Determine which schemas to backup in this database
    declare -a schemas_to_backup_array

    if [[ ${#selected_schemas_array[@]} -gt 0 ]]; then
        log "Backing up selected schemas from database '$database'"
        schemas_to_backup_array=("${selected_schemas_array[@]}")
    else
        log "Backing up all non-system schemas from database '$database'"
        # Get all schemas from database
        local all_schemas
        all_schemas=$(get_schemas_in_database "$database")

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

    # Backup each schema in this database
    for schema in "${schemas_to_backup_array[@]}"; do
        # Validate schema exists
        exists=$(validate_schema_exists "$database" "$schema")

        if [[ "$exists" == "false" ]]; then
            log "WARNING: Schema '$schema' does not exist in database '$database'"
            db_missing_schemas_array+=("$schema")
            echo "- $schema" >> "$manifest"
            echo "  Status: MISSING" >> "$manifest"
            ((db_failure_count++))
            continue
        fi

        log "Backing up database '$database', schema: $schema"
        echo "- $schema" >> "$manifest"

        backup_schema "$database" "$schema" "$db_backup_dir" "${database}_${schema}_${timestamp}"

        if [[ $? -eq 0 ]]; then
            echo "  Status: SUCCESS" >> "$manifest"
            ((db_success_count++))
        else
            echo "  Status: FAILED" >> "$manifest"
            ((db_failure_count++))
        fi
    done

    # Add summary to manifest
    echo "" >> "$manifest"
    echo "=== SUMMARY ===" >> "$manifest"
    echo "Database: $database" >> "$manifest"
    echo "Total schemas attempted: ${#schemas_to_backup_array[@]}" >> "$manifest"
    echo "Successfully backed up: $db_success_count" >> "$manifest"
    echo "Failed: $db_failure_count" >> "$manifest"

    if [[ ${#db_missing_schemas_array[@]} -gt 0 ]]; then
        echo "Missing schemas: ${db_missing_schemas_array[*]}" >> "$manifest"
    fi

    # Compress this database backup if requested
    if [[ "$compress" == "true" ]]; then
        local archive_file="${backup_dir}/${database}_${timestamp}.tar.gz"
        log "Compressing backup for database '$database' to ${archive_file}"
        tar -czf "$archive_file" -C "$backup_dir" "$(basename "$db_backup_dir")"
        if [[ $? -eq 0 ]]; then
            log "Compression successful for '$database', removing original backup directory"
            rm -rf "$db_backup_dir"
        else
            log "WARNING: Compression failed for '$database', keeping original backup directory"
        fi
    fi

    return $db_failure_count
}

# Main backup process
total_success_count=0
total_failure_count=0
declare -a missing_databases_array

# Determine which databases to backup
declare -a databases_to_backup_array

if [[ "$backup_all_databases" == "true" ]]; then
    log "Backing up all databases"
    all_databases=$(get_all_databases)

    while IFS= read -r db; do
        db=$(echo "$db" | tr -d '[:space:]')
        [[ -z "$db" ]] && continue
        databases_to_backup_array+=("$db")
    done <<< "$all_databases"
else
    databases_to_backup_array=("${databases_array[@]}")
fi

log "Found ${#databases_to_backup_array[@]} databases to backup: ${databases_to_backup_array[*]}"

# Backup each database
for database in "${databases_to_backup_array[@]}"; do
    database=$(echo "$database" | tr -d '[:space:]')
    [[ -z "$database" ]] && continue

    # Validate database exists
    exists=$(validate_database_exists "$database")

    if [[ "$exists" == "false" ]]; then
        log "ERROR: Database '$database' does not exist"
        missing_databases_array+=("$database")
        ((total_failure_count++))
        continue
    fi

    log "Starting backup for database: $database"

    # Create a summary log for this database
    db_log_file="${backup_dir}/${database}_${timestamp}.log"

    # Backup the database (redirect output to log file)
    backup_database "$database" >> "$db_log_file" 2>&1
    db_exit_code=$?

    if [[ $db_exit_code -eq 0 ]]; then
        log "Database '$database' backup completed successfully"
        ((total_success_count++))
    else
        log "Database '$database' backup had failures"
        ((total_failure_count++))
    fi
done

# Cleanup old backups for each database
if [[ -n "$days_to_keep" && "$days_to_keep" -gt 0 ]]; then
    log "Removing backups older than $days_to_keep days for all databases"

    for database in "${databases_to_backup_array[@]}"; do
        database=$(echo "$database" | tr -d '[:space:]')
        [[ -z "$database" ]] && continue

        log "Cleaning up old backups for database: $database"
        find "$backup_dir" -name "${database}_*" -type d -mtime "+$days_to_keep" -exec rm -rf {} \; 2>/dev/null || true
        find "$backup_dir" -name "${database}_*.tar.gz" -type f -mtime "+$days_to_keep" -delete 2>/dev/null || true
        find "$backup_dir" -name "${database}_*.log" -type f -mtime "+$days_to_keep" -delete 2>/dev/null || true
    done
fi

# Create overall summary log
summary_log="${backup_dir}/backup_summary_${timestamp}.log"
echo "=== BACKUP SUMMARY ===" > "$summary_log"
echo "Backup date: $(date)" >> "$summary_log"
echo "Total databases attempted: ${#databases_to_backup_array[@]}" >> "$summary_log"
echo "Successfully backed up: $total_success_count" >> "$summary_log"
echo "Failed: $total_failure_count" >> "$summary_log"

if [[ ${#missing_databases_array[@]} -gt 0 ]]; then
    echo "" >> "$summary_log"
    echo "Missing databases:" >> "$summary_log"
    for db in "${missing_databases_array[@]}"; do
        echo "  - $db" >> "$summary_log"
    done
fi

echo "" >> "$summary_log"
echo "Databases backed up:" >> "$summary_log"
for db in "${databases_to_backup_array[@]}"; do
    if [[ " ${missing_databases_array[*]} " =~ " ${db} " ]]; then
        echo "  - $db: FAILED (database not found)" >> "$summary_log"
    else
        echo "  - $db: SUCCESS" >> "$summary_log"
    fi
done

# Final exit
log "=== BACKUP COMPLETED ==="
log "Total databases: ${#databases_to_backup_array[@]}"
log "Successful: $total_success_count"
log "Failed: $total_failure_count"

if [[ ${#missing_databases_array[@]} -gt 0 ]]; then
    log "Missing databases: ${missing_databases_array[*]}"
fi

if [[ $total_failure_count -gt 0 ]]; then
    log "WARNING: Some databases failed to backup. Check summary log for details."
    cat "$summary_log"
    exit 1
else
    log "All PostgreSQL database backups completed successfully"
    exit 0
fi