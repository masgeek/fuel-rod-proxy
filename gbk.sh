#!/bin/bash

# Function to log messages
log() {
    local message="$1"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message"
}

# Get the directory of the script
dir="$(dirname "$(realpath "$0")")"

# Load environment variables from .backup file if present
if [[ -f "$dir/.backup" ]]; then
    source "$dir/.backup"
    log "Exported environment variables"
fi

# Set backup directory - use the same base directory for both SQL and n8n files
backupDir="${BACKUP_DIR:-$dir/db-backup}"  # Default to $dir/backups if BACKUP_DIR is not set

# Default values from environment variables or fallbacks
gdrive="${GDRIVE:-db-backup}"
dry_run_val="${DRY_RUN:-0}"
dry_run=false
days="${BACKUP_AGE:-2}"
include_files="${INCLUDE_FILES:-*.sql.zip *_backups.zip *.tar.gz}"  # Include both SQL and n8n backup patterns

if [[ "$dry_run_val" == 1 ]]; then
    dry_run=true
fi

log "Dry run value is ${dry_run} with env variable ${dry_run_val}"
log "Google drive directory for backups: ${gdrive}"
log "Including files matching: ${include_files}"

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -g|-gdrive|--gdrive)
            gdrive="$2"
            shift 2
            ;;
        -d|--dry-run)
            dry_run=true
            shift
            ;;
        -n|--days)
            days="$2"
            shift 2
            ;;
        -i|--include)
            include_files="$2"
            shift 2
            ;;
        *)
            log "Error: Invalid argument '$1' in backup script"
            exit 1
            ;;
    esac
done

# Backup files
log "Backing up files from ${backupDir} to Google Drive: gdrive:${gdrive}/"

# Create an array of include patterns
IFS=' ' read -ra include_patterns <<< "$include_files"
include_args=()

# Build the include arguments for rclone
for pattern in "${include_patterns[@]}"; do
    include_args+=(--include "$pattern")
done

# Execute rclone with the include patterns
rclone move "${backupDir}/" "gdrive:${gdrive}/" "${include_args[@]}" --verbose --transfers 30 --checkers 8 --contimeout 60s --timeout 300s --retries 3 --low-level-retries 10 --delete-empty-src-dirs
backup_status=$?

if [[ $backup_status -eq 0 ]]; then
    log "Backup to Google Drive completed successfully"
else
    log "Error: Failed to backup files to Google Drive"
fi

# Clean up old backups
log "Clearing remote directory older than ${days} days"

# Build the delete commands for each include pattern
for pattern in "${include_patterns[@]}"; do
    # Build the rclone delete command
    rclone_command="rclone --drive-use-trash=false --verbose --min-age ${days}d --include '${pattern}' delete gdrive:${gdrive}"
    
    # Add the dry run flag if necessary
    if [[ "$dry_run" == true ]]; then
        rclone_command="$rclone_command --dry-run"
    fi
    
    log "Deleting old files matching pattern: ${pattern}"
    
    # Execute the rclone command
    eval $rclone_command
    delete_status=$?
    
    if [[ $delete_status -eq 0 ]]; then
        log "Old files matching '${pattern}' deleted from Google Drive successfully"
    else
        log "Error: Failed to delete old files matching '${pattern}' from Google Drive"
        # Continue with next pattern even if this one fails
    fi
done

log "Backup and cleanup process completed"