
# Fuelrod Docker Compose

Docker Compose orchestration layer combining an NGINX reverse proxy with containerised services for domain-based routing. Manages multiple independent application stacks (Fuelrod, Akilimo, Fees, and others) on a shared host.

## Architecture

### Networks

Two Docker networks are used:

| Network | Scope | Notes |
|---------|-------|-------|
| `web` | External | Must be pre-created once: `docker network create web` |
| `internal` | Private | Created automatically by Compose; isolated per stack |

Services that need cross-stack communication must both be on the `web` network.

### Compose Structure

```
docker-compose.yml              ← Fuelrod stack entry point
docker-compose-akilimo.yml      ← Akilimo stack entry point
docker-compose-monitor.yml      ← Beszel monitoring stack
  ├── compose/docker-compose.base.yml         ← Named volumes (shared)
  ├── compose/docker-compose.networks.yml     ← Network definitions
  └── compose/services/docker-compose.*.yml  ← One file per service/group
```

To add or remove a service from a stack, edit the `include:` block in the relevant entry-point file.

### Environment Files

| File | Used by |
|------|---------|
| `.env` | All stacks (base variables, image tags) |
| `.env-fuelrod` | Fuelrod stack |
| `.env-akilimo` | Akilimo stack |
| `.env-fees` | Fees syncer service |
| `.backup` | Backup scripts only — sourced at runtime, gitignored |

### Service Configuration

Laravel-based services (Fuelrod, Fees, Akilimo) use Supervisor inside their containers. Configs live in `config/<app>/supervisor/conf.d/` and are bind-mounted into the container.

---

## Starting Stacks

```bash
# Pre-requisite (run once)
docker network create web

# Fuelrod stack
docker compose -f docker-compose.yml --env-file .env --env-file .env-fuelrod up -d

# Akilimo stack
docker compose -f docker-compose-akilimo.yml --env-file .env --env-file .env-akilimo up -d

# Monitoring stack (Beszel)
docker compose -f docker-compose-monitor.yml up -d

# Start a specific service only
docker compose -f docker-compose.yml up -d postgres redis
```

---

## Backup & Restore

Backups are managed by [fuelrod-backup](https://github.com/masgeek/fuelrod-backup) (a Python CLI tool).

### Setup

Copy the sample script and configure it:

```bash
cp autobackup.sample.sh autobackup.sh
# Edit autobackup.sh and set your BACKUP_DIR, GDRIVE remote, etc.
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
./migration/batch-exporter.sh

# Load CSVs into PostgreSQL via pgloader
./migration/execute-loads.sh

# Direct CSV import
./migration/import_csv_to_pg.sh
```

---

## Utilities

```bash
# Auto-commit file changes (uses inotifywait)
./auto_commit.sh
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
