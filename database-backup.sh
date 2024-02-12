#!/bin/bash

# Uncomment the following line if you want to set all environment variables from .env file
# set -o allexport; source /home/akilimo/services/tsobu-proxy/.env; set +o allexport

while [ $# -gt 0 ]; do
  case "$1" in
    -u|-user|--user)
      user="$2"
      ;;
    -p|-pass|--pass)
      pass="$2"
      ;;
    -s|-service|--service)
      service="$2"
      ;;
    -h|-host|--host)
      host="$2"
      ;;
    *)
      printf "***************************\n"
      printf "* Error: Invalid argument. *\n"
      printf "***************************\n"
      exit 1
  esac
  shift
  shift
done

timestamp=$(date +%Y_%d%b_%H%M)

# Default values if not provided
dbUser="${user:-backup_user}"
dbPass="${pass:-andalite6}"
dbService="${service:-maria}"
dbHost="${host:-127.0.0.1}"

dir="$(dirname "$(realpath "$0")")"
echo "Directory is ${dir}"

# Determine if the database is MariaDB or MySQL
dbType=$(docker exec "${dbService}" mysql -V | grep -o -E "MariaDB|MySQL")

if [[ "$dbType" == "MariaDB" ]]; then
  dumpCommand="mariadb-dump"
elif [[ "$dbType" == "MySQL" ]]; then
  dumpCommand="mysqldump"
else
  echo "Error: Unsupported database type."
  exit 1
fi

echo "Running dump with $dbType"

# Iterate over each schema in the database
for T in $(docker exec "${dbService}" mysql -u "${dbUser}" --password="${dbPass}" -h "${dbHost}" -N -B -e 'SHOW schemas;'); do
  case $T in
    information_schema|mysql|performance_schema|sys|test)
      echo "Skipping backup of $T schema"
      ;;
    *)
      filename="${timestamp}_${T}.sql"
      nodataFileName="${timestamp}_${T}_structure.sql"
      echo "Dumping $T with data to file name ${filename}"
      docker exec "${dbService}" "$dumpCommand" --verbose --no-tablespaces -u "${dbUser}" --password="${dbPass}" "$T" > "$filename"

      echo "Dumping $T with no data to file name ${nodataFileName}"
      docker exec "${dbService}" "$dumpCommand" --verbose --no-tablespaces --no-data -u "${dbUser}" --password="${dbPass}" "$T" > "$nodataFileName"

      # Replace charset in the dump file
      sed -i "s/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g" "$filename"

      # Move dump files to the backup directory
      echo "Moving file to ${filename} in ${dir}/db-backup/"
      mv "$filename" "${dir}/db-backup/"
      mv "$nodataFileName" "${dir}/db-backup/"
      ;;
  esac
done
