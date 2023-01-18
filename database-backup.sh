#!/bin/bash

set -o allexport; source /home/akilimo/services/tsobu-proxy/.env; set +o allexport

if [ -z "$DB_USER" ]; then
  read -rp "Enter database user: " DB_USERNAME
else
  DB_USERNAME="$DB_USER"
fi

if [ -z "$DB_PASS" ]; then
  read -rp "Enter database password: " DB_PASSWORD
else
  DB_PASSWORD="$DB_PASS"
fi

if [ -z "$DB_NAME" ]; then
  read -rp "Enter database name: " DB_NAME
else
  DB_NAME="$DB_NAME"
fi

if [ -z "$DB_SERVICE" ]; then
  read -rp "Enter database service: " DB_SERVICE
else
  DB_SERVICE="$DB_SERVICE"
fi

timestamp=$(date +%Y%m%d%H%M%S)

filename="${timestamp}-${DB_NAME}.sql"

docker exec "${DB_SERVICE}" mysqldump --no-tablespaces -u "${DB_USERNAME}" --password="${DB_PASSWORD}" "${DB_NAME}" >"$filename"

sed -i "$filename" -e 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g'
