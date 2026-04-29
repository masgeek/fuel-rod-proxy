# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A Docker Compose orchestration layer for domain-based routing across multiple independent application stacks (Fuelrod, Akilimo, Fees) on a shared host. Reverse proxying and TLS are handled by Coolify + Traefik. Uses two Docker networks: `internal` (private, per-stack) and `coolify` (external, shared across all stacks, managed by Coolify).

## Common Commands

### Starting Stacks

Stack files live at `stacks/<name>/docker-compose.yml`. Each auto-loads `.env` from its own folder. Deploy in this order:

```bash
# 1. Databases (postgres, pgbouncer, maria, redis)
docker compose -f stacks/databases/docker-compose.yml up -d

# 2. Automation (n8n)
docker compose -f stacks/automation/docker-compose.yml up -d

# 3. Monitoring (Grafana, Prometheus, Loki, Beszel)
docker compose -f stacks/monitoring/docker-compose.yml up -d

# 4. Fuelrod apps
docker compose -f stacks/fuelrod/docker-compose.yml up -d

# 5. Akilimo
docker compose -f stacks/akilimo/docker-compose.yml up -d

# Start a specific service only
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

Stack entry points live at `stacks/<name>/docker-compose.yml`. Each uses `include:` to pull in composable service files from `services/`:

```
stacks/
  ├── databases/docker-compose.yml   ← postgres, pgbouncer, maria, redis
  ├── automation/docker-compose.yml  ← n8n
  ├── monitoring/docker-compose.yml  ← Grafana, Prometheus, Loki, Beszel
  ├── fuelrod/docker-compose.yml     ← Fuelrod apps
  └── akilimo/docker-compose.yml     ← Akilimo apps
services/
  ├── base.yml          ← Named volumes (shared across stacks)
  ├── networks.yml      ← Network definitions (internal + coolify)
  └── *.yml             ← One file per service/service-group
config/
  ├── db/               ← Database config files (postgres.conf, my.cnf)
  ├── supervisor/       ← Supervisor configs per app
  ├── nginx/            ← NGINX configs
  ├── monitoring/       ← Grafana / Prometheus / Loki / Agent configs
  └── init/             ← DB init scripts (pgsql/, mssql/)
```

To add or remove a service from a stack, edit the `include:` block in the relevant stack file.

### Environment Files

Each stack folder has its own `.env` (gitignored) and `.env.example` (tracked). Docker Compose auto-loads `.env` from the same directory as the compose file — no `--env-file` flags needed.

| File | Used by |
|------|---------|
| `stacks/databases/.env` | Databases stack — DB credentials |
| `stacks/automation/.env` | Automation stack — n8n config |
| `stacks/monitoring/.env` | Monitoring stack — Grafana, Beszel |
| `stacks/fuelrod/.env` | Fuelrod stack — apps + domains |
| `stacks/akilimo/.env` | Akilimo stack — apps + domains |
| `.backup` | Backup scripts only (sourced at runtime, gitignored) |

### Service Configuration

Laravel-based services (Fuelrod, Fees, Akilimo) use Supervisor inside their containers. Supervisor configs live in `config/<app>/supervisor/conf.d/` and are bind-mounted into the container. Each `.conf` file manages one process (nginx, php-fpm, scheduler, queue workers, etc.).

### Networking

- `coolify` network: external, created by Coolify on install. All inter-stack communication uses this network. Create manually with `docker network create coolify` when running without Coolify.
- `internal` network: created automatically by Compose, isolated per stack. Used for intra-stack service communication.

### Monitoring Stack

`stacks/monitoring/docker-compose.yml` includes `services/metrics.yml` (Grafana + Prometheus + Loki + Grafana Agent) and adds Beszel for host monitoring. The Grafana Agent tails Supervisor log files from the shared `fuelrod-logs` volume. Prometheus config is at `config/monitoring/prometheus.yml`.

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
