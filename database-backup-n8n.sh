#!/bin/bash

log() {
    local message="$1"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S.%3N')
    echo "[$timestamp] $message"
}

dir="$(dirname "$(realpath "$0")")"
if [[ -f "$dir/.backup" ]]; then
    source "$dir/.backup"
    log "Loaded environment variables from .backup file"
fi

# Default services to back up
services=(${N8N_SERVICES:-n8n workflow})  # space-separated list, override via .backup or env
use_docker="${use_docker:-${USE_DOCKER:-true}}"
base_dir="${BASE_DIR:-$dir/db-backup}"

for service in "${services[@]}"; do
    log "Processing backup for service: $service"

    volume_name="${service}-data"
    backup_dir="${base_dir}/${service}"
    mkdir -p "$backup_dir"

    if [[ "$use_docker" == "true" ]]; then
        log "Checking if $service is running..."
        if ! docker ps --filter "name=${service}" --filter "status=running" | grep -q "${service}"; then
            log "ERROR: ${service} is not running. Skipping."
            continue
        fi
    fi

    dated_dir="$backup_dir/$(date +"%Y-%m-%d")"
    mkdir -p "$dated_dir"

    TIMESTAMP=$(date +"%Y%m%d_%H%M%S.%3N")
    BACKUP_FILE="$dated_dir/${service}_hot_backup_$TIMESTAMP.tar.gz"

    log "Gathering volume information for ${volume_name}..."
    vol_size=$(docker run --rm -v ${volume_name}:/data alpine sh -c "du -sh /data" | awk '{print $1}')
    db_files=$(docker run --rm -v ${volume_name}:/data alpine sh -c "find /data -name '*.db' -o -name '*.sqlite' 2>/dev/null | wc -l")
    workflow_count=$(docker run --rm -v ${volume_name}:/data alpine sh -c "find /data -name 'workflow_*.json' 2>/dev/null | wc -l")

    log "Creating temporary snapshot for ${service}..."
    docker run --rm -v ${volume_name}:/source_data -v "$dated_dir:/backup" alpine sh -c "mkdir -p /backup/temp_snapshot && cp -a /source_data/. /backup/temp_snapshot/ && tar -czf /backup/${service}_hot_backup_$TIMESTAMP.tar.gz -C /backup temp_snapshot && rm -rf /backup/temp_snapshot"

    if [[ $? -eq 0 ]]; then
        log "Backup successful: $BACKUP_FILE"
        log "Backup size: $(du -h "${BACKUP_FILE}" | cut -f1)"
        summary_file="$dated_dir/backup_summary_$TIMESTAMP.txt"
        {
            echo "Backup Date: $(date +'%Y-%m-%d %H:%M:%S.%3N')"
            echo "Backup Type: Hot Backup (No Downtime)"
            echo "Service: ${service}"
            echo "Source Volume: ${volume_name}"
            echo "Volume Size: $vol_size"
            echo "Database Files: $db_files"
            echo "Workflow Count: $workflow_count"
            echo "Backup File: ${BACKUP_FILE}"
            echo "Backup Size: $(du -h "${BACKUP_FILE}" | cut -f1)"
            echo "NOTE: This is a hot backup. Small risk of inconsistency if data was being written."
        } > "$summary_file"
        log "Summary created at: $summary_file"
    else
        log "Backup FAILED for service: ${service}"
    fi

    # Cleanup old backups
    MAX_DAYS="${BACKUP_RETENTION_DAYS:-7}"
    if [[ $MAX_DAYS -gt 0 ]]; then
        old_dirs=$(find "$backup_dir" -type d -name "????-??-??" -mtime +$MAX_DAYS)
        if [[ -n "$old_dirs" ]]; then
            log "Cleaning backups older than $MAX_DAYS days..."
            for old in $old_dirs; do
                log "Removing: $old"
                rm -rf "$old"
            done
        else
            log "No old backups to clean for ${service}"
        fi
    fi
done

log "All backups completed."