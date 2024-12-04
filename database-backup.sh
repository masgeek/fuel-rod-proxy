#!/bin/bash

# Strict mode for better error handling
set -euo pipefail

# Logging and error handling functions
log() {
    local level="${1:-INFO}"
    local message="$2"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >&2
}

# Advanced error handling with optional exit
handle_error() {
    local message="$1"
    local exit_code="${2:-1}"
    
    log "ERROR" "$message"
    
    # Send telemetry (optional, can be configured)
    send_telemetry "$message" || true
    
    # Optional email or Slack notification
    send_notification "$message" || true
    
    # Exit only if requested
    if [[ "$exit_code" -ne 0 ]]; then
        exit "$exit_code"
    fi
}

# Optional telemetry function (can be customized)
send_telemetry() {
    local error_message="$1"
    # Example: curl to monitoring service
    if command -v curl &> /dev/null; then
        curl -s -m 5 "https://telemetry.example.com/report" \
            -d "message=$(printf '%s' "$error_message" | jq -sRr @uri)" \
            || return 1
    fi
}

# Optional notification function
send_notification() {
    local message="$1"
    # Example: Send email or Slack message
    if command -v sendmail &> /dev/null; then
        echo "$message" | sendmail -s "Backup Alert" admin@example.com
    fi
}

# Configuration and defaults
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${SCRIPT_DIR}/backup.conf"
readonly BACKUP_BASE_DIR="${BACKUP_DIR:-${SCRIPT_DIR}/db-backups}"

# Load configuration file
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        log "INFO" "Loaded configuration from $CONFIG_FILE"
    fi
}

# Secure password handling
get_password() {
    local password_file="${1:-}"
    
    # Priority: Command line > Environment > Password File > Prompt
    if [[ -n "${pass:-}" ]]; then
        echo "$pass"
        return 0
    fi
    
    if [[ -n "$password_file" && -r "$password_file" ]]; then
        cat "$password_file"
        return 0
    fi
    
    # Prompt securely if no other method works
    if [[ -t 0 ]]; then
        read -r -s -p "Enter database password: " pass
        echo
    else
        handle_error "No password provided"
    fi
}

# Validate and sanitize input
validate_input() {
    # Validate host
    if [[ ! "$host" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        handle_error "Invalid hostname format"
    fi
    
    # Validate username
    if [[ ! "$user" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        handle_error "Invalid username format"
    fi
}

# Detect database type if not specified
detect_database_type() {
    if [[ -z "${dbType:-}" ]]; then
        if command -v mariadb-dump &> /dev/null; then
            dbType="mariadb"
        elif command -v mysqldump &> /dev/null; then
            dbType="mysql"
        else
            handle_error "Could not detect database type"
        fi
    fi
}

# Flexible backup method selection
select_backup_method() {
    local preferred_method="${1:-auto}"
    
    case "$preferred_method" in
        docker)
            use_docker=true
            ;;
        direct)
            use_docker=false
            ;;
        auto)
            # Automatically detect best method
            if command -v docker &> /dev/null && docker ps &> /dev/null; then
                use_docker=true
            else
                use_docker=false
            fi
            ;;
        *)
            handle_error "Invalid backup method: $preferred_method"
            ;;
    esac
}

# Determine backup command based on database type
get_backup_command() {
    case "${dbType,,}" in
        mariadb)
            dump_command="mariadb-dump"
            db_runner="mariadb"
            ;;
        mysql)
            dump_command="mysqldump"
            db_runner="mysql"
            ;;
        *)
            handle_error "Unsupported database type: $dbType"
            ;;
    esac
}

# Main backup execution
perform_backup() {
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    
    # Create backup directory with permissions
    local backup_dir="${BACKUP_BASE_DIR}/${timestamp}"
    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir"
    
    # Get list of schemas to backup
    local schemas
    if [[ "$use_docker" == "true" ]]; then
        schemas=$(docker exec "$service" "$db_runner" -u "$user" --password="$pass" -h "$host" -N -B -e 'SHOW schemas;')
    else
        schemas=$("$db_runner" -u "$user" -p"$pass" -h "$host" -N -B -e 'SHOW schemas;')
    fi
    
    # Backup each schema
    while IFS= read -r schema; do
        # Skip system schemas
        [[ "$schema" =~ ^(information_schema|mysql|performance_schema|sys|test)$ ]] && continue
        
        local filename="${schema}.sql"
        local backup_path="${backup_dir}/${filename}"
        
        log "INFO" "Backing up schema: $schema"
        
        # Flexible backup options
        local backup_options=(
            "--verbose"
            "--triggers"
            "--routines"
            "--events"
            "--no-tablespaces"
            "--set-gtid-purged=OFF"  # Added for better replication support
        )
        
        # Execute backup
        if [[ "$use_docker" == "true" ]]; then
            docker exec "$service" "$dump_command" "${backup_options[@]}" \
                -u "$user" --password="$pass" "$schema" > "$backup_path"
        else
            "$dump_command" "${backup_options[@]}" \
                -u "$user" -p"$pass" -h "$host" "$schema" > "$backup_path"
        fi
        
        # Post-process dump file
        sed -i 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g' "$backup_path"
        sed -i '/\/\*M!100616 SET NOTE_VERBOSITY=@OLD_NOTE_VERBOSITY \*\//d' "$backup_path"
        
        # Compress backup
        gzip "$backup_path"
    done <<< "$schemas"
    
    # Optional: Rotate old backups
    rotate_backups
}

# Backup rotation management
rotate_backups() {
    local max_backups=10
    
    # Remove old backups, keeping last $max_backups
    find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -printf '%T@ %p\n' | 
        sort -n | 
        head -n "-$max_backups" | 
        cut -f2- -d' ' | 
        xargs -I {} rm -rf {}
}

# Parse command-line arguments
parse_arguments() {
    local OPTIND
    while getopts ":u:p:s:h:t:b:d:m:" opt; do
        case ${opt} in
            u ) user="$OPTARG" ;;
            p ) pass="$OPTARG" ;;
            s ) service="$OPTARG" ;;
            h ) host="$OPTARG" ;;
            t ) dbType="$OPTARG" ;;
            b ) backup_type="$OPTARG" ;;
            d ) BACKUP_BASE_DIR="$OPTARG" ;;
            m ) backup_method="$OPTARG" ;;
            \? ) handle_error "Invalid option: $OPTARG" ;;
        esac
    done
}

# Main script execution
main() {
    # Load configuration
    load_config
    
    # Parse arguments
    parse_arguments "$@"
    
    # Detect database type if not specified
    detect_database_type
    
    # Select backup method
    select_backup_method "${backup_method:-auto}"
    
    # Get backup command
    get_backup_command
    
    # Validate inputs
    validate_input
    
    # Get password securely
    pass=$(get_password "${PASSWORD_FILE:-}")
    
    # Perform backup
    perform_backup
    
    log "INFO" "Backup completed successfully"
}

# Run the main script
main "$@"