#!/bin/bash

# Set default values
backupDir="db-backup"

# Parse command-line arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -g|-gdrive|--gdrive)
      gdrive="$2"
      shift
      ;;
    *)
      printf "***************************\n"
      printf "* Error: Invalid argument in gbk.sh *\n"
      printf "***************************\n"
      shift
  esac
  shift
done

# Get the directory of the script
dir="$(dirname "$(realpath "$0")")"

echo "Directory is ${dir}, backing up to ${backupDir} on Google Drive"

# Move SQL files to Google Drive
rclone move --update --include "*.sql.zip" --verbose --transfers 30 --checkers 8 --contimeout 60s --timeout 300s --retries 3 --low-level-retries 10 "${dir}/${backupDir}/" "gdrive:${gdrive}/${backupDir}"

echo "Clearing remote directory"

# Delete old files from Google Drive
rclone --drive-use-trash=false --verbose --min-age 2d delete "gdrive:${gdrive}/${backupDir}"

# rclone --drive-use-trash=false --verbose --min-age 2d delete gdrive:db-backup

#rm "${dir}/db-backup/*"
