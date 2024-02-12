#!/bin/bash

# Function to display usage information
usage() {
    echo "Usage: $(basename "$0") [-s|--size <size>] [--help]"
    echo "  -s, --size <size>   Specify the size threshold for files to be archived"
    echo "  --help              Display this help message"
    exit 1
}

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

dir="$(dirname "$(realpath "$0")")"

echo "Directory is ${dir}"

# Call database-backup.sh and pass arguments
"${dir}/database-backup.sh" "$@" &&
# Call archive-sql.sh without arguments
"${dir}/archive-sql.sh" --size 200k &&
# Call gbk.sh without arguments
"${dir}/gbk.sh"
