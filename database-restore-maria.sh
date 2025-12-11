#!/bin/bash

# Logging helper
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Error handler
handle_error() {
    log "ERROR: $1"
    exit 1
}

# Load .backup env if present
dir="$(dirname "$(realpath "$0")")"
if [[ -f "$dir/.backup" ]]; then
    # Source the file to load variables into current script only
    source "$dir/.backup"
    log "Loaded environment variables from .backup file"
fi

# Parse CLI args
while [ $# -gt 0 ]; do
    case "$1" in
        -u|--user) shift; user="$1" ;;
        -p|--pass) shift; pass="$1" ;;
        -h|--host) shift; host="$1" ;;
        --port) shift; port="$1" ;;
        -b|--base-dir) shift; base_dir="$1" ;;
        -db|--database) shift; database="$1" ;;
        --docker) use_docker=true ;;
        --backup) shift; backup_file="$1" ;;
        --list) list_only=true ;;
        --latest) use_latest=true ;;
        --type) shift; db_type="$1" ;; # mysql or mariadb
        *) handle_error "Unknown arg: $1" ;;
    esac
    shift
done

# Defaults
user="${user:-${DB_USERNAME:-root}}"
pass="${pass:-${DB_PASSWORD:-}}"
host="${host:-127.0.0.1}"
port="${port:-3306}"
database="${database:-${DB_SCHEMA:-test}}"
use_docker="${use_docker:-false}"
list_only="${list_only:-false}"
use_latest="${use_latest:-false}"
base_dir="${base_dir:-$dir/db-restore}"
backup_dir="${backup_dir:-$base_dir/mysql}"
db_type="${db_type:-mysql}" # or mariadb

[[ -z "$pass" ]] && handle_error "No DB password provided."

# Choose command
case "$db_type" in
    mysql) db_cmd="mysql" ;;
    mariadb) db_cmd="mariadb" ;;
    *) handle_error "Invalid db type: $db_type (use 'mysql' or 'mariadb')" ;;
esac

temp_dir="/tmp/mysql_restore_$$"

# Backup listing
list_backups() {
    log "Looking for backups for '$database'..."
    archives=$(find "$backup_dir" -type f -name "*_${database}.sql.zip" | sort)

    if [[ -z "$archives" ]]; then
        log "No backups found for '$database'"
        exit 0
    fi

    backups=()
    index=0
    echo "Backups:"
    for file in $archives; do
        echo "  [$index] $(basename "$file")"
        backups+=("$file")
        ((index++))
    done

    echo -n "Select number: "
    read -r selected_index
    if ! [[ "$selected_index" =~ ^[0-9]+$ ]] || (( selected_index < 0 || selected_index >= ${#backups[@]} )); then
        echo "Invalid selection."
        exit 1
    fi

    backup_file="${backups[$selected_index]}"
    echo "Selected: $backup_file"
}

# Get latest backup
get_latest_backup() {
    find "$backup_dir" -type f -name "*_${database}.sql.zip" -print0 | xargs -0 ls -t | head -n 1
}

# Short-circuit if listing only
if [[ "$list_only" == "true" ]]; then
    list_backups
    exit 0
fi

# Determine backup file
if [[ "$use_latest" == "true" ]]; then
    backup_file=$(get_latest_backup)
    [[ -z "$backup_file" ]] && handle_error "No backups found for '$database'"
    log "Using latest backup: $(basename "$backup_file")"
elif [[ -z "$backup_file" ]]; then
    list_backups
fi

# Validate backup file
[[ ! -e "$backup_file" ]] && handle_error "Backup file not found: $backup_file"

# Prepare temp dir
mkdir -p "$temp_dir" || handle_error "Failed to create temp dir"
log "Extracting: $(basename "$backup_file")"
unzip -q "$backup_file" -d "$temp_dir" || handle_error "Unzip failed"
sql_file=$(find "$temp_dir" -name "*.sql" | head -n 1)
[[ -z "$sql_file" ]] && handle_error "No .sql file found inside archive"

# Create DB if not exists
create_db_sql="CREATE DATABASE IF NOT EXISTS \`$database\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
if [[ "$use_docker" == "true" ]]; then
    echo "$create_db_sql" | docker exec -i "$service" $db_cmd -u"$user" -p"$pass" -h"$host" -P"$port"
else
    echo "$create_db_sql" | $db_cmd -u"$user" -p"$pass" -h"$host" -P"$port"
fi

# Restore
log "Restoring into '$database' using $db_cmd..."
if [[ "$use_docker" == "true" ]]; then
    docker exec -i "$service" $db_cmd -u"$user" -p"$pass" -h"$host" -P"$port" "$database" < "$sql_file"
else
    $db_cmd -u"$user" -p"$pass" -h"$host" -P"$port" "$database" < "$sql_file"
fi

# Check result
if [[ $? -eq 0 ]]; then
    log "Restore successful"
else
    handle_error "Restore failed"
fi

# Cleanup
rm -rf "$temp_dir"
log "Cleanup done"

exit 0
# End of script