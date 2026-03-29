# Fuelrod Docker Compose

Docker Compose orchestration layer combining an NGINX reverse proxy with containerised services for domain-based routing. Manages multiple independent application stacks (Fuelrod, Akilimo, Fees, and others) on a shared host.

## Repository Layout

```
proxy-tool/
├── compose/
│   ├── docker-compose.base.yml      ← named volumes (shared across stacks)
│   ├── docker-compose.networks.yml  ← network definitions
│   ├── init/
│   │   ├── mssql/                   ← MSSQL init scripts
│   │   └── pgsql/                   ← PostgreSQL init scripts
│   ├── metrics/                     ← Grafana / Prometheus / Loki / Agent configs
│   └── services/
│       └── docker-compose.*.yml     ← one file per service or service group
├── config/
│   ├── akilimo/api/supervisor/      ← Supervisor configs for Akilimo
│   ├── db/
│   │   ├── fuelrod/                 ← MariaDB config (fuelrod)
│   │   ├── mariadb/                 ← MariaDB config (generic)
│   │   └── postgres/                ← PostgreSQL config
│   ├── fees/api/supervisor/         ← Supervisor configs for Fees
│   └── fuelrod/
│       ├── api/supervisor/          ← Supervisor configs for Fuelrod API
│       └── exporter/supervisor/     ← Supervisor configs for Fuelrod Exporter
├── infra/
│   └── nginx/                       ← NGINX configs (compute, storage, generic)
├── scripts/
│   ├── auto_commit.sh
│   ├── autobackup.sample.sh
│   ├── generic_replace.sh
│   └── migration/                   ← MySQL → PostgreSQL migration scripts
├── docker-compose-fuelrod.yml       ← Fuelrod stack (rename to docker-compose.yml on server)
├── docker-compose-akilimo.yml       ← Akilimo stack
├── docker-compose-monitor.yml       ← Beszel monitoring stack
└── .env, .env-fuelrod, .env-akilimo, .env-fees
```

---

## Architecture

### Networks

| Network | Scope | Notes |
|---------|-------|-------|
| `web` | External | Must be pre-created once: `docker network create web` |
| `internal` | Private | Created automatically by Compose; isolated per stack |

Services that need cross-stack communication must both be on the `web` network.

### Compose Structure

Top-level files are the stack entry points. Each uses `include:` directives to pull in service files from `compose/services/`. To add or remove a service from a stack, edit the `include:` block in the relevant entry-point file.

On the server, the relevant stack file is copied to `docker-compose.yml` so `docker compose up -d` works without `-f`:

```bash
cp docker-compose-fuelrod.yml docker-compose.yml
```

### Environment Files

| File | Used by |
|------|---------|
| `.env` | All stacks (base variables, image tags) |
| `.env-fuelrod` | Fuelrod stack |
| `.env-akilimo` | Akilimo stack |
| `.env-fees` | Fees syncer service |
| `.backup` | Backup scripts only — sourced at runtime, gitignored |

### Service Configuration

Laravel-based services (Fuelrod, Fees, Akilimo) use Supervisor inside their containers. Configs live in `config/<app>/api/supervisor/conf.d/` and are bind-mounted into the container.

---

## Starting Stacks

```bash
# Pre-requisite (run once)
docker network create web

# Fuelrod stack
docker compose -f docker-compose-fuelrod.yml --env-file .env --env-file .env-fuelrod up -d

# Akilimo stack
docker compose -f docker-compose-akilimo.yml --env-file .env --env-file .env-akilimo up -d

# Monitoring stack (Beszel)
docker compose -f docker-compose-monitor.yml up -d

# Start a specific service only
docker compose -f docker-compose-fuelrod.yml up -d postgres redis
```

---

## Backup & Restore

Backups are managed by [fuelrod-backup](https://github.com/masgeek/fuelrod-backup) (a Python CLI tool).

### Setup

Copy the sample script to the repo root and configure it:

```bash
cp scripts/autobackup.sample.sh autobackup.sh
# Edit autobackup.sh — set BACKUP_DIR, GDRIVE remote, etc.
```

The `.backup` file (gitignored) must define: `PG_USERNAME`, `PG_PASSWORD`, `PG_HOST`, `BACKUP_DIR`, `GDRIVE`, `COMPRESS_FILE`, `USE_DOCKER`, etc.

### Running Backups

```bash
# Full automated backup (n8n → postgres → mariadb → Google Drive sync)
./autobackup.sh

# PostgreSQL — all databases, compressed, keep 7 days
fuelrod-backup backup --db-type postgres --compress --keep-days 7

# PostgreSQL — specific databases and schemas
fuelrod-backup backup --db-type postgres --db mydb --schemas public,audit --compress

# PostgreSQL restore
fuelrod-backup restore --db-type postgres

# MariaDB backup / restore
fuelrod-backup backup --db-type mariadb
fuelrod-backup restore --db-type mariadb

# MSSQL backup / restore
fuelrod-backup backup --db-type mssql
fuelrod-backup restore --db-type mssql

# n8n volume backup
fuelrod-backup n8n-backup --no-interactive

# Google Drive sync only
fuelrod-backup gdrive-sync
```

---

## Data Migration (MySQL → PostgreSQL)

```bash
# Export MySQL tables to CSV
./scripts/migration/batch-exporter.sh

# Generate pgloader .load files from CSV exports
./scripts/migration/import_csv_to_pg.sh

# Execute pgloader to load CSVs into PostgreSQL
./scripts/migration/execute-loads.sh
```

---

## Utilities

```bash
# Auto-commit file changes (uses inotifywait)
./scripts/auto_commit.sh
```

---

## SSL / Certbot

```bash
sudo certbot --nginx -d yourdomain.example.com
```

---

## Versioning & CI

- Commits to `main` trigger automatic SemVer tagging via `masgeek/github-tag-action`
- Commit message prefixes drive version bumps: `fix:` → patch, `feat:` → minor, `BREAKING CHANGE:` → major
- Renovate Bot manages Docker image tag updates
- PRs from non-owner actors are auto-approved by the `pr-automation` workflow
