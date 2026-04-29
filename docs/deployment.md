# Deployment Guide

This guide covers deploying the full stack on a fresh server using Coolify as the platform. Coolify installs and manages Traefik (reverse proxy + automatic TLS) and provides a Git-backed UI for deploying and updating each stack.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| VPS or dedicated server | Ubuntu 22.04 / Debian 12 recommended |
| Docker 24+ and Docker Compose v2 | Coolify installs these if missing |
| Ports 80 and 443 open | In the server firewall / security group |
| A registered domain | With access to create DNS A records |
| DNS A records pointing to the server IP | One per service you want to expose |
| Git access to this repo | SSH key or HTTPS token |

---

## Step 1 — Install Coolify

Run this once on the server as root (or with sudo). The script installs Docker if it is not already present, creates the `coolify` Docker network, and starts Traefik + the Coolify management UI.

```bash
curl -fsSL https://cdn.coolify.io/install.sh | bash
```

After the script completes, Coolify is accessible at `http://<server-ip>:8000`. Open it in a browser and complete the initial account setup (create the admin user, set the instance URL).

---

## Step 2 — Configure Environment Files

On the server (or in Coolify's env editor — see Step 4), prepare the environment files:

```bash
cp .env.example .env
cp .env-fuelrod.example .env-fuelrod
cp .env-akilimo.example .env-akilimo
cp .env-fees.example .env-fees
cp .backup-example .backup
```

### Critical variables to set in `.env`

All domain variables must be set to real FQDNs before deploying. Traefik uses these to route traffic and request TLS certificates.

```bash
# Image tags
FUELROD_TAG=latest
PORTAL_TAG=latest
GATEWAY_TAG=latest
FARM_TAG=latest
SYNCER_TAG=latest

# Domains — replace example.com with your actual domain
FUELROD_DOMAIN=fuelrod.yourdomain.com
PORTAL_DOMAIN=portal.yourdomain.com
GATEWAY_DOMAIN=sms.yourdomain.com
FARM_API_DOMAIN=farm-api.yourdomain.com
FARM_WEB_DOMAIN=farm.yourdomain.com
N8N_DOMAIN=n8n.yourdomain.com
GRAFANA_DOMAIN=grafana.yourdomain.com
DOZZLE_DOMAIN=logs.yourdomain.com
PGADMIN_DOMAIN=pgadmin.yourdomain.com
METABASE_DOMAIN=metabase.yourdomain.com
SONAR_DOMAIN=sonar.yourdomain.com
AKILIMO_DOMAIN=akilimo.yourdomain.com
BESZEL_DOMAIN=monitor.yourdomain.com
```

---

## Step 3 — Add a Git Source in Coolify

1. In the Coolify UI, go to **Sources** → **Add a new Source**
2. Select **GitHub** (or **Gitea / GitLab** if self-hosted)
3. Follow the OAuth flow or paste a Personal Access Token with `repo` scope
4. Coolify will now be able to clone this repository for each stack deployment

---

## Step 4 — Create Stacks

Each top-level compose file maps to one Coolify Stack. Repeat the following for each stack:

1. Go to **Projects** → **New Project** (or select an existing project)
2. Click **+ New Resource** → **Docker Compose**
3. Select the Git source from Step 3 and choose this repository
4. Set the **Compose file path** for each stack:

| Stack | Compose file | Env files to attach |
|-------|-------------|---------------------|
| Fuelrod | `docker-compose.yml` | `.env`, `.env-fuelrod` |
| Akilimo | `docker-compose-akilimo.yml` | `.env`, `.env-akilimo` |
| Monitor | `docker-compose-monitor.yml` | `.env` |

5. In the **Environment Variables** tab, paste the contents of the relevant `.env` files, or enter variables individually
6. Leave **Auto-deploy** on if you want Coolify to redeploy when commits land on `develop`

---

## Step 5 — Deploy

Click **Deploy** for each stack. Coolify will:

1. Clone the repository
2. Pull all required Docker images
3. Start containers and attach them to the `coolify` and `internal` networks
4. Signal Traefik to pick up the new routing labels
5. Traefik requests TLS certificates from Let's Encrypt (HTTP-01 challenge on port 80)

Allow 1–2 minutes for certificates to be issued on first deploy. Subsequent deploys reuse cached certs.

Check deployment logs in the Coolify UI under the stack's **Logs** tab.

---

## Step 6 — Verify

```bash
# Check all containers are running
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Tail logs for a specific service
docker logs -f fuelrod

# Check Traefik has picked up all routers
curl -s http://localhost:8080/api/http/routers | jq '.[].rule'
# (Traefik dashboard is on port 8080 by default in Coolify)
```

Open each domain in a browser and confirm HTTPS is working with a valid certificate.

---

## DNS Setup

Each domain variable in `.env` needs a corresponding DNS A record:

```
fuelrod.yourdomain.com      → <server-ip>
portal.yourdomain.com       → <server-ip>
sms.yourdomain.com          → <server-ip>
farm.yourdomain.com         → <server-ip>
farm-api.yourdomain.com     → <server-ip>
n8n.yourdomain.com          → <server-ip>
grafana.yourdomain.com      → <server-ip>
...
```

TTL of 300s (5 min) is enough for initial setup. Increase to 3600s once everything is working.

> **Wildcard alternative:** If all services share a subdomain (e.g. `*.apps.yourdomain.com`), a single wildcard A record works. Traefik's HTTP-01 challenge does not support wildcard certs — you would need to switch to DNS-01 challenge with your DNS provider's API.

---

## Updating Services

### Via Coolify (recommended)

Push to the tracked branch (`develop`). If Auto-deploy is enabled, Coolify redeploys the affected stack automatically within seconds.

To trigger a manual redeploy: Coolify UI → Stack → **Redeploy**.

### Manually on the server

```bash
# Pull latest images and restart changed containers only
docker compose -f docker-compose.yml --env-file .env --env-file .env-fuelrod pull
docker compose -f docker-compose.yml --env-file .env --env-file .env-fuelrod up -d

# Restart a single service without rebuilding others
docker compose -f docker-compose.yml --env-file .env restart fuelrod
```

---

## Adding a New Service

1. Create `compose/services/docker-compose.<name>.yml` following the pattern of an existing service file
2. Add Traefik labels and connect to `coolify` + `internal` networks (see any existing service file)
3. Add the new `*_DOMAIN` variable to `.env` and `.env.example`
4. Add the `include:` line to the relevant top-level compose file
5. Commit and push — Coolify redeploys automatically

---

## Manual Fallback (no Coolify)

If Coolify is unavailable, the stacks can be deployed directly. The `coolify` Docker network must exist first:

```bash
docker network create coolify

# Deploy each stack
docker compose -f docker-compose.yml --env-file .env --env-file .env-fuelrod up -d
docker compose -f docker-compose-akilimo.yml --env-file .env --env-file .env-akilimo up -d
docker compose -f docker-compose-monitor.yml --env-file .env up -d
```

> Without Coolify, Traefik is not running, so services are not reachable via their domains. To expose them temporarily, uncomment the `ports:` sections in the relevant service files.

---

## Backup & Restore

See the main [README](../README.md#backup--restore) for backup commands. The backup scripts read from `.backup` (gitignored) which must be present on the server.

```bash
# Run a full backup
./autobackup.sh

# Restore postgres from latest backup
fuelrod-backup restore --db-type postgres
```

---

## Troubleshooting

### Certificate not issued

- Confirm the DNS A record resolves to the server: `dig +short fuelrod.yourdomain.com`
- Confirm port 80 is reachable from the internet: `curl http://fuelrod.yourdomain.com`
- Check Traefik logs: `docker logs coolify-proxy`
- Let's Encrypt rate-limits failed attempts. If you've hit the limit, wait 1 hour before retrying.

### Container fails to start

```bash
# Check exit code and last log lines
docker inspect <container-name> | jq '.[0].State'
docker logs --tail 50 <container-name>
```

### Service unreachable despite container running

- Confirm the container is on the `coolify` network: `docker inspect <name> | jq '.[0].NetworkSettings.Networks'`
- Confirm `traefik.enable=true` is set in the service labels: `docker inspect <name> | jq '.[0].Config.Labels'`
- Check that the `*_DOMAIN` env var was actually substituted: `docker compose config | grep traefik`

### `coolify` network missing

```bash
docker network create coolify
# Then redeploy the affected stacks
```

### Database connection refused

Databases (postgres, maria, redis) are on the `internal` network only and have no host port binding by default. To allow direct access temporarily, uncomment the `ports:` block in the relevant service file and redeploy.
