#!/bin/bash

read -rp "Enter database user: " DATABASE_USERNAME
read -rp "Enter database password: " DATABASE_PASSWORD
read -rp "Enter database name: " DATABASE

timestamp=$(date +%Y%m%d%H%M%S)

filename="${timestamp}-${DATABASE}.sql"

docker exec db /usr/bin/mysqldump -u "${DATABASE_USERNAME}" --password="${DATABASE_PASSWORD}" "${DATABASE}" >"$filename"

sed -i "$filename" -e 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g'
