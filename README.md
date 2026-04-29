# Fuelrod Docker Compose

Docker Compose orchestration layer for domain-based routing across multiple independent application stacks (Fuelrod, Akilimo, Fees, and others) on a shared host. Reverse proxying and TLS termination are handled by [Coolify](https://coolify.io) + Traefik.

## Repository Layout

```
proxy-tool/
├── compose/
│   ├── docker-compose.base.yml      ← named volumes (shared across stacks)
│   ├── docker-compose.networks.yml  ← network definitions (internal + coolify)
│   ├── init/
│   │   ├── mssql/                   ← MSSQL init scripts
│   │   └── pgsql/                   ← PostgreSQL init scripts
│   ├── metrics/                     ← Grafana / Prometheus / Loki / Agent configs
│   └── services/
│       └── docker-compose.*.yml     ← one file per service or service group
├── config/
│   ├── db/
│   │   ├── fuelrod/                 ← MariaDB config
│   │   └── postgres/                ← PostgreSQL config
│   └── supervisor/                  ← Supervisor configs per app
├── infra/
│   └── nginx/                       ← NGINX configs (ana-dashboard, compute)
├── docker-compose-databases.yml     ← Databases stack (postgres, maria, redis) — deploy first
├── docker-compose-n8n.yml           ← n8n workflow automation — deploy second
├── docker-compose-metrics.yml       ← Monitoring stack (Grafana, Prometheus, Loki)
├── docker-compose.yml               ← Fuelrod application stack — deploy after databases
├── docker-compose-fuelrod.yml       ← Fuelrod stack (alternate, more services)
├── docker-compose-akilimo.yml       ← Akilimo stack entry point
├── docker-compose-monitor.yml       ← Beszel host monitoring
├── .env.example                     ← copy to .env
├── .env-fuelrod.example             ← copy to .env-fuelrod
├── .env-akilimo.example             ← copy to .env-akilimo
├── .env-fees.example                ← copy to .env-fees
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

| File | Used by |
|------|---------|
| `.env` | All stacks — base variables, image tags, domain names |
| `.env-fuelrod` | Fuelrod stack |
| `.env-akilimo` | Akilimo stack |
| `.env-fees` / `.env-fees-prod` | Fees syncer |
| `.env.coolify` | Coolify bootstrap only — not used by app stacks |
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
cp .env.example .env
cp .env-fuelrod.example .env-fuelrod
cp .env-akilimo.example .env-akilimo
cp .env-fees.example .env-fees
cp .backup-example .backup
# Edit each file — replace all example.com domains and placeholders

# 3. In the Coolify UI, add this repo as a Git Source, then create
#    one Stack per entry-point file — see docs/deployment.md for the full walkthrough
```

---

## Starting Stacks (manual fallback)

These commands work without Coolify for local development or emergency deploys:

```bash
# Fuelrod stack
docker compose -f docker-compose.yml --env-file .env --env-file .env-fuelrod up -d

# Akilimo stack
docker compose -f docker-compose-akilimo.yml --env-file .env --env-file .env-akilimo up -d

# Monitoring stack
docker compose -f docker-compose-monitor.yml --env-file .env up -d

# Start a single service
docker compose -f docker-compose.yml --env-file .env up -d postgres
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
