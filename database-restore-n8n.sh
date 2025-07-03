#!/bin/bash
set -euo pipefail

log() {
    local message="$1"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message"
}

dir="$(dirname "$(realpath "$0")")"
if [[ -f "$dir/.backup" ]]; then
    source "$dir/.backup"
    log "Loaded environment variables from .backup file"
fi

services=(${N8N_SERVICES:-n8n1 n8n2})
base_dir="${RESTORE_DIR:-$dir/db-restore}"

# Function to choose a service
select_service() {
    echo ""
    log "Available n8n services:"
    for i in "${!services[@]}"; do
        echo "$((i+1))) ${services[$i]}"
    done

    echo ""
    read -p "Select a service to restore (number): " svc_choice
    if ! [[ "$svc_choice" =~ ^[0-9]+$ ]] || (( svc_choice < 1 || svc_choice > ${#services[@]} )); then
        log "Invalid service selection. Exiting."
        exit 1
    fi

    selected_service="${services[$((svc_choice-1))]}"
    service_volume="${selected_service}-data"
    service_container="${selected_service}"
    service_backup_dir="${base_dir}/${selected_service}"
}

# Function to list backups for a service
list_backups() {
    log "Available backup folders for ${selected_service}:"
    mapfile -t date_folders < <(find "$service_backup_dir" -type d -name "????-??-??" | sort -r)

    if [[ ${#date_folders[@]} -eq 0 ]]; then
        log "No backup folders found in $service_backup_dir"
        exit 1
    fi

    echo ""
    for i in "${!date_folders[@]}"; do
        folder="${date_folders[$i]}"
        folder_name=$(basename "$folder")
        backup_count=$(find "$folder" -name "*.tar.gz" | wc -l)
        echo "$((i+1))) $folder_name ($backup_count backups)"
    done

    echo ""
    read -p "Select a date folder (number): " folder_choice
    if ! [[ "$folder_choice" =~ ^[0-9]+$ ]] || (( folder_choice < 1 || folder_choice > ${#date_folders[@]} )); then
        log "Invalid date selection. Exiting."
        exit 1
    fi

    selected_folder="${date_folders[$((folder_choice-1))]}"
    log "Backups in $(basename "$selected_folder"):"
    mapfile -t backups < <(find "$selected_folder" -name "*.tar.gz" | sort -r)

    if [[ ${#backups[@]} -eq 0 ]]; then
        log "No backups found in selected folder"
        exit 1
    fi

    echo ""
    for i in "${!backups[@]}"; do
        backup="${backups[$i]}"
        backup_name=$(basename "$backup")
        backup_size=$(du -h "$backup" | cut -f1)
        summary_file="${backup%.*.*}_summary.txt"

        if [[ -f "$summary_file" ]]; then
            workflow_count=$(grep "Workflow Count:" "$summary_file" | awk '{print $3}')
            db_files=$(grep "Database Files:" "$summary_file" | awk '{print $3}')
            echo "$((i+1))) $backup_name - Size: $backup_size, Workflows: $workflow_count, DBs: $db_files"
        else
            echo "$((i+1))) $backup_name - Size: $backup_size"
        fi
    done

    echo ""
    read -p "Select a backup to restore (number): " backup_choice
    if ! [[ "$backup_choice" =~ ^[0-9]+$ ]] || (( backup_choice < 1 || backup_choice > ${#backups[@]} )); then
        log "Invalid backup selection. Exiting."
        exit 1
    fi

    selected_backup="${backups[$((backup_choice-1))]}"
    restore_backup "$selected_backup"
}

# Function to restore a backup
restore_backup() {
    local backup_file="$1"

    log "Preparing to restore ${selected_service} from: $(basename "$backup_file")"
    log "⚠️ WARNING: This will REPLACE ALL CURRENT DATA in the ${service_volume} volume! ⚠️"

    read -p "Are you sure you want to proceed with restoration? (yes/no): " confirmation
    if [[ "$confirmation" != "yes" ]]; then
        log "Restoration cancelled."
        exit 0
    fi

    log "Stopping ${selected_service} container..."
    docker stop "$service_container" || log "Warning: Failed to stop container. Continuing..."

    log "Creating backup of current data (pre-restore)..."
    current_timestamp=$(date +"%Y%m%d_%H%M%S")
    pre_restore_dir="$service_backup_dir/pre_restore_$current_timestamp"
    mkdir -p "$pre_restore_dir"
    docker run --rm -v ${service_volume}:/data -v "$pre_restore_dir:/backup" alpine tar -czf "/backup/pre_restore_backup.tar.gz" /data
    log "Current data backed up to: $pre_restore_dir/pre_restore_backup.tar.gz"

    log "Clearing current volume data..."
    docker run --rm -v ${service_volume}:/data alpine sh -c "rm -rf /data/*"

    log "Restoring from backup..."
    temp_dir="/tmp/${selected_service}_restore_$current_timestamp"
    mkdir -p "$temp_dir"
    tar -xzf "$backup_file" -C "$temp_dir"

    if [[ -d "$temp_dir/temp_snapshot" ]]; then
        docker run --rm -v ${service_volume}:/data -v "$temp_dir:/restore" alpine sh -c "cp -a /restore/temp_snapshot/. /data/"
    elif [[ -d "$temp_dir/data" ]]; then
        docker run --rm -v ${service_volume}:/data -v "$temp_dir:/restore" alpine sh -c "cp -a /restore/data/. /data/"
    else
        docker run --rm -v ${service_volume}:/data -v "$temp_dir:/restore" alpine sh -c "cp -a /restore/. /data/"
    fi

    rm -rf "$temp_dir"

    log "Setting permissions..."
    docker run --rm -v ${service_volume}:/data alpine sh -c "chown -R 1000:1000 /data"

    log "Starting container ${service_container}..."
    docker start "$service_container"

    log "✅ Restoration complete for ${selected_service}!"
    log "Backup file used: $backup_file"
    log "Pre-restore backup stored at: $pre_restore_dir/pre_restore_backup.tar.gz"
}

# Main execution
if [[ $# -eq 0 ]]; then
    select_service
    list_backups
elif [[ $# -eq 2 && -f "$2" ]]; then
    selected_service="$1"
    service_volume="${selected_service}-data"
    service_container="${selected_service}"
    restore_backup "$2"
else
    echo "Usage:"
    echo "  $0                      # Interactive mode"
    echo "  $0 service_name backup_file.tar.gz  # Direct restore"
    exit 1
fi
