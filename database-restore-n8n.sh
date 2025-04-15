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
base_dir="${RESTORE_DIR:-$dir/db-restore"  # Default to $dir/db-backup if RESTORE_DIR is not set
backup_dir="${base_dir}/n8n"  # Use provided backup_dir, or default to RESTORE_DIR/n8n, or use fallback path

# Function to list available backups
list_backups() {
    log "Available backup folders:"
    
    # Find and list date folders
    date_folders=$(find "$backup_dir" -type d -name "????-??-??" | sort -r)
    
    if [[ -z "$date_folders" ]]; then
        log "No backup folders found in $backup_dir"
        exit 1
    fi
    
    # Display folders with count of backups
    count=1
    echo ""
    for folder in $date_folders; do
        backup_count=$(find "$folder" -name "*.tar.gz" | wc -l)
        folder_name=$(basename "$folder")
        echo "$count) $folder_name ($backup_count backups)"
        count=$((count + 1))
    done
    
    echo ""
    read -p "Select a date folder (number): " folder_choice
    
    if ! [[ "$folder_choice" =~ ^[0-9]+$ ]] || [ "$folder_choice" -lt 1 ] || [ "$folder_choice" -gt $((count-1)) ]; then
        log "Invalid selection. Exiting."
        exit 1
    fi
    
    # Get the selected folder
    selected_folder=$(echo "$date_folders" | sed -n "${folder_choice}p")
    
    # List backups in the selected folder
    log "Backups in $(basename "$selected_folder"):"
    
    backups=$(find "$selected_folder" -name "*.tar.gz" | sort -r)
    
    if [[ -z "$backups" ]]; then
        log "No backups found in selected folder"
        exit 1
    fi
    
    count=1
    echo ""
    for backup in $backups; do
        backup_name=$(basename "$backup")
        backup_size=$(du -h "$backup" | cut -f1)
        
        # Try to extract info from summary if available
        summary_file="${backup%.*.*}_summary.txt"
        if [[ -f "$summary_file" ]]; then
            workflow_count=$(grep "Workflow Count:" "$summary_file" | awk '{print $3}')
            db_files=$(grep "Database Files:" "$summary_file" | awk '{print $3}')
            echo "$count) $backup_name - Size: $backup_size, Workflows: $workflow_count, DBs: $db_files"
        else
            echo "$count) $backup_name - Size: $backup_size"
        fi
        
        count=$((count + 1))
    done
    
    echo ""
    read -p "Select a backup to restore (number): " backup_choice
    
    if ! [[ "$backup_choice" =~ ^[0-9]+$ ]] || [ "$backup_choice" -lt 1 ] || [ "$backup_choice" -gt $((count-1)) ]; then
        log "Invalid selection. Exiting."
        exit 1
    fi
    
    # Get the selected backup
    selected_backup=$(echo "$backups" | sed -n "${backup_choice}p")
    
    restore_backup "$selected_backup"
}

# Function to restore a backup
restore_backup() {
    local backup_file="$1"
    
    log "Preparing to restore from: $(basename "$backup_file")"
    log "⚠️  WARNING: This will REPLACE ALL CURRENT DATA in the n8n-data volume! ⚠️"
    log "Ensure you have backed up any important data before proceeding."
    
    read -p "Are you sure you want to proceed with restoration? (yes/no): " confirmation
    
    if [[ "$confirmation" != "yes" ]]; then
        log "Restoration cancelled."
        exit 0
    fi
    
    log "Stopping n8n container..."
    docker stop n8n
    
    log "Creating backup of current data (just in case)..."
    current_timestamp=$(date +"%Y%m%d_%H%M%S")
    pre_restore_dir="$backup_dir/pre_restore_$current_timestamp"
    mkdir -p "$pre_restore_dir"
    
    docker run --rm -v n8n-data:/data -v "$pre_restore_dir:/backup" alpine tar -czf "/backup/pre_restore_backup.tar.gz" /data
    log "Current data backed up to: $pre_restore_dir/pre_restore_backup.tar.gz"
    
    log "Clearing current volume data..."
    docker run --rm -v n8n-data:/data alpine sh -c "rm -rf /data/*"
    
    log "Restoring from backup..."
    # First check if this is a hot backup (has a temp_snapshot directory inside)
    temp_dir="/tmp/n8n_restore_$current_timestamp"
    mkdir -p "$temp_dir"
    
    # Extract the backup to the temporary directory
    tar -xzf "$backup_file" -C "$temp_dir"
    
    # Check if the extract contains temp_snapshot or direct data
    if [[ -d "$temp_dir/temp_snapshot" ]]; then
        # Hot backup format - copy from temp_snapshot
        docker run --rm -v n8n-data:/data -v "$temp_dir:/restore" alpine sh -c "cp -a /restore/temp_snapshot/. /data/"
    elif [[ -d "$temp_dir/data" ]]; then
        # Standard format with data directory
        docker run --rm -v n8n-data:/data -v "$temp_dir:/restore" alpine sh -c "cp -a /restore/data/. /data/"
    else
        # Try direct copy from whatever is extracted
        docker run --rm -v n8n-data:/data -v "$temp_dir:/restore" alpine sh -c "cp -a /restore/. /data/"
    fi
    
    # Cleanup temporary directory
    rm -rf "$temp_dir"
    
    log "Setting correct permissions..."
    docker run --rm -v n8n-data:/data alpine sh -c "chown -R 1000:1000 /data"
    
    log "Starting n8n container..."
    docker start n8n
    
    log "Restoration complete! n8n should be running with the restored data."
    log "If you encounter any issues, a pre-restoration backup was created at: $pre_restore_dir/pre_restore_backup.tar.gz"
}

# Main execution
if [[ $# -eq 0 ]]; then
    # Interactive mode - list and select backup
    list_backups
elif [[ $# -eq 1 && -f "$1" ]]; then
    # Direct restore from specified file
    restore_backup "$1"
else
    echo "Usage: $0 [backup_file.tar.gz]"
    echo ""
    echo "When run without arguments, this script will display available backups."
    echo "You can also specify a backup file path directly to restore from that file."
    exit 1
fi