-- Akilimo database initialization
ALTER ROLE akilimo WITH SUPERUSER CREATEDB CREATEROLE REPLICATION;

CREATE DATABASE akilimo OWNER akilimo;
