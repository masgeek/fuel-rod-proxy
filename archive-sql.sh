#!/bin/bash

dir="$(dirname "$(realpath "$0")")"

# Load environment variables from .backup file if present
dir="$(dirname "$(realpath "$0")")"
if [[ -f "$dir/.backup" ]]; then
    export $(grep -v '^#' "$dir/.backup" | xargs)
    log "Exported environment variables"
fi


backup_dir="${BACKUP_DIR:-$dir/db-backup}"  # Default to $dir/db-backup if BACKUP_DIR is not set


echo "Directory is ${backup_dir}"

find "${backup_dir}" -name '*.sql' -print -exec zip -r -j '{}'.zip '{}' \; -exec rm '{}' \;