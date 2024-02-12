#!/bin/bash

# Function to display error messages
error() {
  echo "Error: $1" >&2
  exit 1
}

# Function to determine database runner based on type
get_db_runner() {
  local db_type="$1"
  case "$db_type" in
    mariadb)
      echo "mariadb"
      ;;
    mysql)
      echo "mysql"
      ;;
    *)
      error "Unsupported database type: $db_type"
      ;;
  esac
}

# Function to perform database dump
perform_database_dump() {
  local db_service="$1"
  local db_runner="$2"
  local db_user="$3"
  local db_pass="$4"
  local db_host="$5"
  local timestamp="$6"
  
  # Iterate over each schema in the database
  for schema in $(docker exec "$db_service" "$db_runner" -u "$db_user" --password="$db_pass" -h "$db_host" -N -B -e 'SHOW schemas;'); do
    case $schema in
      information_schema|mysql|performance_schema|sys|test)
        echo "Skipping backup of $schema schema"
        ;;
      *)
        filename="${timestamp}_${schema}.sql"
        nodata_filename="${timestamp}_${schema}_structure.sql"
        echo "Dumping $schema with data to file: $filename"
        docker exec "$db_service" "$dump_command" --verbose --no-tablespaces -u "$db_user" --password="$db_pass" "$schema" > "$filename"

        # echo "Dumping $schema with no data to file: $nodata_filename"
        # docker exec "$db_service" "$dump_command" --verbose --no-tablespaces --no-data -u "$db_user" --password="$db_pass" "$schema" > "$nodata_filename"

        # Replace charset in the dump file
        sed -i "s/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g" "$filename"

        # Move dump files to the backup directory
        echo "Moving files to ${dir}/db-backup/"
        mv "$filename" "${dir}/db-backup/"
        # mv "$nodata_filename" "${dir}/db-backup/"
        ;;
    esac
  done
}

# Parse command-line arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -u|--user)
      db_user="$2"
      ;;
    -p|--pass)
      db_pass="$2"
      ;;
    -s|--service)
      db_service="$2"
      ;;
    -h|--host)
      db_host="$2"
      ;;
    -t|--type)
      db_type="$2"
      ;;
    *)
      error "Invalid argument: $1"
      ;;
  esac
  shift 2
done

# Set default values if not provided
db_user="${db_user:-backup_user}"
db_pass="${db_pass:-user_pass}"
db_service="${db_service:-maria}"
db_host="${db_host:-127.0.0.1}"
db_type="${db_type:-MariaDB}" # Default to MariaDB if not provided
db_type=$(echo "$db_type" | tr '[:upper:]' '[:lower:]') # Convert to lowercase

# Determine database runner and dump command
db_runner=$(get_db_runner "$db_type")
dump_command="${db_runner}-dump"

echo "Running dump with $db_type and DB runner $db_runner"

# Check if connection is successful
if ! docker exec "$db_service" "$db_runner" -u "$db_user" --password="$db_pass" -h "$db_host" -N -B -e 'SHOW schemas;' &>/dev/null; then
  error "Unable to connect to the database."
fi

# Get the current directory
dir="$(dirname "$(realpath "$0")")"
echo "Directory is $dir"

# Get the current timestamp
timestamp=$(date +%Y_%d%b_%H%M)

# Perform database dump
perform_database_dump "$db_service" "$db_runner" "$db_user" "$db_pass" "$db_host" "$timestamp"