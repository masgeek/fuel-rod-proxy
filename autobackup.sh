#!/bin/bash

dir="$(dirname "$(realpath "$0")")"


echo "Directory is ${dir}"

"${dir}/database-backup.sh" && "${dir}/archive-sql.sh" && "${dir}/gbk.sh"
