#!/bin/bash

dir="$(dirname "$(realpath "$0")")"

echo "Directory is ${dir}"

# n8n volume backup (non-interactive)
fuelrod-backup n8n-backup --no-interactive

# PostgreSQL backup (non-interactive)
# Runs from the repo root so _find_config_file() picks up .backup in cwd
fuelrod-backup backup --db-type postgres --no-interactive

# MariaDB backup (non-interactive)
fuelrod-backup backup --db-type mariadb --no-interactive

# Check if the "--size" argument is provided
if [[ "$@" =~ "--size" ]]; then
    "${dir}/archive-sql.sh" "$@"
else
    "${dir}/archive-sql.sh"
fi

# Sync backups to Google Drive via rclone
fuelrod-backup gdrive-sync
