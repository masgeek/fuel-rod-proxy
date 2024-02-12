#!/bin/bash

# Default size threshold (20KB)
DEFAULT_SIZE_THRESHOLD="20k"

# Function to display usage information
usage() {
    echo "Usage: $(basename "$0") [-s|--size <size>] [--help]"
    echo "  -s, --size <size>   Specify the size threshold for files to be archived (default: 20k)"
    echo "  --help              Display this help message"
    exit 1
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--size)
            size_threshold="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            echo "Invalid option: $1" >&2
            usage
            ;;
    esac
done

# Set size threshold or default value if not provided
size_threshold="${size_threshold:-$DEFAULT_SIZE_THRESHOLD}"

# Get the directory of the script
dir="$(dirname "$(realpath "$0")")"
echo "Directory is ${dir}"

# Create a temporary directory to store files greater than the size threshold
temp_dir=$(mktemp -d)

# Find SQL files greater than the size threshold and move them to the temporary directory
find "${dir}/db-backup" -name '*.sql' -size +${size_threshold} -exec mv {} "$temp_dir" \;

# Zip files in the temporary directory and remove original files
if [ "$(ls -A "$temp_dir")" ]; then
    zip -r "${dir}/db-backup-$(date +%Y%m%d%H%M%S).zip" "$temp_dir"
    rm -rf "$temp_dir"
else
    echo "No files to archive."
    rm -rf "$temp_dir"
    exit 1
fi

# Remove other files that do not meet the criteria (files smaller than or equal to the size threshold)
find "${dir}/db-backup" -name '*.sql' -not -size +${size_threshold} -delete

exit 0