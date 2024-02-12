#!/bin/bash

dir="$(dirname "$(realpath "$0")")"

echo "Directory is ${dir}"

# Call database-backup.sh and pass arguments
"${dir}/database-backup.sh" "$@" &&

# Check if the "--size" argument is provided
if [[ "$@" =~ "--size" ]]; then
    "${dir}/archive-sql.sh" "$@" &&
else
    "${dir}/archive-sql.sh" &&
fi

# Call gbk.sh without arguments
"${dir}/gbk.sh" &&
