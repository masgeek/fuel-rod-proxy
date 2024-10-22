#!/bin/bash

# Function to log messages
log() {
    local message="$1"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message"
}

# Set directory of the script
dir="$(dirname "$(realpath "$0")")"

# Load environment variables from .backup file if present
if [[ -f "$dir/.backup" ]]; then
    export "$(grep -v '^#' "$dir/.backup" | xargs)"
    log "Exported environment variables from .backup file"
fi

# Set backup directory
backup_dir="${BACKUP_DIR:-$dir/db-backup}"  # Default to $dir/db-backup if BACKUP_DIR is not set

log "Backup directory set to: ${backup_dir}"

# Find all .sql files and zip them
if [[ -d "$backup_dir" ]]; then
    find "$backup_dir" -name '*.sql' -print0 | while IFS= read -r -d '' file; do
        zip_file="${file}.zip"
        zip -r -j "$zip_file" "$file" && rm "$file"
        if [[ $? -eq 0 ]]; then
            log "Successfully zipped and removed: $file"
        else
            log "Failed to zip or remove: $file"
        fi
    done
else
    log "Backup directory not found or is not a directory: $backup_dir"
fi

log "Backup and compression process completed"