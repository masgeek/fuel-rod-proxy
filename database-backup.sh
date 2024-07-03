#!/bin/bash

# Function to log messages
log() {
    local message="$1"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message"
}

# Function to send telemetry on errors
send_telemetry() {
    local error_message="$1"
    log "Sending telemetry on error: $error_message"
    #curl "https://cronitor.link/p/b5cbdedf915c4a22be135d4ae6d883c1/ya2G2O?state=fail&msg=$error_message"
}

# Function to handle errors
handle_error() {
    local error_message="$1"
    log "ERROR: $error_message"
    echo "ERROR: $error_message"
    # Add notification mechanism here (e.g., send email, notify via Slack)
    send_telemetry "$error_message"
    exit 1
}

# Load environment variables from .backup file if present
dir="$(dirname "$(realpath "$0")")"
if [[ -f "$dir/.backup" ]]; then
    export $(grep -v '^#' "$dir/.backup" | xargs)
    log "Exported environment variables"
fi

# Process command-line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -u|-user|--user)
            shift
            user="$1"
            ;;
        -p|-pass|--pass)
            shift
            pass="$1"
            ;;
        -s|-service|--service)
            shift
            service="$1"
            ;;
        -h|-host|--host)
            shift
            host="$1"
            ;;
        -t|-type|--type)
            shift
            dbType="$1"
            ;;
        -b|-backup|--backup)
            shift
            backup_type="$1"
            ;;
        *)
            handle_error "Invalid argument: $1"
            ;;
    esac
    shift
done

# Set default values
user="${user:-backup_user}"
service="${service:-maria}"
host="${host:-127.0.0.1}"
dbType="${dbType:-MariaDB}"  # Default to MariaDB if not provided
backup_type="${backup_type:-full}" # Default to full backup

# Check if password is not passed as a parameter
if [[ -z "$pass" && -n "$DB_PASS" ]]; then
    pass="$DB_PASS"
fi

# Validate input parameters
if [[ -z "$user" || -z "$pass" ]]; then
    handle_error "Username or password not provided"
fi

# Validate database type
case "${dbType,,}" in
    mariadb|mysql)
        ;;
    *)
        handle_error "Unsupported database type: $dbType"
        ;;
esac

# Validate backup type
case "${backup_type,,}" in
    full|incremental)
        ;;
    *)
        handle_error "Unsupported backup type: $backup_type"
        ;;
esac

# Perform backup
timestamp=$(date +%Y_%d%b_%H%M)
backup_dir="${dir}/db-backup"
mkdir -p "$backup_dir" || handle_error "Failed to create backup directory: $backup_dir"

log "Starting $backup_type database backup for $dbType at $timestamp"

# Run backup command based on database type and backup type
if [[ "${dbType,,}" == "mariadb" ]]; then
    dump_command="mariadb-dump"
    db_runner="mariadb"
elif [[ "${dbType,,}" == "mysql" ]]; then
    dump_command="mysqldump"
    db_runner="mysql"
fi

# Check database connection
if ! docker exec "${service}" "${db_runner}" -u "${user}" --password="${pass}" -h "${host}" -N -B -e 'SHOW schemas;' &>/dev/null; then
    handle_error "Unable to connect to the database"
fi

# Backup each schema
schemas=$(docker exec "${service}" "${db_runner}" -u "${user}" --password="${pass}" -h "${host}" -N -B -e 'SHOW schemas;')
while IFS= read -r schema; do
    case $schema in
        information_schema|mysql|performance_schema|sys|test)
            log "Skipping backup of $schema schema"
            ;;
        *)
            filename="${timestamp}_${schema}.sql"
            log "Dumping $schema with data to file: $filename"
            if [[ "${backup_type,,}" == "full" ]]; then
                docker exec "${service}" "$dump_command" --verbose --triggers --routines --events --no-tablespaces -u "${user}" --password="${pass}" "$schema" > "${backup_dir}/${filename}"
            elif [[ "${backup_type,,}" == "incremental" ]]; then
                docker exec "${service}" "$dump_command" --verbose --triggers --routines --events --no-tablespaces --incremental -u "${user}" --password="${pass}" "$schema" > "${backup_dir}/${filename}"
            fi

            # Add error handling for backup command
            if [[ $? -ne 0 ]]; then
                handle_error "Failed to dump $schema"
            fi

            # Replace charset in the dump file
            sed -i "s/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g" "${backup_dir}/${filename}"
            ;;
    esac
done <<< "$schemas"

log "Database backup completed successfully"
