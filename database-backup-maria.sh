#!/bin/bash

# -------- Logging & Error Handling --------
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

send_telemetry() {
    [[ -n "$MONITOR_URL" ]] && curl -s "${MONITOR_URL}?state=fail&msg=$1" > /dev/null
}

fail() {
    log "ERROR: $1"
    send_telemetry "$1"
    exit 1
}

# -------- Env Setup --------
load_env_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        export $(grep -v '^#' "$file" | xargs)
        log "Loaded environment from $file"
    fi
}

# -------- Backup Directory --------
init_backup_dir() {
    local dir="$1"
    mkdir -p "$dir" || fail "Failed to create backup directory: $dir"
    log "Backup directory set to: $dir"
}

# -------- Cleanup --------
cleanup_old_backups() {
    local path="$1"
    local days="$2"
    log "Cleaning up backups older than $days days in $path"
    find "$path" -type f -name "*.sql" -mtime +"$days" -exec rm -f {} \; || fail "Failed to clean up old backups"
}

# -------- Command Line Parser --------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -u|--user) shift; user="$1" ;;
            -p|--pass) shift; pass="$1" ;;
            -s|--service) shift; service="$1" ;;
            -h|--host) shift; host="$1" ;;
            -t|--type) shift; db_type="$1" ;;
            -b|--backup) shift; backup_type="$1" ;;
            -d|--backup-dir) shift; backup_dir="$1" ;;
            --docker) use_docker=true ;;
            --cleanup)
                cleanup_enabled=true
                [[ "$2" =~ ^[0-9]+$ ]] && cleanup_days="$2" && shift || cleanup_days=7
                ;;
            *) fail "Invalid argument: $1" ;;
        esac
        shift
    done
}

# -------- Validate Inputs --------
validate_config() {
    [[ -z "$user" || -z "$pass" ]] && fail "Username or password not provided"
    [[ ! "$db_type" =~ ^(mariadb|mysql)$ ]] && fail "Unsupported DB type: $db_type"
    [[ ! "$backup_type" =~ ^(full|incremental)$ ]] && fail "Unsupported backup type: $backup_type"
}

# -------- Get Schema List --------
get_schemas() {
    local runner="$1"
    local exec_prefix="$2"
    local query='SHOW schemas;'

    if [[ "$use_docker" == "true" ]]; then
        $exec_prefix "$runner" -u "$user" --password="$pass" -h "$host" -N -B -e "$query"
    else
        $runner -u "$user" -p"$pass" -h "$host" -N -B -e "$query"
    fi
}

# -------- Dump Schema --------
dump_schema() {
    local schema="$1"
    local outfile="$2"
    local runner="$3"
    local exec_prefix="$4"
    local options="--verbose --triggers --routines --events --no-tablespaces"

    [[ "$backup_type" == "incremental" ]] && options="$options --incremental"

    log "Dumping $schema -> $outfile"
    if [[ "$use_docker" == "true" ]]; then
        $exec_prefix "$runner" $options -u "$user" --password="$pass" "$schema" > "$outfile"
    else
        "$runner" $options -u "$user" -p"$pass" -h "$host" "$schema" > "$outfile"
    fi

    [[ $? -ne 0 ]] && fail "Failed to dump $schema"

    # Fix potential character set issues
    sed -i "s/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g" "$outfile"
    sed -i "/\/\*M!100616 SET NOTE_VERBOSITY=@OLD_NOTE_VERBOSITY \*\//d" "$outfile"
}

# -------- Main Execution --------
main() {
    script_dir="$(dirname "$(realpath "$0")")"
    load_env_file "$script_dir/.backup"

    parse_args "$@"

    # Assign variables with priority: Command-line args > .backup file > hardcoded defaults
    user="${user:-${DB_USERNAME:-}}"
    pass="${pass:-${DB_PASSWORD:-}}"
    service="${service:-${SERVICE:-maria}}"
    host="${host:-${HOST:-127.0.0.1}}"
    db_type="${db_type:-${DB_TYPE:-mariadb}}"
    backup_type="${backup_type:-${BACKUP_TYPE:-full}}"
    backup_dir="${backup_dir:-${BACKUP_DIR:-$script_dir/db-backup/maria}}"
    use_docker="${use_docker:-${USE_DOCKER:-true}}"
    monitor_url="${monitor_url:-${MONITOR_URL:-}}"
    cleanup_enabled="${cleanup_enabled:-${CLEANUP_ENABLED:-false}}"
    cleanup_days="${cleanup_days:-${CLEANUP_DAYS:-7}}"

    base_dir="${BASE_DIR:-$script_dir/db-backup}"
    backup_dir="${backup_dir:-$base_dir/maria}"

if [[ "$use_docker" == "true" ]]; then
    log "Checking if ${service} service is running..."
    if ! docker ps --filter "name=${service}" --filter "status=running" | grep -q "${service}"; then
        log "ERROR: ${service} service is not running. Exiting script."
        exit 1
    fi
fi

    init_backup_dir "$backup_dir"

    timestamp=$(date +%Y_%d%b_%H%M)

    [[ -z "$user" && -n "$DB_USERNAME" ]] && user="$DB_USERNAME"
    [[ -z "$pass" && -n "$DB_PASSWORD" ]] && pass="$DB_PASSWORD"

    validate_config

    if [[ "$db_type" == "mariadb" ]]; then
        dump_cmd="mariadb-dump"
        sql_runner="mariadb"
    else
        dump_cmd="mysqldump"
        sql_runner="mysql"
    fi

    if [[ "$use_docker" == "true" ]]; then
        command -v docker &>/dev/null || fail "Docker not available"
        docker exec "$service" "$sql_runner" -u "$user" --password="$pass" -h "$host" -e "SELECT 1;" &>/dev/null || fail "Docker DB connection failed"
        exec_prefix="docker exec $service"
    else
        command -v "$dump_cmd" &>/dev/null || fail "$dump_cmd not found"
        "$sql_runner" -u "$user" -p"$pass" -h "$host" -e "SELECT 1;" &>/dev/null || fail "Direct DB connection failed"
        exec_prefix=""
    fi

    log "Starting $backup_type backup at $timestamp"
    schemas=$(get_schemas "$sql_runner" "$exec_prefix")

    while IFS= read -r schema; do
        case $schema in
            information_schema|mysql|performance_schema|sys|test)
                log "Skipping $schema"
                ;;
            *)
                filename="${timestamp}_${schema}.sql"
                dump_schema "$schema" "${backup_dir}/${filename}" "$dump_cmd" "$exec_prefix"
                ;;
        esac
    done <<< "$schemas"

    [[ "$cleanup_enabled" == "true" ]] && cleanup_old_backups "$backup_dir" "$cleanup_days"

    log "Backup completed successfully"
}

main "$@"
# End of script
