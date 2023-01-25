#!/bin/bash

#timestamp=$(date +%Y%m%d%H)

#zip -r "${timestamp}_backups.zip" *.sql && rm *.sql && mv "${timestamp}_backups.zip" /home/akilimo/services/tsobu-proxy/db-backup/

dir="$(dirname "$(realpath "$0")")"


echo "Directory is ${dir}"

#find "${dir}/db-backup" -name '*.sql' -print -exec zip '{}'.zip '{}' \; -exec rm '{}' \; -exec mv '{}'.zip "${dir}/db-backup" \;

find "${dir}/db-backup" -name '*.sql' -print -exec zip '{}'.zip '{}' \; -exec rm '{}' \;