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
    curl -s "https://cronitor.link/p/b5cbdedf915c4a22be135d4ae6d883c1/ya2G2O?state=fail&msg=$error_message" > /dev/null
}

# Function to handle errors
handle_error() {
    local error_message="$1"
    log "ERROR: $error_message"
    echo "ERROR: $error_message"
    send_telemetry "$error_message"
    exit 1
}

# Load environment variables from .backup file if present
dir="$(dirname "$(realpath "$0")")"
if [[ -f "$dir/.backup" ]]; then
    export $(grep -v '^#' "$dir/.backup" | xargs)
    log "Exported environment variables"
fi

# Parse command-line arguments
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
        -d|-dir|--backup-dir)
            shift
            backup_dir="$1"
            ;;
        --docker)
            use_docker=true
            ;;
        *)
            handle_error "Invalid argument: $1"
            ;;
    esac
    shift
done

# Set default values
service="${service:-maria}"
host="${host:-127.0.0.1}"
dbType="${dbType:-MariaDB}"  # Default to MariaDB if not provided
backup_type="${backup_type:-full}" # Default to full backup
backup_dir="${BACKUP_DIR:-$dir/db-backup}"  # Default to $dir/db-backup if BACKUP_DIR is not set
use_docker="${use_docker:-false}"

# Check if user is not passed as a parameter
if [[ -z "$user" && -n "$DB_USER" ]]; then
    user="$DB_USER"
fi

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

# Determine backup command based on database type
if [[ "${dbType,,}" == "mariadb" ]]; then
    dump_command="mariadb-dump"
    db_runner="mariadb"
elif [[ "${dbType,,}" == "mysql" ]]; then
    dump_command="mysqldump"
    db_runner="mysql"
fi

# Perform Docker or direct backup based on --docker flag
if [[ "$use_docker" == "true" ]]; then
    # Docker backup method
    if ! command -v docker &> /dev/null; then
        handle_error "Docker is not available, cannot perform Docker backup for"
    fi

    # Check database connection via Docker
    if ! docker exec "${service}" "${db_runner}" -u "${user}" --password="${pass}" -h "${host}" -N -B -e 'SHOW schemas;' &>/dev/null; then
        handle_error "Unable to connect to the database via Docker"
    fi

    # Docker backup execution
    docker_exec_prefix="docker exec ${service}"
    schemas=$(${docker_exec_prefix} "${db_runner}" -u "${user}" --password="${pass}" -h "${host}" -N -B -e 'SHOW schemas;')
else
    # Direct database backup method
    # Check if necessary tools are available
    if ! command -v "$dump_command" &> /dev/null; then
        handle_error "$dump_command is not available. Please install database client tools."
    fi

    # Check direct database connection
    if ! "${db_runner}" -u "${user}" -p"${pass}" -h "${host}" -N -B -e 'SHOW schemas;' &>/dev/null; then
        handle_error "Unable to connect to the database directly"
    fi

    # Direct execution
    docker_exec_prefix=""
    schemas=$(${db_runner} -u "${user}" -p"${pass}" -h "${host}" -N -B -e 'SHOW schemas;')
fi

# Create backup directory
timestamp=$(date +%Y_%d%b_%H%M)
mkdir -p "$backup_dir" || handle_error "Failed to create backup directory: $backup_dir"

log "Starting $backup_type database backup for $dbType at $timestamp"

# Backup each schema
while IFS= read -r schema; do
    case $schema in
        information_schema|mysql|performance_schema|sys|test)
            log "Skipping backup of $schema schema"
            ;;
        *)
            filename="${timestamp}_${schema}.sql"
            log "Dumping $schema with data to file: $filename"
            
            # Determine backup command based on backup type
            if [[ "${backup_type,,}" == "full" ]]; then
                backup_options="--verbose --triggers --routines --events --no-tablespaces"
            elif [[ "${backup_type,,}" == "incremental" ]]; then
                backup_options="--verbose --triggers --routines --events --no-tablespaces --incremental"
            fi

            # Execute backup
            if [[ "$use_docker" == "true" ]]; then
                ${docker_exec_prefix} "$dump_command" $backup_options -u "${user}" --password="${pass}" "$schema" > "${backup_dir}/${filename}"
            else
                "$dump_command" $backup_options -u "${user}" -p"${pass}" -h "${host}" "$schema" > "${backup_dir}/${filename}"
            fi

            # Check backup result
            if [[ $? -ne 0 ]]; then
                handle_error "Failed to dump $schema"
            fi

            # Post-processing of dump file
            sed -i "s/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g" "${backup_dir}/${filename}"
            sed -i "/\/\*M!100616 SET NOTE_VERBOSITY=@OLD_NOTE_VERBOSITY \*\//d" "${backup_dir}/${filename}"
            ;;
    esac
done <<< "$schemas"

log "Database backup completed successfully"