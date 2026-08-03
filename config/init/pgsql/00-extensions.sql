-- Extensions enabled on the primary database (POSTGRES_DB).
-- Additional databases created by 01-databases.sh also get uuid-ossp applied.
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";
