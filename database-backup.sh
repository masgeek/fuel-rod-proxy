#!/bin/bash

read -rp "Enter database user: " DATABASE_USERNAME
read -rp "Enter database password: " DATABASE_PASSWORD
read -rp "Enter database name: " DATABASE

timestamp=$(date +%Y%m%d%H%M%S)

filename="${timestamp}-fuelrod.sql"

docker exec db /usr/bin/mysqldump -u "${DATABASE_USERNAME}" --password="${DATABASE_PASSWORD}" "${DATABASE}" >"$filename"
