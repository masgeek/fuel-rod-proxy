#!/bin/bash

set -o allexport; source .env; set +o allexport

if [ -z "$DB_USER" ]; then
  read -rp "Enter database user: " DB
else
  DB="$DB_USER"
fi

if [ -z "$DB_URL_B" ]; then
  read -rp "Enter database password: " DB_PASSWORD
else
  DB_PASSWORD="$DB_URL_B"
fi

if [ -z "$DATABASE" ]; then
  read -rp "Enter database name: " DB_NAME
else
  DB_NAME="$DATABASE"
fi

timestamp=$(date +%Y%m%d%H%M%S)

filename="${timestamp}-${DB_NAME}.sql"

docker exec db /usr/bin/mysqldump -u "${DB_USERNAME}" --password="${DB_PASSWORD}" "${DB_NAME}" >"$filename"

sed -i "$filename" -e 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g'
