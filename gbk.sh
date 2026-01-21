#!/usr/bin/env bash
set -euo pipefail

# -------------------------------
# Logging function
# -------------------------------
log() {
    local message="$1"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message"
}

# -------------------------------
# Script dir & environment
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
include_files="${INCLUDE_FILES:-*.sql.zip *.sql.gz *_backups.zip *.tar.gz *.dump *.dump.gz *.txt}"

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
        -g|--gdrive) gdrive="$2"; shift 2 ;;
        -d|--dry-run) dry_run=true; shift ;;
        -n|--days) days="$2"; shift 2 ;;
        -i|--include) include_files="$2"; shift 2 ;;
        *) log "Error: Invalid argument '$1'"; exit 1 ;;
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
# List files to copy
# -------------------------------
log "Listing files to copy from $backupDir"
files_to_remove=()
for pattern in "${include_patterns[@]}"; do
    while IFS= read -r f; do
        log "Found: $f"
        files_to_remove+=("$f")
    done < <(find "$backupDir" -type f -name "$pattern")
done

# -------------------------------
# Ensure Google Drive folder exists
# -------------------------------
log "Ensuring Google Drive folder exists: gdrive:${gdrive}/"
if [[ "$dry_run" == true ]]; then
    log "[DRY RUN] Would create folder on Google Drive: gdrive:${gdrive}/"
else
    rclone mkdir "gdrive:${gdrive}/"
    log "Google Drive folder ready: gdrive:${gdrive}/"
fi

# -------------------------------
# Copy files to Google Drive (throttled)
# -------------------------------
log "Starting copy to Google Drive: gdrive:${gdrive}/"

rclone copy "$backupDir/" "gdrive:${gdrive}/" \
    "${include_args[@]}" \
    --verbose --progress --create-empty-src-dirs \
    --transfers 2 --checkers 4 \
    --tpslimit 10 --bwlimit 2M \
    --contimeout 60s --timeout 300s --retries 3 --low-level-retries 10 \
    $([[ "$dry_run" == true ]] && echo "--dry-run" || echo "")

log "Copy operation completed"

# -------------------------------
# Clean up local files
# -------------------------------
log "Cleaning up local files that were backed up"
for file in "${files_to_remove[@]}"; do
    if [[ "$dry_run" == true ]]; then
        log "[DRY RUN] Would remove local file: $file"
    else
        if [[ -f "$file" ]]; then
            rm -f "$file"
            log "Removed local file: $file"
        fi
    fi
done

# -------------------------------
# Delete old files on Google Drive safely
# -------------------------------
log "Deleting files older than ${days} days on Google Drive"
for pattern in "${include_patterns[@]}"; do
    rclone_delete_cmd=(rclone --drive-use-trash=false --verbose --min-age "${days}d" --include "$pattern" delete "gdrive:${gdrive}")
    rclone_delete_cmd+=(--tpslimit 10 --transfers 2) # throttle API requests
    [[ "$dry_run" == true ]] && rclone_delete_cmd+=(--dry-run)
    log "Executing: ${rclone_delete_cmd[*]}"
    "${rclone_delete_cmd[@]}"
done

log "Backup, cleanup, and remote pruning completed successfully"
