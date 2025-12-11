#!/bin/bash
set -euo pipefail

###############################################
# Logging and error helpers
###############################################
verbose=false
dry_run=false

log() {
    local message="$1"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message"
}

logv() {
    # Verbose log only if verbose=true
    [[ "$verbose" == true ]] && log "$1"
}

fail() {
    log "ERROR: $1"
    exit 1
}

###############################################
# Load environment variables from .backup
###############################################
dir="$(dirname "$(realpath "$0")")"
if [[ -f "$dir/.backup" ]]; then
    source "$dir/.backup"
    log "Loaded environment variables from .backup file"
fi

services=(${N8N_SERVICES:-n8n})
base_dir="${RESTORE_DIR:-$dir/db-restore}"

###############################################
# Parse CLI args
###############################################
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose) verbose=true ;;
        --dry-run) dry_run=true ;;
        *) break ;;
    esac
    shift
done

###############################################
# Validate Docker
###############################################
if ! command -v docker >/dev/null 2>&1; then
    fail "Docker CLI not found. Cannot continue."
fi

###############################################
# Function: Select service interactively
###############################################
select_service() {
    echo ""
    log "Available n8n services:"
    for i in "${!services[@]}"; do
        echo "$((i+1))) ${services[$i]}"
    done

    echo ""
    read -p "Select a service to restore (number): " svc_choice
    if ! [[ "$svc_choice" =~ ^[0-9]+$ ]] || (( svc_choice < 1 || svc_choice > ${#services[@]} )); then
        fail "Invalid service selection."
    fi

    selected_service="${services[$((svc_choice-1))]}"
    service_volume="${selected_service}-data"
    service_container="${selected_service}"
    service_backup_dir="${base_dir}/${selected_service}"
}

###############################################
# Function: List backups and select
###############################################
list_backups() {
    [[ -d "$service_backup_dir" ]] || fail "Backup directory not found: $service_backup_dir"
    log "Available backup folders for ${selected_service}:"

    mapfile -t date_folders < <(find "$service_backup_dir" -type d -name "????-??-??" | sort -r)
    [[ ${#date_folders[@]} -gt 0 ]] || fail "No backup folders found in $service_backup_dir"

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
        fail "Invalid date selection."
    fi

    selected_folder="${date_folders[$((folder_choice-1))]}"
    log "Backups in $(basename "$selected_folder"):"

    mapfile -t backups < <(find "$selected_folder" -name "*.tar.gz" | sort -r)
    [[ ${#backups[@]} -gt 0 ]] || fail "No backups found in selected folder"

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
        fail "Invalid backup selection."
    fi

    selected_backup="${backups[$((backup_choice-1))]}"
    restore_backup "$selected_backup"
}

###############################################
# Function: Restore backup
###############################################
restore_backup() {
    local backup_file="$1"
    [[ -f "$backup_file" ]] || fail "Backup file not found: $backup_file"

    current_timestamp=$(date +"%Y%m%d_%H%M%S")
    temp_dir="/tmp/${selected_service}_restore_$current_timestamp"
    mkdir -p "$temp_dir"

    log "Execution context: Docker mode"
    log "Selected service: $selected_service"
    log "Container: $service_container"
    log "Volume: $service_volume"
    log "Backup directory: $service_backup_dir"
    log "Preparing to restore from: $(basename "$backup_file")"
    log "⚠️ WARNING: This will REPLACE ALL CURRENT DATA in the ${service_volume} volume! ⚠️"

    read -p "Are you sure you want to proceed with restoration? (yes/no): " confirmation
    [[ "$confirmation" == "yes" ]] || { log "Restoration cancelled."; exit 0; }

    if [[ "$dry_run" == true ]]; then
        logv "[DRY-RUN] Would stop container: $service_container"
        logv "[DRY-RUN] Would create pre-restore backup in $service_backup_dir/pre_restore_$current_timestamp"
        logv "[DRY-RUN] Would clear volume: $service_volume"
        logv "[DRY-RUN] Would extract backup: $backup_file -> $temp_dir"
        logv "[DRY-RUN] Would copy files to volume and set permissions"
        logv "[DRY-RUN] Would start container: $service_container"
        return 0
    fi

    # Stop container
    log "Stopping container ${service_container}..."
    docker stop "$service_container" || log "Warning: Failed to stop container. Continuing..."

    # Pre-restore backup
    log "Creating pre-restore backup..."
    pre_restore_dir="$service_backup_dir/pre_restore_$current_timestamp"
    mkdir -p "$pre_restore_dir"
    docker run --rm -v "${service_volume}:/data" -v "$pre_restore_dir:/backup" alpine \
        tar -czf "/backup/pre_restore_backup.tar.gz" /data
    log "Pre-restore backup stored at: $pre_restore_dir/pre_restore_backup.tar.gz"

    # Clear current volume
    log "Clearing current volume data..."
    docker run --rm -v "${service_volume}:/data" alpine sh -c "rm -rf /data/*"

    # Extract backup
    log "Extracting backup..."
    tar -xzf "$backup_file" -C "$temp_dir"

    # Determine source directory
    if [[ -d "$temp_dir/temp_snapshot" ]]; then
        src_dir="$temp_dir/temp_snapshot"
    elif [[ -d "$temp_dir/data" ]]; then
        src_dir="$temp_dir/data"
    else
        src_dir="$temp_dir"
    fi
    logv "Restoring data from $src_dir -> volume $service_volume"

    # Copy files to volume
    docker run --rm -v "${service_volume}:/data" -v "$src_dir:/restore" alpine \
        sh -c "cp -a /restore/. /data/"

    # Set permissions
    log "Setting permissions for volume..."
    docker run --rm -v "${service_volume}:/data" alpine sh -c "chown -R 1000:1000 /data"

    # Start container
    log "Starting container ${service_container}..."
    docker start "$service_container"

    log "✅ Restoration complete!"
    log "Backup used: $backup_file"

    # Cleanup temp
    rm -rf "$temp_dir"
    log "Temporary restore directory cleaned: $temp_dir"
}

###############################################
# Main execution
###############################################
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
    echo "  $0                          # Interactive mode"
    echo "  $0 service_name backup_file.tar.gz  # Direct restore"
    echo "Options:"
    echo "  --dry-run       # Only logs steps, does not modify containers/volumes"
    echo "  --verbose       # Prints detailed step logs"
    exit 1
fi
