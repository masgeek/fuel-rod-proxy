#!/bin/bash

dir="$(dirname "$(realpath "$0")")"

echo "Directory is ${dir}"

# Call n8n-backup.sh first
"${dir}/database-backup-n8n.sh"

# Call pg-tool backup (Python CLI, non-interactive: no wizard prompts)
cd "${dir}/pg-tool" && poetry run pg-tool backup --no-interactive

# Call database-backup-maria.sh
"${dir}/database-backup-maria.sh"

# Check if the "--size" argument is provided
if [[ "$@" =~ "--size" ]]; then
    "${dir}/archive-sql.sh" "$@"
else
    "${dir}/archive-sql.sh" 
fi

# Call gbk.sh without arguments
# "${dir}/gbk.sh"
