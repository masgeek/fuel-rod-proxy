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
    export "$(grep -v '^#' "$dir/.backup" | xargs)"
    log "Exported environment variables"
fi

# Set backup directory
backupDir="${BACKUP_DIR:-$dir/db-backup}"  # Default to $dir/db-backup if BACKUP_DIR is not set

# Default values from environment variables or fallbacks
gdrive="${GDRIVE:-db-backup}"
dry_run_val="${DRY_RUN:-0}"
dry_run=false
days="${BACKUP_AGE:-2}"
include_files="${INCLUDE_FILES:-*.sql.zip}"

if [[ "$dry_run_val" == 1 ]]; then
    dry_run=true
fi

log "Dry run value is ${dry_run} with env variable ${dry_run_val}"

log "Google drive directory is ${gdrive}"

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

# Unset environment variables to avoid affecting other processes
unset DB_PASS MONITOR_URL BACKUP_DIR GDRIVE DRY_RUN BACKUP_AGE INCLUDE_FILES

if [[ -z "$gdrive" ]]; then
    log "Error: Google Drive destination not specified"
    exit 1
fi

log "Backing up SQL files from ${backupDir} to Google Drive: gdrive:${gdrive}/${backupDir}"

# Move SQL files to Google Drive and delete local files after copying
rclone move "${backupDir}/" "gdrive:${gdrive}/" --include "${include_files}" --verbose --transfers 30 --checkers 8 --contimeout 60s --timeout 300s --retries 3 --low-level-retries 10 --delete-empty-src-dirs
backup_status=$?

if [[ $backup_status -eq 0 ]]; then
    log "Backup to Google Drive completed successfully"
else
    log "Error: Failed to backup to Google Drive"
    exit 1
fi

log "Clearing remote directory older than ${days} days"

# Build the rclone delete command
rclone_command="rclone --drive-use-trash=false --verbose --min-age ${days}d --include '${include_files}' delete gdrive:${gdrive}"

# Add the dry run flag if necessary
if [[ "$dry_run" == true ]]; then
    rclone_command="$rclone_command --dry-run"
fi

# Execute the rclone command
eval $rclone_command
delete_status=$?

if [[ $delete_status -eq 0 ]]; then
    log "Old files deleted from Google Drive successfully"
else
    log "Error: Failed to delete old files from Google Drive"
    exit