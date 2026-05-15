#!/usr/bin/env bash
set -e

# Create a non-superuser role with CREATEDB and full schema-level access on all
# databases (primary + ADDITIONAL_DBS). Skipped when APP_DB_USER is unset.
#
# Capabilities granted:
#   role level  — LOGIN, CREATEDB (can create new databases)
#   db level    — CONNECT, CREATE (schemas), TEMPORARY on every database
#   schema level — CREATE + USAGE on public schema in every database
#   object level — ALL on existing tables/sequences/functions/procedures/types
#   defaults     — ALTER DEFAULT PRIVILEGES so future objects are also covered

grant_db_privileges() {
    local db="$1"
    echo "  Granting schema privileges in '${db}'..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" <<-EOSQL
        GRANT ALL PRIVILEGES ON SCHEMA public TO "${APP_DB_USER}";
        GRANT ALL PRIVILEGES ON ALL TABLES     IN SCHEMA public TO "${APP_DB_USER}";
        GRANT ALL PRIVILEGES ON ALL SEQUENCES  IN SCHEMA public TO "${APP_DB_USER}";
        GRANT ALL PRIVILEGES ON ALL ROUTINES   IN SCHEMA public TO "${APP_DB_USER}";
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO "${APP_DB_USER}";
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "${APP_DB_USER}";
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO "${APP_DB_USER}";
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES     TO "${APP_DB_USER}";
EOSQL
}

if [ -n "${APP_DB_USER:-}" ] && [ -n "${APP_DB_PASSWORD:-}" ]; then
    # Escape single quotes for SQL string literal
    escaped_pw="${APP_DB_PASSWORD//\'/\'\'}"

    echo "Creating app role '${APP_DB_USER}'..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${APP_DB_USER}') THEN
                CREATE ROLE "${APP_DB_USER}" WITH
                    LOGIN
                    PASSWORD '${escaped_pw}'
                    CREATEDB
                    NOSUPERUSER
                    INHERIT
                    NOREPLICATION;
            END IF;
        END
        \$\$;
EOSQL

    # Primary database
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -c "GRANT ALL PRIVILEGES ON DATABASE \"${POSTGRES_DB}\" TO \"${APP_DB_USER}\";"
    grant_db_privileges "$POSTGRES_DB"

    # Additional databases
    if [ -n "${ADDITIONAL_DBS:-}" ]; then
        IFS=',' read -ra DBS <<< "$ADDITIONAL_DBS"
        for raw in "${DBS[@]}"; do
            db="${raw//[[:space:]]/}"
            if [ -n "$db" ]; then
                psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
                    -c "GRANT ALL PRIVILEGES ON DATABASE \"${db}\" TO \"${APP_DB_USER}\";"
                grant_db_privileges "$db"
            fi
        done
    fi

    echo "App role '${APP_DB_USER}' provisioned."
fi
