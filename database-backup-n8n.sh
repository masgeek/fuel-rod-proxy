#!/bin/bash

# Function to log messages with millisecond precision
log() {
    local message="$1"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S.%3N')  # Added .%3N for milliseconds
    echo "[$timestamp] $message"
}

# Set directory of the script
dir="$(dirname "$(realpath "$0")")"

# Load environment variables from .backup file if present
if [[ -f "$dir/.backup" ]]; then
    export "$(grep -v '^#' "$dir/.backup" | xargs)"
    log "Exported environment variables from .backup file"
fi

# Set base directory and backup directory
base_dir="${BASE_DIR:-$dir/db-backup}"  # Default to $dir/db-backup if BASE_DIR is not set
backup_dir="${base_dir}/n8n"  # Use provided backup_dir, or default to BASE_DIR/n8n, or use fallback path

# Create base directory if it doesn't exist
mkdir -p "$base_dir"
log "Base directory set to: ${base_dir}"

# Create backup directory if it doesn't exist
mkdir -p "$backup_dir"
log "Backup directory set to: ${backup_dir}"

# Create a dated subfolder for this backup (YYYY-MM-DD format)
dated_dir="$backup_dir/$(date +"%Y-%m-%d")"
mkdir -p "$dated_dir"
log "Creating backup in subfolder: ${dated_dir}"

# Create a timestamp for the backup filename with millisecond precision
TIMESTAMP=$(date +"%Y%m%d_%H%M%S.%3N")  # Added .%3N for milliseconds
BACKUP_FILE="$dated_dir/n8n-data_hot_backup_$TIMESTAMP.tar.gz"

# Log volume info before backup
log "Gathering information about n8n-data volume..."
vol_size=$(docker run --rm -v n8n-data:/data alpine sh -c "du -sh /data" | awk '{print $1}')
log "Volume size: $vol_size"

# Check for important files (SQLite database and workflows)
db_files=$(docker run --rm -v n8n-data:/data alpine sh -c "find /data -name '*.db' -o -name '*.sqlite' 2>/dev/null | wc -l")
log "Found $db_files database files"

workflow_count=$(docker run --rm -v n8n-data:/data alpine sh -c "find /data -name 'workflow_*.json' 2>/dev/null | wc -l")
log "Found $workflow_count workflow files"

log "Creating a hot backup (container remains running)..."

# For SQLite, create a temporary container that will copy the data first, then compress it
# This avoids direct interaction with actively used files
log "Creating temporary snapshot of volume data..."
docker run --rm -v n8n-data:/source_data -v "$dated_dir:/backup" alpine sh -c "mkdir -p /backup/temp_snapshot && cp -a /source_data/. /backup/temp_snapshot/ && tar -czf /backup/n8n-data_hot_backup_$TIMESTAMP.tar.gz -C /backup temp_snapshot && rm -rf /backup/temp_snapshot"

if [[ $? -eq 0 ]]; then
    log "Hot backup created successfully: $BACKUP_FILE"
    log "Backup size: $(du -h "${BACKUP_FILE}" | cut -f1)"
    
    # Create a backup summary file
    summary_file="$dated_dir/backup_summary_$TIMESTAMP.txt"
    {
        echo "Backup Date: $(date +'%Y-%m-%d %H:%M:%S.%3N')"  # Added .%3N for milliseconds
        echo "Backup Type: Hot Backup (No Downtime)"
        echo "Source Volume: n8n-data"
        echo "Volume Size: $vol_size"
        echo "Database Files: $db_files"
        echo "Workflow Count: $workflow_count"
        echo "Backup File: ${BACKUP_FILE}"
        echo "Backup Size: $(du -h "${BACKUP_FILE}" | cut -f1)"
        echo "IMPORTANT: This is a hot backup. While convenient, there is a small risk of data inconsistency if files were being written during backup."
    } > "$summary_file"
    
    log "Backup summary created: $summary_file"
else
    log "Failed to create hot backup"
fi

# Cleanup old backups - keep last 7 days by default
MAX_DAYS="${BACKUP_RETENTION_DAYS:-7}"
if [[ $MAX_DAYS -gt 0 ]]; then
    old_backup_dirs=$(find "$backup_dir" -type d -name "????-??-??" -mtime +$MAX_DAYS)
    if [[ -n "$old_backup_dirs" ]]; then
        log "Removing backup folders older than $MAX_DAYS days..."
        for old_dir in $old_backup_dirs; do
            log "Removing old backup folder: $old_dir"
            rm -rf "$old_dir"
        done
        log "Old backup folders removed"
    else
        log "No backup folders older than $MAX_DAYS days found"
    fi
fi

log "Hot backup process completed"