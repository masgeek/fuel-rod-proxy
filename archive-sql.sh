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

# Set base backup directory (shared for all backups)
backup_dir="${BACKUP_DIR:-$dir/db-backup}"  # Default to $dir/backups if BACKUP_DIR is not set
log "Base backup directory set to: ${backup_dir}"

# SQL backup directory is a subfolder
sql_backup_dir="$backup_dir"
log "SQL backup directory set to: ${sql_backup_dir}"

# n8n backup directory is a subfolder
n8n_backup_dir="$backup_dir/n8n"
log "n8n backup directory set to: ${n8n_backup_dir}"

# Process SQL files first
log "Processing SQL files..."
if [[ -d "$sql_backup_dir" ]]; then
    find "$sql_backup_dir" -name '*.sql' -print0 | while IFS= read -r -d '' file; do
        zip_file="${file}.zip"
        zip -r -j "$zip_file" "$file" && rm "$file"
        if [[ $? -eq 0 ]]; then
            log "Successfully zipped and removed: $file"
        else
            log "Failed to zip or remove: $file"
        fi
    done
else
    log "SQL backup directory not found or is not a directory: $sql_backup_dir"
fi

# Process n8n backup subfolders
log "Processing n8n backup subfolders..."
if [[ -d "$n8n_backup_dir" ]]; then
    # Find all date-based subfolders (format: YYYY-MM-DD)
    date_folders=$(find "$n8n_backup_dir" -maxdepth 1 -type d -name "????-??-??" | sort)

    if [[ -z "$date_folders" ]]; then
        log "No date-based subfolders found in $n8n_backup_dir"
    else
        for folder in $date_folders; do
            folder_name=$(basename "$folder")
            zip_file="$n8n_backup_dir/${folder_name}_backups.zip"
            
            # Check if the folder already has a corresponding zip file and if it's older than 1 day
            if [[ -f "$zip_file" ]] && [[ $(find "$folder" -type f -newer "$zip_file" | wc -l) -eq 0 ]]; then
                log "Zip file already exists and up to date for $folder_name, skipping: $zip_file"
                continue
            fi
            
            log "Zipping subfolder: $folder_name"
            file_count=$(find "$folder" -type f | wc -l)
            log "Found $file_count files to compress in $folder_name"
            
            # Create zip file from the folder contents
            if (cd "$n8n_backup_dir" && zip -r "${folder_name}_backups.zip" "$folder_name"); then
                zip_size=$(du -h "$zip_file" | cut -f1)
                log "Successfully created zip archive: $zip_file (Size: $zip_size)"
                
                # Auto-delete original folder if it's older than 2 days
                folder_age=$(find "$folder" -type d -mtime +2 | wc -l)
                if [[ $folder_age -gt 0 ]]; then
                    rm -rf "$folder"
                    log "Automatically deleted old subfolder: $folder_name (older than 2 days)"
                fi
            else
                log "Error: Failed to create zip archive for $folder_name"
            fi
        done
    fi
else
    log "n8n backup directory not found or is not a directory: $n8n_backup_dir"
fi

log "All backup compression processes completed"