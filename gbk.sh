#!/bin/bash
set -euo pipefail

# -------------------------------
# Logging
# -------------------------------
log() {
    local message="$1"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message"
}

# -------------------------------
# Script dir & env
# -------------------------------
dir="$(dirname "$(realpath "$0")")"

if [[ -f "$dir/.backup" ]]; then
    source "$dir/.backup"
    log "Exported environment variables from .backup"
fi

# -------------------------------
# Default configuration
# -------------------------------
backupDir="${BACKUP_DIR:-$dir/db-backup}"
gdrive="${GDRIVE:-db-backup}"
dry_run_val="${DRY_RUN:-0}"
dry_run=false
days="${BACKUP_AGE:-2}"
include_files="${INCLUDE_FILES:-*.sql.zip *_backups.zip *.tar.gz *.dump *.dump.gz *.txt}"

[[ "$dry_run_val" == 1 ]] && dry_run=true

log "Dry run: $dry_run"
log "Backup directory: $backupDir"
log "Google Drive directory: gdrive:${gdrive}/"
log "Include patterns: $include_files"

# -------------------------------
# Parse CLI arguments
# -------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -g|--gdrive)
            gdrive="$2"; shift 2 ;;
        -d|--dry-run)
            dry_run=true; shift ;;
        -n|--days)
            days="$2"; shift 2 ;;
        -i|--include)
            include_files="$2"; shift 2 ;;
        *)
            log "Error: Invalid argument '$1'"
            exit 1 ;;
    esac
done

# -------------------------------
# Build rclone include args
# -------------------------------
IFS=' ' read -ra include_patterns <<< "$include_files"
include_args=()
for pattern in "${include_patterns[@]}"; do
    include_args+=(--include "$pattern")
done

# -------------------------------
# Ensure subfolder exists on Google Drive
# -------------------------------
log "Ensuring Google Drive folder exists: gdrive:${gdrive}/"

if [[ "$dry_run" == true ]]; then
    log "[DRY RUN] Would create folder on Google Drive: gdrive:${gdrive}/"
else
    rclone mkdir "gdrive:${gdrive}/"
    log "Google Drive folder ready: gdrive:${gdrive}/"
fi

# -------------------------------
# Copy files to Google Drive
# -------------------------------
log "Starting copy to Google Drive: gdrive:${gdrive}/"

rclone copy "${backupDir}/" "gdrive:${gdrive}/" \
    "${include_args[@]}" \
    --verbose --transfers 30 --checkers 8 \
    --contimeout 60s --timeout 300s --retries 3 --low-level-retries 10

if [[ $? -eq 0 ]]; then
    log "All files copied to Google Drive successfully"
else
    log "Error: Failed to copy files to Google Drive"
fi


# -------------------------------
# Optional: Delete old files
# -------------------------------
log "Deleting files older than ${days} days on Google Drive"

for pattern in "${include_patterns[@]}"; do
    rclone_delete_cmd=(rclone --drive-use-trash=false --verbose --min-age "${days}d" --include "$pattern" delete "gdrive:${gdrive}")
    [[ "$dry_run" == true ]] && rclone_delete_cmd+=(--dry-run)
    log "Executing: ${rclone_delete_cmd[*]}"
    "${rclone_delete_cmd[@]}"
done

log "Backup and cleanup process completed successfully"
