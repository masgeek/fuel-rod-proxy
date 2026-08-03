#!/usr/bin/env bash
set -e

# Create additional databases listed in ADDITIONAL_DBS (comma-separated).
# Each database is owned by POSTGRES_USER and gets uuid-ossp enabled.
# This script runs only when the data directory is empty (first container start).

create_database() {
    local db="$1"

    if psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
            -tAc "SELECT 1 FROM pg_database WHERE datname = '${db}'" | grep -q 1; then
        echo "Database '${db}' already exists, skipping."
    else
        echo "Creating database '${db}'..."
        createdb --username "$POSTGRES_USER" --owner "$POSTGRES_USER" "${db}"
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${db}" \
            -c 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp";'
        echo "Database '${db}' ready."
    fi
}

if [ -n "${ADDITIONAL_DBS:-}" ]; then
    IFS=',' read -ra DBS <<< "$ADDITIONAL_DBS"
    for raw in "${DBS[@]}"; do
        db="${raw//[[:space:]]/}"
        [ -n "$db" ] && create_database "$db"
    done
fi
