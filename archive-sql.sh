#!/bin/bash

timestamp=$(date +%Y%m%d%H%M%S)

zip -r "${timestamp}_backups.zip" *.sql && rm *.sql && mv "${timestamp}_backups.zip" /home/sammy/services/proxy-tool/db-backup/
