# Security Improvements

## 1. PostgreSQL Application User Has SUPERUSER

`compose/init/pgsql/01-init.sql:2` grants the application role full superuser privileges:

```sql
ALTER ROLE fuelrod WITH SUPERUSER CREATEDB CREATEROLE REPLICATION;
```

A SUPERUSER can bypass all access controls, read any table in any database, create or drop roles, and access the filesystem via `COPY TO/FROM`. If the application is compromised this becomes full database server compromise.

### Fix

Grant only the privileges the application actually needs. For a typical Laravel app:

```sql
-- Minimum for application operation
CREATE ROLE fuelrod WITH LOGIN PASSWORD '${DB_PASSWORD}';
GRANT CONNECT ON DATABASE fuelrod TO fuelrod;
GRANT USAGE ON SCHEMA public TO fuelrod;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO fuelrod;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO fuelrod;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO fuelrod;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO fuelrod;
```

If migrations need `CREATE TABLE`, add `CREATEDB` to the role used only during migration runs — not the runtime app role.

---

## 2. PostgreSQL Listens on All Interfaces

`config/db/postgres/postgres.conf:2` (and again at line 20 after the tuning block):

```
listen_addresses = '*'
```

Combined with the port being published to the host (`5432:5432`), this means PostgreSQL accepts connections from any network interface. On a host with a public IP, the database port is reachable from the internet unless an external firewall blocks it.

### Fix

Restrict to the Docker bridge interfaces or leave listening to Docker's internal network. The safest option on a standalone Docker host is to remove the host port binding entirely and let services connect via the `internal` network:

```yaml
# compose/services/docker-compose.postgres-stable.yml
# Remove or comment out:
# ports:
#   - "5432:5432"
```

If direct host access is required (e.g. for local development or migration tooling), bind only to localhost:

```yaml
ports:
  - "127.0.0.1:5432:5432"
```

And in `postgres.conf`, this setting can remain `*` because Docker network routing handles isolation — but the host port binding above is the real control point.

---

## 3. MariaDB Healthcheck Exposes Password in Process List

`compose/services/docker-compose.maria.yml:23`:

```yaml
test: ["CMD-SHELL", "mysqladmin ping -h localhost -u${MARIADB_USER} -p${MARIADB_PASSWORD} || exit 1"]
```

The `-p${MARIADB_PASSWORD}` flag passes the password as a command-line argument. On Linux, command arguments are visible in `/proc/<pid>/cmdline` and in `ps` output to any user on the host.

### Fix

Use a MySQL option file or the `MYSQL_PWD` environment variable:

```yaml
test: ["CMD-SHELL", "MYSQL_PWD=${MARIADB_PASSWORD} mysqladmin ping -h localhost -u${MARIADB_USER} || exit 1"]
```

Or write a `.my.cnf` file into the container at startup and reference it:

```yaml
test: ["CMD-SHELL", "mysqladmin --defaults-file=/root/.my.cnf ping -h localhost || exit 1"]
```

---

## 4. MSSQL SA Password in Container Command Args

`compose/services/docker-compose.mssql.yml:50`:

```bash
"$$SQLCMD_PATH" -S mssql -U sa -P "$$MSSQL_SA_PASSWORD" -C -i "$$f"
```

Same issue as the MariaDB healthcheck — the password is a process argument visible in `ps`.

### Fix

Use a `sqlcmd` config file or environment-based authentication. For the init container, set `MSSQL_SA_PASSWORD` in the environment (already done) and use a connection string that reads it from the environment rather than passing it as a flag. Alternatively, accept this risk for a short-lived init container since it only runs once at first boot.

---

## 5. No Secrets Management

All service credentials (database passwords, API keys, webhook URLs) are stored in `.env` files on disk. These files are gitignored, which is correct, but there is no audit trail, rotation process, or access control — anyone with filesystem access to the host can read all credentials.

### Options by effort

**Low effort:** Ensure `.env` files have restricted permissions:

```bash
chmod 600 .env .env-fuelrod .env-akilimo .env-fees .backup
```

**Medium effort:** Use Docker secrets for sensitive values (requires Swarm mode or a secrets backend like Vault).

**High effort:** Integrate with a secrets manager (HashiCorp Vault, AWS Secrets Manager, etc.) and inject values at runtime rather than storing them on disk.

At minimum, the file permission approach should be applied immediately.

---

## 6. Grafana Credentials Hardcoded in Compose

`compose/services/docker-compose.metrics.yml:43–44`:

```yaml
- GF_SECURITY_ADMIN_USER=${GRAFANA_ADMIN_USER:-admin}
- GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:?}
```

The `:?` suffix on `GRAFANA_ADMIN_PASSWORD` is correct — it will fail loudly if unset. However, the internal Grafana–Postgres connection uses hardcoded credentials (`grafana_user`/`grafana_user`) directly in the compose file rather than via env vars. See `improvements-maintainability.md` §2 for the fix.

---

## 7. Portainer Exposes Docker Socket

`compose/services/docker-compose.portainer.yml` mounts `/var/run/docker.sock`. This is standard for Portainer but grants full Docker daemon access to the container — equivalent to root on the host. Ensure:

- Portainer is not reachable on the `web` network without authentication
- The Portainer admin password is set on first boot and not left at the default
- Portainer port is not published to a public interface (bind to `127.0.0.1` if only accessed via reverse proxy)
