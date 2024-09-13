#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE fuelrod;
    CREATE DATABASE kvuno;
    CREATE DATABASE akilimo_db;
EOSQL
