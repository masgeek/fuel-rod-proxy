# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A Docker Compose orchestration layer for domain-based routing across multiple independent application stacks (Fuelrod, Akilimo, Use-Uptake, Fees, Farm, Sonar, Metabase, and supporting tooling) on a shared host. Reverse proxying and TLS are handled by Dokploy + Traefik — routing rules are configured in Dokploy, not in the compose files. Uses two Docker networks: `internal` (private, per-stack) and `dokploy-network` (external, shared across all stacks, managed by Dokploy).

## Common Commands

### Starting Stacks

Stack files live at `stacks/<name>/docker-compose.yml`. Deploy in dependency order:

```bash
# 1. Databases — must start first (postgres, pgbouncer, maria, redis)
docker compose -f stacks/databases/docker-compose.yml up -d

# 2. Automation — requires databases (n8n)
docker compose -f stacks/automation/docker-compose.yml up -d

# 3. Monitoring — requires databases (Grafana, Prometheus, Loki, Grafana Alloy)
docker compose -f stacks/monitoring/docker-compose.yml up -d

# 4. Fuelrod — requires databases; creates the shared 'uploads' volume
docker compose -f stacks/fuelrod/docker-compose.yml up -d

# 5. Farm — requires databases + fuelrod (uses the 'uploads' volume)
docker compose -f stacks/farm/docker-compose.yml up -d

# 6. Akilimo — requires databases (MariaDB)
docker compose -f stacks/akilimo/docker-compose.yml up -d

# 7. Use-Uptake — requires akilimo (connects to Akilimo API)
docker compose -f stacks/use-uptake/docker-compose.yml up -d

# 8. Fees — requires databases
docker compose -f stacks/fees/docker-compose.yml up -d

# --- Optional / tooling stacks (order independent) ---
docker compose -f stacks/sonar/docker-compose.yml up -d
docker compose -f stacks/metabase/docker-compose.yml up -d
docker compose -f stacks/mail/docker-compose.yml up -d
docker compose -f stacks/mqtt/docker-compose.yml up -d
docker compose -f stacks/db-tools/docker-compose.yml up -d
docker compose -f stacks/dozzle/docker-compose.yml up -d

# Start a single service within a stack
docker compose -f stacks/databases/docker-compose.yml up -d postgres
```

### Backup & Restore

```bash
# Full backup (n8n → postgres → maria → archive → Google Drive)
# Copy autobackup.sample.sh → autobackup.sh and customise, then run:
./autobackup.sh

# Postgres backup (all databases, compressed, keep 7 days)
cd fuelrod-backup && poetry run fuelrod-backup backup --db-type postgres --compress --keep-days 7

# Postgres backup (specific databases and schemas)
cd fuelrod-backup && poetry run fuelrod-backup backup --db-type postgres --db mydb --schemas public,audit --compress

# Postgres restore
cd fuelrod-backup && poetry run fuelrod-backup restore --db-type postgres

# MariaDB backup/restore
cd fuelrod-backup && poetry run fuelrod-backup backup --db-type mariadb
cd fuelrod-backup && poetry run fuelrod-backup restore --db-type mariadb

# MSSQL backup/restore
cd fuelrod-backup && poetry run fuelrod-backup backup --db-type mssql
cd fuelrod-backup && poetry run fuelrod-backup restore --db-type mssql

# Google Drive sync only (dry run first)
./gbk.sh --dry-run
./gbk.sh
```

### Data Migration (MySQL → PostgreSQL)

```bash
# Export MySQL tables to CSV
./migration/batch-exporter.sh

# Load CSVs into PostgreSQL via pgloader
./migration/execute-loads.sh

# Direct CSV import
./migration/import_csv_to_pg.sh
```

### Utilities

```bash
# Auto-commit file changes (uses inotifywait)
./auto_commit.sh

# Archive and size-report SQL backup files
./archive-sql.sh --size

# Build custom Docker images (nginx + flask)
./build-images.sh
```

## Architecture

### Compose Structure

Each stack is a self-contained `docker-compose.yml` with no `include:` directives. Bind-mount paths in each compose file are **relative to that compose file's own directory**. To reference shared config at the repo root from `stacks/<name>/docker-compose.yml`, use the `../../` prefix (e.g. `../../config/supervisor/common`).

```
stacks/
  ├── databases/          ← postgres 17, pgbouncer, mariadb, redis
  ├── automation/         ← n8n
  ├── monitoring/         ← Grafana, Prometheus, Loki, Grafana Alloy
  ├── fuelrod/            ← Fuelrod service, SMS portal, SMS gateway
  ├── farm/               ← Farm Manager API, web, migrations
  ├── akilimo/            ← Akilimo API (Laravel)
  ├── use-uptake/         ← Use-Uptake frontend
  ├── fees/               ← Fee-syncer (prod + dev)
  ├── sonar/              ← SonarQube (optional)
  ├── metabase/           ← Metabase BI (optional)
  ├── mail/               ← Mailpit SMTP relay (optional)
  ├── mqtt/               ← EMQX MQTT broker (optional)
  ├── db-tools/           ← Adminer + RedisInsight (optional)
  └── dozzle/             ← Docker log viewer (optional)
config/
  ├── supervisor/         ← Supervisor process configs per app (common/, fuelrod/, fees/, akilimo/)
  ├── nginx/              ← NGINX configs
  ├── monitoring/         ← Grafana dashboards/datasources, Prometheus, Loki, Agent configs
  └── init/pgsql/         ← PostgreSQL init scripts (run on first container start)
log/
  └── supervisor/         ← Bind-mounted log directories (fees.prod/, fees.dev/)
stacks/databases/
  └── postgres/           ← postgres.conf (bind-mounted into the postgres container)
```

### PostgreSQL Initialisation

On first start (empty data volume), postgres runs every file in `config/init/pgsql/` in sorted order:

| Script | Purpose |
|--------|---------|
| `00-extensions.sql` | Enables `uuid-ossp` and `pg_stat_statements` on the primary DB |
| `01-databases.sh` | Creates databases listed in `ADDITIONAL_DBS` (comma-separated); enables `uuid-ossp` on each |

`shared_preload_libraries = 'pg_stat_statements'` is set in `stacks/databases/postgres/postgres.conf`.

### Environment Files

Each stack folder has its own `.env` (gitignored) and `.env.example` (tracked). Docker Compose auto-loads `.env` from the same directory as the compose file — no `--env-file` flags needed.

Stacks that share postgres credentials must use matching values — copy from `stacks/databases/.env`.

| Stack `.env` | Services configured |
|---|---|
| `stacks/databases/.env` | postgres, pgbouncer, mariadb, redis |
| `stacks/automation/.env` | n8n (postgres creds must match databases) |
| `stacks/monitoring/.env` | Grafana, Prometheus, Loki, Grafana Alloy |
| `stacks/fuelrod/.env` | Fuelrod, SMS portal, SMS gateway |
| `stacks/farm/.env` | Farm API, web, migrations (postgres creds must match databases) |
| `stacks/akilimo/.env` | Akilimo API |
| `stacks/use-uptake/.env` | Use-Uptake frontend |
| `stacks/fees/.env` | Fee-syncer prod + dev |
| `stacks/sonar/.env` | SonarQube (postgres creds must match databases) |
| `stacks/metabase/.env` | Metabase (postgres creds must match databases) |
| `stacks/mail/.env` | Mailpit |
| `stacks/mqtt/.env` | EMQX MQTT broker |
| `stacks/db-tools/.env` | Adminer, RedisInsight |
| `stacks/dozzle/.env` | Dozzle |
| `.backup` | Backup scripts only (sourced at runtime, gitignored) |

### Service Configuration

Laravel-based services (Fuelrod, Fees, Akilimo) use Supervisor inside their containers. Supervisor configs live in `config/supervisor/<app>/` and are bind-mounted into the container with `../../config/supervisor/...` paths. Each `.conf` file manages one process (nginx, php-fpm, scheduler, queue workers, etc.).

### Networking

- `dokploy-network`: external, created by Dokploy on install. All inter-stack communication uses this network. Create manually with `docker network create dokploy-network` when running without Dokploy.
- `internal`: declared per-stack, used for intra-stack service-to-service calls (not exposed externally).

### Cross-Stack Volumes

| Volume | Created by | Consumed by | Purpose |
|---|---|---|---|
| `uploads` | fuelrod | farm | User file uploads |

Application logs are emitted to container stdout and collected through the
Docker socket by Grafana Alloy.

### Monitoring Stack

`stacks/monitoring/docker-compose.yml` runs Grafana, Prometheus, Loki, and Grafana Alloy. Alloy discovers Fuelrod, Fees, Fees Dev, and Akilimo through the Docker socket and forwards their stdout/stderr streams to Loki. Config files are bind-mounted from `../../config/monitoring/` (relative to `stacks/monitoring/`).

## Versioning & CI

- Commits to `main` trigger automatic SemVer tagging via `masgeek/github-tag-action`
- Commit messages drive version bumps: `fix:` → patch, `feat:` → minor, `BREAKING CHANGE:` → major
- Renovate Bot manages Docker image tag updates with semantic commit prefixes
- PRs from non-owner actors are auto-approved by the `pr-automation` workflow

## SonarQube MCP (if available)

- Always disable automatic analysis (`toggle_automatic_analysis`) at task start
- Run `analyze_file_list` on any files created or modified at task end
- Re-enable automatic analysis when done
- Look up project keys with `search_my_sonarqube_projects` — never guess them
- Use USER tokens, not project tokens (project tokens cause "Not authorized" errors)
