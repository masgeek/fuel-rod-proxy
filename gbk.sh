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

# Parse command-line arguments
gdrive="${GDRIVE:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        -g|-gdrive|--gdrive)
            gdrive="$2"
            shift 2
            ;;
        *)
            log "Error: Invalid argument '$1' in backup script"
            shift
            ;;
    esac
done

# if [[ -z "$gdrive" ]]; then
#     log "Error: Google Drive destination not specified"
#     exit 1
# fi

log "Backing up SQL files from ${backupDir} to Google Drive: gdrive:${gdrive}/${backupDir}"

# Move SQL files to Google Drive
#rclone move --update --include "*.sql.zip" --verbose --transfers 30 --checkers 8 --contimeout 60s --timeout 300s --retries 3 --low-level-retries 10 "${backupDir}/" "gdrive:${gdrive}/${backupDir}"
# Move .sql.zip files to Google Drive and delete local files after copying
rclone move "${backupDir}/" "gdrive:${gdrive}/" --include "*.sql.zip" --verbose --transfers 30 --checkers 8 --contimeout 60s --timeout 300s --retries 3 --low-level-retries 10 --delete-empty-src-dirs

# Copy SQL files to Google Drive without creating folder structure
#rclone copyto --verbose --include "*.sql.zip" --transfers 30 --checkers 8 --contimeout 60s --timeout 300s --retries 3 --low-level-retries 10 "${backupDir}/" "gdrive:${gdrive}/"


if [[ $? -eq 0 ]]; then
    log "Backup to Google Drive completed successfully"
else
    log "Error: Failed to backup to Google Drive"
    exit 1
fi

log "Clearing remote directory older than 2 days"

# Delete old files from Google Drive
rclone --drive-use-trash=false --verbose --min-age 2d delete "gdrive:${gdrive}/${backupDir}"

if [[ $? -eq 0 ]]; then
    log "Old files deleted from Google Drive successfully"
else
    log "Error: Failed to delete old files from Google Drive"
    exit 1
fi

log "Backup and cleanup process completed"