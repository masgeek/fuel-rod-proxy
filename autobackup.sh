#!/bin/bash

dir="$(dirname "$(realpath "$0")")"

echo "Directory is ${dir}"

# Call n8n-backup.sh first
"${dir}/backup_n8n.sh" &&

# Call database-backup.sh and pass arguments
"${dir}/database-backup.sh" &&

# Call database-backup.sh and pass arguments
"${dir}/database-backup-maria.sh" &&

# Check if the "--size" argument is provided
if [[ "$@" =~ "--size" ]]; then
    "${dir}/archive-sql.sh" "$@"
else
    "${dir}/archive-sql.sh" 
fi

# Call gbk.sh without arguments
"${dir}/gbk.sh"