#!/bin/bash
set -e

# This script is run by postgres entrypoint during initialization
# Environment variables available:
#   POSTGRES_USER (default: postgres) - admin user
#   POSTGRES_PASSWORD - admin password
#   POSTGRES_DB (default: postgres) - default database
#   DB_USERNAME - application user (defaults to POSTGRES_USER)
#   ADDITIONAL_DBS - comma-separated list of additional databases to create
#   DB_CREATE_USER - if set, creates the DB_USERNAME role with superuser privileges

APP_USER="${DB_USERNAME:-$POSTGRES_USER}"

# Grant superuser privileges to app user if requested
if [ "${DB_CREATE_USER:-true}" = "true" ]; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
        ALTER ROLE ${APP_USER} WITH SUPERUSER CREATEDB CREATEROLE REPLICATION;
EOSQL
fi

# Create additional databases from comma-separated list
if [ -n "${ADDITIONAL_DBS:-}" ]; then
    IFS=',' read -ra DBS <<< "$ADDITIONAL_DBS"
    for db in "${DBS[@]}"; do
        db=$(echo "$db" | xargs) # trim whitespace
        if [ -n "$db" ]; then
            psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
                SELECT 'CREATE DATABASE ${db} OWNER ${APP_USER}'
                WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db}')\gexec
EOSQL
        fi
    done
fi
