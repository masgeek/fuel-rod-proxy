# Proxy Tool — Docker Compose Orchestration

Docker Compose orchestration layer for domain-based routing across multiple independent application stacks on a shared host under **munywele.co.ke**. Reverse proxying and TLS termination are handled by [Dokploy](https://dokploy.com) + Traefik.

---

## Repository Layout

```
proxy-tool/
├── stacks/                    ← one folder per stack, each self-contained
│   ├── databases/             ← postgres 17, pgbouncer, mariadb, redis  [deploy first]
│   ├── automation/            ← n8n
│   ├── monitoring/            ← Grafana, Prometheus, Loki, Grafana Agent
│   ├── fuelrod/               ← Fuelrod service, SMS portal, SMS gateway
│   ├── farm/                  ← Farm Manager API, web, migrations
│   ├── akilimo/               ← Akilimo API, use-uptake
│   ├── fees/                  ← Fee-syncer (prod + dev)
│   ├── sonar/                 ← SonarQube  [optional]
│   ├── metabase/              ← Metabase BI  [optional]
│   ├── mail/                  ← Mailpit SMTP relay  [optional]
│   ├── db-tools/              ← Adminer + RedisInsight  [tunnel only]
│   └── dozzle/                ← Docker log viewer  [tunnel only]
├── config/
│   ├── supervisor/            ← Supervisor process configs (common/, fuelrod/, fees/, akilimo/)
│   ├── nginx/                 ← NGINX configs
│   ├── monitoring/            ← Grafana dashboards/datasources, Prometheus, Loki, Agent
│   └── init/pgsql/            ← PostgreSQL init scripts (run on first container start)
├── log/
│   └── supervisor/            ← Bind-mounted log dirs (fees.prod/, fees.dev/)
├── stacks/databases/postgres/ ← postgres.conf
├── IMPROVEMENTS.md            ← reliability/security checklist
├── BACKLOG.md                 ← deferred work items
└── .backup-example            ← copy to .backup (backup credentials, gitignored)
```

---

## Architecture

### Networks

| Network | Scope | Managed by |
|---|---|---|
| `dokploy-network` | External — Traefik routes here | Dokploy (created on install) |
| `internal` | Private — intra-stack only | Docker Compose (per stack) |

Create `dokploy-network` manually when running without Dokploy:
```bash
docker network create dokploy-network
```

### Reverse Proxy & TLS

All public traffic flows through Traefik (managed by Dokploy). Each service declares its routing rules and TLS config via Docker labels:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.myservice.rule=Host(`myservice.munywele.co.ke`)"
  - "traefik.http.routers.myservice.entrypoints=websecure"
  - "traefik.http.routers.myservice.tls=true"
  - "traefik.http.routers.myservice.tls.certresolver=letsencrypt"
  - "traefik.http.services.myservice.loadbalancer.server.port=80"
```

TLS certificates are issued automatically by Let's Encrypt.

### Bind Mount Paths

Bind mount paths in each compose file are **relative to that compose file's directory**. Shared config at the repo root is referenced with `../../`:

```yaml
# From stacks/fuelrod/docker-compose.yml:
- ../../config/supervisor/common:/etc/supervisor/conf.d   ✓
- ./config/supervisor/common:/etc/supervisor/conf.d       ✗  (resolves to stacks/fuelrod/config/...)
```

### PostgreSQL Initialisation

On first start (empty data volume) postgres runs `config/init/pgsql/` in sorted order:

| Script | Purpose |
|---|---|
| `00-extensions.sql` | Enables `uuid-ossp` and `pg_stat_statements` on the primary DB |
| `01-databases.sh` | Creates each database in `ADDITIONAL_DBS`; enables `uuid-ossp` on each |

### Cross-Stack Volumes

| Volume | Created by | Consumed by | Purpose |
|---|---|---|---|
| `uploads` | fuelrod | farm | User file uploads |
| `fuelrod-logs` | fuelrod | monitoring | Supervisor logs tailed by Grafana Agent |

---

## First-time Setup

```bash
# 1. Install Dokploy on the server (creates dokploy-network + Traefik)
curl -sSL https://get.dokploy.com | sh

# 2. Copy and configure env files for each stack
for stack in databases automation monitoring fuelrod farm akilimo fees sonar metabase mail; do
  cp stacks/$stack/.env.example stacks/$stack/.env
done
cp .backup-example .backup
# Edit each .env — replace all placeholder values and domains

# 3. Deploy stacks in order (see Deployment Order below)
```

---

## Deployment Order

```bash
# 1. Databases — must be first (provides postgres, pgbouncer, mariadb, redis)
docker compose -f stacks/databases/docker-compose.yml up -d

# 2. Automation — requires databases
docker compose -f stacks/automation/docker-compose.yml up -d

# 3. Monitoring — requires databases
docker compose -f stacks/monitoring/docker-compose.yml up -d

# 4. Fuelrod — requires databases; creates the shared 'uploads' volume
docker compose -f stacks/fuelrod/docker-compose.yml up -d

# 5. Farm — requires databases + fuelrod (uses 'uploads' volume)
docker compose -f stacks/farm/docker-compose.yml up -d

# 6. Akilimo — requires databases (MariaDB)
docker compose -f stacks/akilimo/docker-compose.yml up -d

# 7. Fees — requires databases
docker compose -f stacks/fees/docker-compose.yml up -d

# Optional tooling — deploy independently as needed
docker compose -f stacks/sonar/docker-compose.yml up -d
docker compose -f stacks/metabase/docker-compose.yml up -d
docker compose -f stacks/mail/docker-compose.yml up -d
```

---

## Accessing Internal Tools via SSH Tunnel

**Adminer**, **RedisInsight**, and **Dozzle** are not exposed through Traefik. They bind only to `127.0.0.1` on the server and are accessed by forwarding a local port over SSH. This means no public URL, no TLS cert needed, and no risk of accidental exposure.

### Bring up the stack

```bash
# On the server — deploy only when needed
docker compose -f stacks/db-tools/docker-compose.yml up -d   # Adminer + RedisInsight
docker compose -f stacks/dozzle/docker-compose.yml up -d     # Dozzle
```

### Open the SSH tunnel

Run this on your **local machine**:

```bash
# Adminer (postgres / mariadb GUI) — opens at http://localhost:8080
ssh -L 8080:localhost:8080 user@your-server.munywele.co.ke

# RedisInsight — opens at http://localhost:5540
ssh -L 5540:localhost:5540 user@your-server.munywele.co.ke

# Dozzle (container log viewer) — opens at http://localhost:9999
ssh -L 9999:localhost:9999 user@your-server.munywele.co.ke

# All three at once (single SSH session)
ssh -L 8080:localhost:8080 \
    -L 5540:localhost:5540 \
    -L 9999:localhost:9999 \
    user@your-server.munywele.co.ke
```

Open your browser while the SSH session is active. The tunnel closes when you exit the session.

### Take down when done

```bash
# On the server — never leave these running unattended
docker compose -f stacks/db-tools/docker-compose.yml down
docker compose -f stacks/dozzle/docker-compose.yml down
```

### Add to SSH config (optional convenience)

In `~/.ssh/config` on your local machine:

```
Host munywele-tools
    HostName your-server.munywele.co.ke
    User your-user
    LocalForward 8080 localhost:8080
    LocalForward 5540 localhost:5540
    LocalForward 9999 localhost:9999
```

Then just run `ssh munywele-tools` and all ports are forwarded automatically.

---

## Environment Files

Each stack has its own `.env` (gitignored) sourced from `.env.example`. Stacks sharing postgres credentials must use matching values — copy from `stacks/databases/.env`.

| Stack | Key variables |
|---|---|
| `databases` | `POSTGRES_USER/PASSWORD/DB`, `ADDITIONAL_DBS`, `MARIADB_*`, `REDIS_PASSWORD` |
| `automation` | `POSTGRES_*` (must match databases), `N8N_DOMAIN` |
| `monitoring` | `POSTGRES_*`, `GRAFANA_ADMIN_PASSWORD`, `GRAFANA_DOMAIN` |
| `fuelrod` | `FUELROD_TAG`, `FUELROD_DOMAIN`, `PORTAL_DOMAIN`, `GATEWAY_DOMAIN` |
| `farm` | `FARM_TAG`, `POSTGRES_*`, `JWT_SECRET`, `DEFAULT_PASSWORD` |
| `akilimo` | `AKILIMO_TAG`, `USE_UPTAKE_TAG`, `AKILIMO_DOMAIN`, `MARIADB_*` |
| `fees` | `SYNCER_TAG`, `FEES_PROD_DOMAIN`, `FEES_DEV_DOMAIN` |
| `sonar` | `SONAR_TAG`, `SONAR_DOMAIN`, `POSTGRES_*` |
| `metabase` | `METABASE_DOMAIN`, `POSTGRES_*` |
| `mail` | `MAILPIT_DOMAIN` |
| `db-tools` | `ADMINER_DEFAULT_SERVER`, `ADMINER_DESIGN` |
| `dozzle` | `DOZZLE_HOSTNAME` |

---

## Backup & Restore

```bash
# Full automated backup (n8n → postgres → mariadb → Google Drive sync)
./autobackup.sh

# PostgreSQL — all databases, compressed, keep 7 days
cd fuelrod-backup && poetry run fuelrod-backup backup --db-type postgres --compress --keep-days 7

# PostgreSQL — specific databases and schemas
cd fuelrod-backup && poetry run fuelrod-backup backup --db-type postgres --db mydb --schemas public,audit --compress

# PostgreSQL restore
cd fuelrod-backup && poetry run fuelrod-backup restore --db-type postgres

# MariaDB backup / restore
cd fuelrod-backup && poetry run fuelrod-backup backup --db-type mariadb
cd fuelrod-backup && poetry run fuelrod-backup restore --db-type mariadb

# Google Drive sync only (dry run first)
./gbk.sh --dry-run && ./gbk.sh
```

---

## Data Migration (MySQL → PostgreSQL)

```bash
./migration/batch-exporter.sh    # Export MySQL tables to CSV
./migration/execute-loads.sh     # Load CSVs into PostgreSQL via pgloader
./migration/import_csv_to_pg.sh  # Direct CSV import
```

---

## Caddy

Caddy is used as the host-level reverse proxy for WordPress-based stacks (Akilimo, and others as added). Each stack that uses Caddy keeps its own `Caddyfile` inside the stack directory (e.g. `stacks/akilimo/Caddyfile`). Copy the relevant blocks into the host's global Caddyfile.

### Common Commands

```bash
# Validate config before applying (dry run)
caddy validate --config /etc/caddy/Caddyfile

# Format / auto-indent the Caddyfile in place
caddy fmt --overwrite /etc/caddy/Caddyfile

# Reload config without downtime (no restart needed)
caddy reload --config /etc/caddy/Caddyfile

# Restart the Caddy service (when reload is not enough)
sudo systemctl restart caddy

# Stop / start
sudo systemctl stop caddy
sudo systemctl start caddy

# Enable Caddy to start on boot
sudo systemctl enable caddy

# Check service status and recent logs
sudo systemctl status caddy
sudo journalctl -u caddy -f

# Test a domain's TLS certificate
caddy adapt --config /etc/caddy/Caddyfile --pretty   # inspect adapted config

# View Caddy version
caddy version

# List all active certificates managed by Caddy
caddy list-modules

# Run Caddy in the foreground (useful for debugging)
sudo caddy run --config /etc/caddy/Caddyfile
```

### File Permissions for PHP-FPM Mounts

WordPress sites served via PHP-FPM containers run as `www-data` (UID 33). The host directory must be owned by that user so WordPress can write files (plugins, uploads, WAF files):

```bash
# Fix ownership — run once per site directory
sudo chown -R 33:33 /mnt/data/extra_storage/services/akilimo
sudo chown -R 33:33 /mnt/data/extra_storage/services/portal
```

### Stack Caddyfiles

| Stack | Caddyfile |
|---|---|
| akilimo | `stacks/akilimo/Caddyfile` |

---

## Versioning & CI

- Commits to `main` trigger automatic SemVer tagging via `masgeek/github-tag-action`
- Commit message prefixes drive version bumps: `fix:` → patch, `feat:` → minor, `BREAKING CHANGE:` → major
- Renovate Bot manages Docker image tag updates
- PRs from non-owner actors are auto-approved by the `pr-automation` workflow
