#!/usr/bin/env bash

set -o allexport; source .env; set +o allexport

if [ -z "$DATABASE_USERNAME" ]; then
  read -rp "Enter database user: " DB
else
  DB="$DATABASE_USERNAME"
fi

if [ -z "$DATABASE_PASSWORD" ]; then
  read -rp "Enter database password: " DB_PASSWORD
else
  DB_PASSWORD="$DATABASE_PASSWORD"
fi

if [ -z "$DATABASE" ]; then
  read -rp "Enter database name: " DATABASE
else
  DB="$DATABASE"
fi

timestamp=$(date +%Y%m%d%H%M%S)

filename="${timestamp}-${DB}.sql"

docker exec db /usr/bin/mysqldump -u "${DB_USERNAME}" --password="${DB_PASSWORD}" "${DB}" >"$filename"

sed -i "$filename" -e 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g'
