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
            shift
            ;;
    esac
done

# Set size threshold or default value if not provided
size_threshold="${size_threshold:-$DEFAULT_SIZE_THRESHOLD}"

# Get the directory of the script
dir="$(dirname "$(realpath "$0")")"
echo "Directory is ${dir}"

# Archive files greater than the size threshold
find "${dir}/db-backup" -name '*.sql' -print -size +${size_threshold} -exec zip -r -j '{}'.zip '{}' \; -exec rm '{}' \;

# Delete files that do not meet the size threshold
find "${dir}/db-backup" -name '*.sql' ! -size +${size_threshold} -delete

exit 0
