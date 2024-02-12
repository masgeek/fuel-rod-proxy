#!/bin/bash


dir="$(dirname "$(realpath "$0")")"

echo "Directory is ${dir}"

# Call database-backup.sh and pass arguments
"${dir}/database-backup.sh" "$@" &&
# Call archive-sql.sh without arguments
"${dir}/archive-sql.sh"  "$@" &&
# Call gbk.sh without arguments
"${dir}/gbk.sh"
