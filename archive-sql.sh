#!/bin/bash

# Get the directory of the script
dir="$(dirname "$(realpath "$0")")"
echo "Directory is ${dir}"

# Create a temporary directory to store files greater than 20KB
temp_dir=$(mktemp -d)

# Find SQL files greater than 20KB and move them to the temporary directory
find "${dir}/db-backup" -name '*.sql' -size +20k -exec mv {} "$temp_dir" \;

# Zip files in the temporary directory and remove original files
zip -r "${dir}/db-backup-$(date +%Y%m%d%H%M%S).zip" "$temp_dir"

# Remove the temporary directory
rm -rf "$temp_dir"
