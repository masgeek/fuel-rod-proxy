# Maintainability Improvements

## 1. Restart Policy Inconsistency

Two policies are used for long-running services where only one should be:

| Policy | Services using it | Should be |
|--------|------------------|-----------|
| `restart: always` | mssql, devops (x2), drone-ci (x2), mantis | `unless-stopped` |
| `restart: unless-stopped` | all other persistent services | (correct) |
| `restart: "no"` | akilimo migrate | (correct for one-shot jobs) |
| `restart: no` | exporter migrate, farm migrate, sqlinit | (correct for one-shot jobs) |

`always` restarts a container even when it was manually stopped (e.g. for maintenance). `unless-stopped` preserves the manual stop. Use `restart: always` only when a service absolutely must come back after a host reboot regardless of manual state — which is rarely the right choice on a managed host.

**Files to update:** `docker-compose-bug.yml:17`, `docker-compose-drone-ci.yml:8,28`, `docker-compose.devops.yml:21,41`, `docker-compose.mssql.yml:6`.

One-shot containers (`sqlinit`, `farm-migrate`, `exporter-migrate`) should use `restart: "no"` (quoted string) consistently — the unquoted `restart: no` is also valid YAML but mixing both forms is confusing.

---

## 2. Hardcoded Values in Compose Files

Several values are written directly into compose files rather than being driven by environment variables. This forces file edits across environments instead of just changing `.env`.

### Grafana database credentials (`docker-compose.metrics.yml:35–44`)

```yaml
# Current — hardcoded
environment:
  - POSTGRES_USER=grafana_user
  - POSTGRES_PASSWORD=grafana_user
  - POSTGRES_HOST=postgres
  - POSTGRES_DB=fuelrod
  - POSTGRES_SCHEMA=fuelrod
```

```yaml
# Better
environment:
  - POSTGRES_USER=${GRAFANA_DB_USER:-grafana_user}
  - POSTGRES_PASSWORD=${GRAFANA_DB_PASSWORD:?}
  - POSTGRES_HOST=${GRAFANA_DB_HOST:-postgres}
  - POSTGRES_DB=${GRAFANA_DB_NAME:-fuelrod}
  - POSTGRES_SCHEMA=${GRAFANA_DB_SCHEMA:-fuelrod}
```

### n8n database host/port (`docker-compose.n8n.yml:23–26`)

```yaml
# Current — hardcoded
DB_POSTGRESDB_HOST: postgres
DB_POSTGRESDB_PORT: 5432
```

```yaml
# Better
DB_POSTGRESDB_HOST: ${DB_HOST:-postgres}
DB_POSTGRESDB_PORT: ${DB_PORT:-5432}
```

### `${PWD}` in bind-mount paths

Five bind-mounts use `${PWD}` which relies on the current working directory at the time `docker compose` is invoked. If called from a different directory (e.g. from a CI script), the path resolves incorrectly.

**Affected lines:**
- `docker-compose.akilimo-new.yml:11` — `${PWD}/.env-akilimo`
- `docker-compose.akilimo-new.yml:22` — `${PWD}/config/akilimo/api/supervisor/conf.d`
- `docker-compose.akilimo-new.yml:57` — `${PWD}/infra/nginx/compute/nginx.conf`
- `docker-compose.minio.yml:43` — `${PWD}/infra/nginx/storage/nginx.conf`
- `docker-compose.maria.yml:17` — `${PWD}/config/db/fuelrod`
- `docker-compose.ana.yml:24` — `${PWD}/infra/nginx/nginx.conf`

Docker Compose resolves relative paths from the directory of the compose file. For files in `compose/services/`, use `../../` prefix instead of `${PWD}/`:

```yaml
# Instead of:
- ${PWD}/config/akilimo/api/supervisor/conf.d:/etc/supervisor/conf.d

# Use:
- ../../config/akilimo/api/supervisor/conf.d:/etc/supervisor/conf.d
```

The `fees` and `fuelrod` supervisor bind-mounts already use this pattern correctly.

---

## 3. No `.env.example` Files

All `.env*` files are gitignored. New developers cloning the repo have no way to know what variables are required or what format they take. They will only discover missing variables at runtime when a service crashes.

### Fix

Create one example file per env file, committed to the repo with all keys present but no real values:

```
.env.example
.env-fuelrod.example
.env-akilimo.example
.env-fees.example
```

Each should list every variable with a placeholder or safe default:

```bash
# .env.example
COMPOSE_PROJECT_NAME=fuelrod

# Database
DB_USERNAME=postgres
DB_PASSWORD=change_me
DB_DATABASE=fuelrod
DB_HOST=postgres
DB_PORT=5432

# Grafana
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=change_me
GRAFANA_DB_URL=postgres://grafana_user:change_me@postgres:5432/postgres?sslmode=disable

# Image tags (pin to known-good versions)
POSTGRES_TAG=17
REDIS_TAG=8.4.0
LOKI_TAG=3.5.0
GRAFANA_TAG=12.0.0
```

Document the copy step in `README.md`:

```bash
cp .env.example .env
cp .env-fuelrod.example .env-fuelrod
# Fill in values before starting stacks
```

---

## 4. Empty Environment Files

`.env-akilimo` and `.env-fees-prod` are tracked as zero-byte files. Services that load them via `env_file:` will silently use no values from them, relying entirely on defaults.

Either populate them with the required variables or add a note explaining they are intentionally empty placeholders. An empty file with a comment block explaining expected variables is more useful than a completely blank file.

---

## 5. `auto_commit.sh` Hardcoded Path

`scripts/auto_commit.sh` contains a hardcoded path that only works on one specific machine:

```bash
# scripts/auto_commit.sh:6
ENV_FILE="/home/agwise/services/proxy/.env"
```

This will silently fail or read the wrong file on any other deployment.

### Fix

Derive the path from the script's own location:

```bash
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
ENV_FILE="${SCRIPT_DIR}/../.env"
```

---

## 6. MSSQL Image Tag

```yaml
# compose/services/docker-compose.mssql.yml:3
image: mcr.microsoft.com/mssql/server:2025-latest
```

The `2025-latest` tag is not a fixed version — it will silently update when Microsoft publishes a new CU. Pin to a specific CU:

```yaml
image: mcr.microsoft.com/mssql/server:${MSSQL_TAG:-2022-CU16-ubuntu-22.04}
```

---

## 7. Nginx Upstream Hostnames Don't Match Compose Services

`infra/nginx/compute/nginx.conf` defines a round-robin upstream with four named backends:

```nginx
upstream akilimo_compute {
    server akilimo-compute-1:80 max_fails=3 fail_timeout=10s;
    server akilimo-compute-2:80 max_fails=3 fail_timeout=10s backup;
    server akilimo-compute-3:80 max_fails=3 fail_timeout=10s backup;
    server akilimo-compute-4:80 max_fails=3 fail_timeout=10s backup;
}
```

The compose file (`docker-compose.akilimo-new.yml`) defines a single `compute` service with a `replicas` count. Docker names replicas `compute-1`, `compute-2`, etc. only in Swarm mode — on a standalone host, all replicas share the hostname `compute`.

The nginx config is either intended for Swarm (in which case the standalone compose file is incomplete) or the upstream should point to `compute:80` only:

```nginx
upstream akilimo_compute {
    server compute:80;
}
```

Clarify the intended deployment model and align the nginx config with it.

---

## 8. PostgreSQL Init Script State

`compose/init/pgsql/01-init.sql` has the role and database creation commented out:

```sql
-- CREATE ROLE fuelrod WITH LOGIN PASSWORD 'fuelrod';
-- CREATE DATABASE fuelrod OWNER fuelrod;
CREATE DATABASE shirakalu OWNER fuelrod;
```

This assumes the `fuelrod` role already exists when the container initialises. On a fresh deployment against a blank volume, this will fail. Either:

- Uncomment the `CREATE ROLE` line (and change the password to use an env var via a shell-based init script), or
- Document clearly that the `fuelrod` role must be pre-created before first boot

---

## 9. Service Files That Are Never Included

Several service files exist in `compose/services/` but are commented out in all entry-point files:

- `docker-compose.agwise.yml` — never included
- `docker-compose.rya.yml` — never included
- `docker-compose.use-uptake.yml` — only in akilimo stack, may be active

Files that are genuinely unused should either be removed or moved to a `compose/services/inactive/` subdirectory so they do not create confusion about whether they are part of an active stack.
