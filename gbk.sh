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
backupDir="${gdrive:-fuelrod-backup}"

echo "Directory is ${dir} backing up to ${backupDir} on google drive"

rclone copy --update --verbose --transfers 30 --checkers 8 --contimeout 60s --timeout 300s --retries 3 --low-level-retries 10 --stats 1s "${dir}/db-backup/" "gdrive:${backupDir}"

echo "Clearing directory"

#rm "${dir}/db-backup/*.zip"
