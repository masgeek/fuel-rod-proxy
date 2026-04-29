# Fuelrod Docker Compose

Docker Compose orchestration layer for domain-based routing across multiple independent application stacks (Fuelrod, Akilimo, Fees, and others) on a shared host. Reverse proxying and TLS termination are handled by [Coolify](https://coolify.io) + Traefik.

## Repository Layout

```
proxy-tool/
├── stacks/                          ← Coolify resources — one folder per stack
│   ├── databases/
│   │   ├── docker-compose.yml       ← postgres, pgbouncer, maria, redis — deploy first
│   │   └── .env.example
│   ├── automation/
│   │   ├── docker-compose.yml       ← n8n workflow automation
│   │   └── .env.example
│   ├── monitoring/
│   │   ├── docker-compose.yml       ← Grafana, Prometheus, Loki, Beszel
│   │   └── .env.example
│   ├── fuelrod/
│   │   ├── docker-compose.yml       ← Fuelrod application stack
│   │   └── .env.example
│   └── akilimo/
│       ├── docker-compose.yml       ← Akilimo application stack
│       └── .env.example
├── services/                        ← composable service units (included by stacks)
│   ├── base.yml                     ← named volumes shared across stacks
│   ├── networks.yml                 ← network definitions (internal + coolify)
│   ├── postgres.yml, maria.yml, redis.yml
│   ├── n8n.yml
│   ├── fuelrod.yml, farm.yml, fees.yml
│   ├── akilimo.yml, use-uptake.yml
│   ├── metrics.yml                  ← Grafana + Prometheus + Loki + Agent
│   └── sonarqube.yml, metabase.yml, dozzle.yml, redis-admin.yml, mailcatchers.yml
├── config/                          ← all non-compose configuration
│   ├── db/                          ← postgres.conf, my.cnf
│   ├── supervisor/                  ← Supervisor configs per app
│   ├── nginx/                       ← NGINX configs
│   ├── monitoring/                  ← Grafana / Prometheus / Loki / Agent configs
│   └── init/                        ← DB init scripts (pgsql/, mssql/)
├── scripts/                         ← backup, migration, utility scripts
├── docs/                            ← deployment guide and other docs
└── .backup-example                  ← copy to .backup (backup credentials, gitignored)
```

---

## Architecture

### Networks

| Network | Scope | Managed by |
|---------|-------|------------|
| `coolify` | External — Traefik routes here | Coolify (created on install) |
| `internal` | Private — service-to-service only | Docker Compose |

The `coolify` network is created automatically when Coolify is installed. Services that need to be publicly reachable join `coolify`; databases and background workers stay on `internal` only.

### Reverse Proxy & TLS

All public traffic flows through Traefik (managed by Coolify). Each service declares its own routing rules and TLS configuration via Docker labels:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.myservice.rule=Host(`${MY_DOMAIN}`)"
  - "traefik.http.routers.myservice.entrypoints=https"
  - "traefik.http.routers.myservice.tls.certresolver=letsencrypt"
  - "traefik.http.services.myservice.loadbalancer.server.port=80"
```

TLS certificates are issued automatically by Let's Encrypt. No manual Certbot setup required.

### Compose Structure

Top-level files are the stack entry points. Each uses `include:` directives to pull in service files from `compose/services/`. To add or remove a service from a stack, edit the `include:` block in the relevant entry-point file.

### Environment Files

Each stack folder contains its own `.env.example`. Copy it to `.env` inside that folder and fill in credentials before deploying. Docker Compose (and Coolify) auto-load `.env` from the directory containing `docker-compose.yml` — no explicit `--env-file` flags needed.

| File | Used by |
|------|---------|
| `stacks/databases/.env` | Databases stack — DB credentials |
| `stacks/automation/.env` | Automation stack — n8n config |
| `stacks/monitoring/.env` | Monitoring stack — Grafana, Beszel |
| `stacks/fuelrod/.env` | Fuelrod stack — apps + domains |
| `stacks/akilimo/.env` | Akilimo stack — apps + domains |
| `.backup` | Backup scripts — sourced at runtime, gitignored |

### Service Configuration

Laravel-based services (Fuelrod, Fees, Akilimo) use Supervisor inside their containers. Configs live in `config/<app>/supervisor/conf.d/` and are bind-mounted into the container.

---

## First-time Setup

See [docs/deployment.md](docs/deployment.md) for the full step-by-step guide.

```bash
# 1. Install Coolify on the server (creates the 'coolify' network + Traefik)
curl -fsSL https://cdn.coolify.io/install.sh | bash

# 2. Copy env files and fill in credentials + domain names
cp stacks/databases/.env.example stacks/databases/.env
cp stacks/automation/.env.example stacks/automation/.env
cp stacks/monitoring/.env.example stacks/monitoring/.env
cp stacks/fuelrod/.env.example stacks/fuelrod/.env
cp stacks/akilimo/.env.example stacks/akilimo/.env
cp .backup-example .backup
# Edit each file — replace all example.com domains and placeholders

# 3. In the Coolify UI, add this repo as a Git Source, then create
#    one resource per stack folder — see docs/deployment.md for the full walkthrough
```

---

## Starting Stacks (manual fallback)

These commands work without Coolify for local development or emergency deploys. Run all commands from the **repo root** — the `--project-directory .` flag is required because all `include:` and bind-mount paths are relative to the repo root.

```bash
# Databases (deploy first)
docker compose -f stacks/databases/docker-compose.yml --project-directory . up -d

# Automation (n8n)
docker compose -f stacks/automation/docker-compose.yml --project-directory . up -d

# Monitoring
docker compose -f stacks/monitoring/docker-compose.yml --project-directory . up -d

# Fuelrod apps
docker compose -f stacks/fuelrod/docker-compose.yml --project-directory . up -d

# Akilimo apps
docker compose -f stacks/akilimo/docker-compose.yml --project-directory . up -d

# Start a single service
docker compose -f stacks/databases/docker-compose.yml --project-directory . up -d postgres
```

> **Note:** When running manually, the `coolify` Docker network must already exist. Create it once with `docker network create coolify` if Coolify is not installed.

---

## Backup & Restore

Backups are managed by [fuelrod-backup](https://github.com/masgeek/fuelrod-backup) (a Python CLI tool).

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

## Versioning & CI

- Commits to `main` trigger automatic SemVer tagging via `masgeek/github-tag-action`
- Commit message prefixes drive version bumps: `fix:` → patch, `feat:` → minor, `BREAKING CHANGE:` → major
- Renovate Bot manages Docker image tag updates
- PRs from non-owner actors are auto-approved by the `pr-automation` workflow
