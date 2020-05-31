#!/bin/bash

timestamp=$(date +%Y%m%d%H%M%S)

filename="${timestamp}-fuelrod.sql"

docker exec db /usr/bin/mysqldump -u "${DATABASE_USERNAME}" --password="${DATABASE_PASSWORD}" "${DATABASE}" >"$filename"
