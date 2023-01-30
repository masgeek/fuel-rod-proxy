#!/bin/bash

while [ $# -gt 0 ]; do
  case "$1" in
    -g|-gdrive|--gdrive)
      gdrive="$2"
      ;;
    *)
      printf "***************************\n"
      printf "* Error: Invalid argument.*\n"
      printf "***************************\n"
      exit 1
  esac
  shift
  shift
done

dir="$(dirname "$(realpath "$0")")"
backupDir="${gdrive:-db-backup}"

echo "Directory is ${dir} backing up to ${backupDir} on google drive"

rclone move --update --include "*sql.zip" --verbose --transfers 30 --checkers 8 --contimeout 60s --timeout 300s --retries 3 --low-level-retries 10 "${dir}/db-backup/" "gdrive:${backupDir}"

echo "Clearing remote directory"

rclone --drive-use-trash=false --verbose --min-age 5d delete gdrive:db-backup

#rm "${dir}/db-backup/*"
