#!/bin/bash

set -euo pipefail

# Usage: ./pg_backup.sh --database mydb [--schemas schema1,schema2] [--exclude schemaX,schemaY]

# Helper: Print logs with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Helper: Show usage
usage() {
    echo "Usage: $0 --database DB_NAME [--schemas SCHEMAS] [--exclude EXCLUDE]"
    exit 1
}

# Parse args
database=""
selected_schemas=""
exclude_schemas=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --database)
            database="$2"
            shift 2
            ;;
        --schemas)
            selected_schemas="$2"
            shift 2
            ;;
        --exclude)
            exclude_schemas="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

[[ -z "$database" ]] && usage

timestamp=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="./backups/$database/$timestamp"
MANIFEST="$BACKUP_DIR/manifest.txt"
mkdir -p "$BACKUP_DIR"

# Convert CSV to space-separated list
IFS=',' read -ra schema_array <<< "${selected_schemas:-}"
all_selected_schemas="${schema_array[*]}"

IFS=',' read -ra exclude_array <<< "${exclude_schemas:-}"
all_exclude_schemas="${exclude_array[*]}"

# Get all schemas from database (excluding system ones)
get_schemas() {
    psql -d "$database" -qtAc "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT LIKE 'pg_%' AND schema_name <> 'information_schema';"
}

# Function to check if schema should be excluded via wildcard
should_exclude() {
    local schema="$1"
    for pattern in $all_exclude_schemas; do
        local regex="^${pattern//\*/.*}"
        regex="${regex//\%/.+}"
        if [[ "$schema" =~ $regex ]]; then
            echo "true"
            return
        fi
    done
    echo "false"
}

# Filter schema names using wildcard matching
match_schema_patterns() {
    local patterns="$1"
    local all_schemas="$2"
    local matched=""

    for pattern in $patterns; do
        local regex="^${pattern//\*/.*}"
        regex="${regex//\%/.+}"
        while IFS= read -r schema; do
            [[ "$schema" =~ $regex ]] && matched+="$schema"$'\n'
        done <<< "$all_schemas"
    done

    echo "$matched" | sort -u
}

# Determine which schemas to back up
all_db_schemas="$(get_schemas)"

if [[ -n "$all_selected_schemas" ]]; then
    log "Filtering schemas based on: $all_selected_schemas"
    schema_list="$(match_schema_patterns "$all_selected_schemas" "$all_db_schemas")"
else
    log "Backing up all schemas from database '$database'"
    schema_list="$all_db_schemas"
fi

# Final filtered list after exclusions
final_schemas=""
while IFS= read -r schema; do
    [[ -z "$schema" ]] && continue
    if [[ "$(should_exclude "$schema")" == "true" ]]; then
        log "Excluding schema: $schema"
        continue
    fi
    final_schemas+="$schema"$'\n'
done <<< "$schema_list"

# Perform backup per schema
log "Starting backup for database '$database'"
echo "Backup manifest - $(date)" > "$MANIFEST"

while IFS= read -r schema; do
    [[ -z "$schema" ]] && continue
    output_file="$BACKUP_DIR/${schema}_${timestamp}.sql.gz"
    log "Backing up schema: $schema -> $output_file"
    pg_dump -d "$database" --schema="$schema" | gzip > "$output_file"
    echo "$output_file" >> "$MANIFEST"
done <<< "$final_schemas"

log "Backup complete. Files written to: $BACKUP_DIR"
