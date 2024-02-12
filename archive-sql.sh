#!/bin/bash

# Get the directory of the script
dir="$(dirname "$(realpath "$0")")"
echo "Directory is ${dir}"

# Zip SQL files and remove original files
find "${dir}/db-backup" -name '*.sql' -exec zip -r -j '{}'.zip '{}' \; -exec rm '{}' \;