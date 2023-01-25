#!/bin/bash

#timestamp=$(date +%Y%m%d%H)

#zip -r "${timestamp}_backups.zip" *.sql && rm *.sql && mv "${timestamp}_backups.zip" /home/akilimo/services/tsobu-proxy/db-backup/

find . -name '*.sql' -print -exec zip '{}'.zip '{}' \; -exec rm '{}' \; -exec mv '{}'.zip db-backup \;
