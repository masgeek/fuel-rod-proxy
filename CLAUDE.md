# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A Docker Compose orchestration layer that combines an NGINX reverse proxy with containerized services for domain-based routing. It manages multiple independent application stacks (Fuelrod, Akilimo, Fees) on a shared host using two Docker networks: `internal` (private, not externally routable) and `web` (external, must be pre-created with `docker network create web`).

## Common Commands

### Starting Stacks

```bash
# Fuelrod stack (main)
docker compose -f docker-compose.yml --env-file .env --env-file .env-fuelrod up -d

# Akilimo stack
docker compose -f docker-compose-akilimo.yml --env-file .env --env-file .env-akilimo up -d

# Monitoring stack (Beszel)
docker compose -f docker-compose-monitor.yml up -d

# Start specific service only
docker compose -f docker-compose.yml up -d postgres redis
```

### Backup & Restore

```bash
# Full backup (n8n → postgres → maria → archive → Google Drive)
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

The repo uses Docker Compose `include:` directives to assemble stacks from modular files:

```
docker-compose.yml              ← Fuelrod stack entry point
docker-compose-akilimo.yml      ← Akilimo stack entry point
docker-compose-monitor.yml      ← Beszel monitoring stack
  ├── compose/docker-compose.base.yml       ← Named volumes (shared across stacks)
  ├── compose/docker-compose.networks.yml   ← Network definitions (internal + web)
  └── compose/services/docker-compose.*.yml ← One file per service/service-group
```

Each top-level compose file selects which service files to include by commenting/uncommenting lines. To add or remove a service from a stack, edit the `include:` block in the stack entry point.

### Environment Files

| File | Used by |
|------|---------|
| `.env` | All stacks (base variables, image tags) |
| `.env-fuelrod` | Fuelrod stack |
| `.env-akilimo` | Akilimo stack |
| `.env-fees` | Fees syncer service |
| `.backup` | Backup scripts only (sourced at runtime, gitignored) |

Backup scripts source `.backup` from the script's own directory. This file should define: `PG_USERNAME`, `PG_PASSWORD`, `PG_HOST`, `BACKUP_DIR`, `GDRIVE`, `COMPRESS_FILE`, `USE_DOCKER`, etc.

### Service Configuration

Laravel-based services (Fuelrod, Fees, Akilimo) use Supervisor inside their containers. Supervisor configs live in `config/<app>/supervisor/conf.d/` and are bind-mounted into the container. Each `.conf` file manages one process (nginx, php-fpm, scheduler, queue workers, etc.).

### Networking

- `web` network: must exist before starting any stack — create once with `docker network create web`
- `internal` network: created automatically by Docker Compose, isolated between stacks
- Services that need inter-stack communication must both be on `web`

### Monitoring Stack

`compose/services/docker-compose.metrics.yml` deploys Grafana + Prometheus + Loki + Grafana Agent as a single unit. The Grafana Agent tails Supervisor log files from the `fuelrod-logs` volume. Prometheus config is at `compose/metrics/prometheus.yml`.

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
