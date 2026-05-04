#!/bin/bash
# Copy to repo root before use: cp scripts/autobackup.sample.sh autobackup.sh
export PATH="$HOME/.local/bin:$PATH"

dir="$(dirname "$(realpath "$0")")"

echo "Directory is ${dir}"

# n8n volume backup (non-interactive)
fuelrod-backup n8n-backup --no-interactive

# Back up all configured engines in parallel.
# Requires PG_*, MY_*, and/or MS_* prefixed credentials in .backup.
fuelrod-backup backup --all-engines

# ── Single-engine examples (uncomment as needed) ─────────────────────────────
# fuelrod-backup backup --db-type postgres --no-interactive
# fuelrod-backup backup --db-type mariadb --no-interactive
# fuelrod-backup backup --db-type mssql --no-interactive

# Back up specific databases only:
# fuelrod-backup backup --db-type postgres --no-interactive --db mydb1 --db mydb2
# fuelrod-backup backup --db-type mariadb  --no-interactive --db mydb1 --db mydb2

# Sync backups to Google Drive via rclone
fuelrod-backup gdrive-sync
