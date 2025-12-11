#!/bin/bash
set -euo pipefail

###############################################
# Logging + Errors
###############################################
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

fail() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

###############################################
# Load .backup env if present
###############################################
dir="$(dirname "$(realpath "$0")")"

if [[ -f "$dir/.backup" ]]; then
    source "$dir/.backup"
    log "Loaded .backup environment"
fi

###############################################
# CLI arguments
###############################################
user=""
pass=""
host=""
port=""
database=""
backup_file=""
list_only=false
use_latest=false
use_docker=true
db_type="mysql"
service=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)       shift; user="$1" ;;
        -p|--pass)       shift; pass="$1" ;;
        -h|--host)       shift; host="$1" ;;
        --port)          shift; port="$1" ;;
        -db|--database)  shift; database="$1" ;;
        -b|--base-dir)   shift; base_dir="$1" ;;
        --backup)        shift; backup_file="$1" ;;
        --docker)        use_docker=true ;;
        --list)          list_only=true ;;
        --latest)        use_latest=true ;;
        --type)          shift; db_type="$1" ;; # mysql | mariadb
        --service)       shift; service="$1" ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
    shift
done

###############################################
# Defaults
###############################################
user="${user:-${DB_USERNAME:-root}}"
pass="${pass:-${DB_PASSWORD:-}}"
host="${host:-${DB_HOST:-127.0.0.1}}"
port="${port:-${DB_PORT:-3306}}"
database="${database:-${DB_SCHEMA:-test}}"
service="${service:-${SERVICE:-maria}}"
base_dir="${base_dir:-$dir/db-restore}"
backup_dir="${backup_dir:-$base_dir/$db_type}"

[[ -z "$user" ]] && fail "User cannot be empty"
[[ -z "$database" ]] && fail "Database cannot be empty"
[[ -z "$backup_dir" ]] && fail "Backup dir invalid"

###############################################
# Select command (mysql / mariadb)
###############################################
if [[ "$use_docker" == true ]]; then
    # Detect actual client inside container
    if docker exec "$service" which mysql >/dev/null 2>&1; then
        db_cmd="mysql"
    elif docker exec "$service" which mariadb >/dev/null 2>&1; then
        db_cmd="mariadb"
    else
        fail "Neither mysql nor mariadb client exists inside container '$service'"
    fi
else
    # Host mode - default to system command
    case "$db_type" in
        mysql) db_cmd="mysql" ;;
        mariadb) db_cmd="mariadb" ;;
        *) fail "Invalid db type: $db_type" ;;
    esac
fi


# mysql uses -P, mariadb prefers --port
if [[ "$db_type" == "mariadb" ]]; then
    port_arg="--port=$port"
else
    port_arg="-P$port"
fi

###############################################
# Helper: List backups
###############################################
list_backups() {
    log "Searching in: $backup_dir"

    mapfile -t files < <(find "$backup_dir" -type f -name "*_${database}.sql.zip" | sort)

    if (( ${#files[@]} == 0 )); then
        log "No backups found."
        exit 0
    fi

    echo "Backups:"
    for i in "${!files[@]}"; do
        printf " [%d] %s\n" "$i" "$(basename "${files[$i]}")"
    done

    echo -n "Select number: "
    read -r idx

    [[ "$idx" =~ ^[0-9]+$ ]] || fail "Invalid selection"
    (( idx < ${#files[@]} )) || fail "Out of range"

    backup_file="${files[$idx]}"
    echo "Selected: $backup_file"
}

###############################################
# Helper: Get latest backup safely
###############################################
get_latest_backup() {
    find "$backup_dir" -type f -name "*_${database}.sql.zip" \
        -printf '%T@ %p\n' \
        | sort -nr \
        | head -n 1 \
        | cut -d' ' -f2-
}

###############################################
# List only mode
###############################################
if [[ "$list_only" == true ]]; then
    list_backups
    exit 0
fi

###############################################
# Determine backup file
###############################################
if [[ "$use_latest" == true ]]; then
    backup_file=$(get_latest_backup)
    [[ -z "$backup_file" ]] && fail "No backups found for $database"
    log "Using latest backup: $(basename "$backup_file")"
elif [[ -z "$backup_file" ]]; then
    list_backups
fi

[[ -f "$backup_file" ]] || fail "Backup file not found: $backup_file"

###############################################
# Extract backup
###############################################
temp_dir="/tmp/mysql_restore_$$"
mkdir -p "$temp_dir"

log "Extracting: $(basename "$backup_file")"
unzip -q "$backup_file" -d "$temp_dir" || fail "Unzip failed"

sql_file=$(find "$temp_dir" -name "*.sql" | head -n 1)
[[ -z "$sql_file" ]] && fail "No .sql file in archive"


if [[ "$use_docker" == true ]]; then
    log "Running in DOCKER mode → container: $service (db_cmd=$db_cmd)"
else
    log "Running on HOST → direct execution (db_cmd=$db_cmd)"
fi

###############################################
# Create database safely
create_sql="CREATE DATABASE IF NOT EXISTS \`$database\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
log "Creating database '$database' if not exists ..."

if [[ "$use_docker" == true ]]; then
    echo "$create_sql" | docker exec -i "$service" \
        env MYSQL_PWD="$pass" \
        $db_cmd -u"$user" -h"$host" $port_arg \
        || fail "DB creation failed"
else
    echo "$create_sql" | env MYSQL_PWD="$pass" \
        $db_cmd -u"$user" -h"$host" $port_arg \
        || fail "DB creation failed"
fi

###############################################
# Restore
###############################################
log "Restoring into '$database' ..."

if [[ "$use_docker" == true ]]; then
    docker exec -i "$service" \
        env MYSQL_PWD="$pass" \
        $db_cmd -u"$user" -h"$host" $port_arg "$database" < "$sql_file" \
        || fail "Restore failed"
else
    env MYSQL_PWD="$pass" \
        $db_cmd -u"$user" -h"$host" $port_arg "$database" < "$sql_file" \
        || fail "Restore failed"
fi

log "Restore successful."

###############################################
# Clean temp
###############################################
rm -rf "$temp_dir"
log "Cleanup done."

exit 0
