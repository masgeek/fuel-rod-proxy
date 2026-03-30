# Deployment Improvements

## 1. Image Version Pinning

**35 out of 36 service files** use `latest` or a `${VAR:-latest}` fallback. This makes deployments non-reproducible — pulling after an upstream release can silently change behaviour or break services.

### Current state

```yaml
# Bad — latest pulls whatever is current at pull time
image: grafana/loki:latest
image: grafana/grafana:latest
image: prom/prometheus:latest
image: grafana/agent:latest
image: amir20/dozzle:latest
image: mcr.microsoft.com/mssql/server:2025-latest   # still contains "latest"
```

```yaml
# Good — already pinned (keep this pattern)
image: mariadb:12.1
image: redis:8.4.0
image: postgres:17
image: minio/minio:${MINIO_TAG:-RELEASE.2024-03-26T22-10-45Z}
```

### Fix

Pin every image to a specific tag. Use an env var with a pinned default so the tag is overridable without editing compose files:

```yaml
image: grafana/loki:${LOKI_TAG:-3.5.0}
image: grafana/grafana:${GRAFANA_TAG:-12.0.0}
image: prom/prometheus:${PROMETHEUS_TAG:-v3.4.0}
image: grafana/agent:${GRAFANA_AGENT_TAG:-v0.43.3}
image: mcr.microsoft.com/mssql/server:${MSSQL_TAG:-2022-CU16-ubuntu-22.04}
```

Add all `*_TAG` variables to `.env` so they are visible and version-controlled without exposing credentials.

### Renovate

`renovate.json` currently uses defaults only. Add a Docker manager block to automate tag updates:

```json
{
  "extends": ["config:recommended"],
  "docker": {
    "enabled": true
  },
  "packageRules": [
    {
      "matchDatasources": ["docker"],
      "semanticCommitType": "chore",
      "semanticCommitScope": "deps"
    }
  ]
}
```

---

## 2. Healthcheck Intervals

Five services declare a healthcheck but set `interval: 3600s` (1 hour). A failing container will not be marked unhealthy for up to an hour and `depends_on: condition: service_healthy` in dependants will never trigger a restart.

**Affected files:**

| File | Service | Interval |
|------|---------|----------|
| `compose/services/docker-compose.fuelrod.yml:47` | fuelrod api | 3600s |
| `compose/services/docker-compose.fees.yml:40` | fees api | 3600s |
| `compose/services/docker-compose.fees.yml:79` | fees worker | 3600s |
| `compose/services/docker-compose.farm.yml:58` | farm api | 3600s |
| `compose/services/docker-compose.akilimo-new.yml:30` | akilimo api | 3600s |

### Fix

Use a 30–60s interval with a reasonable `start_period` to cover slow boot times:

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost/health"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 120s   # keep long start_period for Laravel boot
```

---

## 3. Missing Healthchecks

Only **13 of 36 service files** define a healthcheck. Services without one cannot be used as targets for `condition: service_healthy` and give no signal to Docker or monitoring tools when they are unhealthy.

### Services missing healthchecks (notable)

| File | Services |
|------|---------|
| `docker-compose.mssql.yml` | `mssql` |
| `docker-compose.akilimo-new.yml` | `compute`, `compute-proxy` |
| `docker-compose.minio.yml` | `mginx` |
| `docker-compose.ana.yml` | `ana-django`, `ana-dashboard` |
| `docker-compose.opensearch.yml` | `opensearch`, `opensearch-dashboards` |
| `docker-compose.dozzle.yml` | `dozzle`, `beszel-agent` |
| `docker-compose.postgres-exporter.yml` | `pg-export` |
| `docker-compose.use-uptake.yml` | `use-uptake` |

### Patterns to reuse

```yaml
# Generic HTTP health endpoint
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost/health"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 30s

# TCP port check (for databases without curl)
healthcheck:
  test: ["CMD", "bash", "-c", "cat /dev/null > /dev/tcp/localhost/1433"]
  interval: 30s
  timeout: 10s
  retries: 5
  start_period: 60s

# wget alternative (alpine images without curl)
healthcheck:
  test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost/health"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 30s
```

---

## 4. `depends_on` Conditions

Three locations use `service_started` where `service_healthy` should be used, meaning the dependent service starts before the dependency is actually ready.

### Current issues

| File | Line | Service | Dependency | Problem |
|------|------|---------|------------|---------|
| `docker-compose.exporter.yml` | 42 | exporter-worker | exporter | `service_started` — worker starts before API is ready |
| `docker-compose.fuelrod.yml` | 38 | fuelrod | `gateway` | `service_started` — gateway has no healthcheck anyway |
| `docker-compose.metrics.yml` | 80 | agent | `loki` | `service_started` — loki has a healthcheck but it is not used |

### Fix for metrics agent

```yaml
# compose/services/docker-compose.metrics.yml
depends_on:
  loki:
    condition: service_healthy   # loki already has a healthcheck
```

### Fix for exporter

Add a healthcheck to the `exporter` service, then change the worker's condition:

```yaml
depends_on:
  exporter:
    condition: service_healthy
```

### Gateway dependency

The `gateway` service has no healthcheck. Either add one and switch to `service_healthy`, or if gateway boot is fast and reliable, the current `service_started` is acceptable as a documented exception.

---

## 5. Duplicate Port Mappings

Four host ports are mapped by more than one service file. When multiple stacks that include these files run on the same host, only one container can bind the port — the second will fail silently or crash.

| Host port | Duplicate services |
|-----------|-------------------|
| `8080:80` | devops (Watchtower), docs, drone-ci server, db-admin (Adminer) |
| `8443:443` | devops, drone-ci server |
| `9000:80` | akilimo-new api, akilimo (legacy) api |
| `6381:6379` | redis (secondary bind), dragonfly |

### Fix

Assign each service a unique host port or parameterise them via env vars so they can differ per host:

```yaml
ports:
  - "${ADMINER_PORT:-8082}:8080"
  - "${DOCS_PORT:-8083}:80"
  - "${DRONE_PORT:-8084}:80"
```

Remove the secondary Redis port `6381:6379` from `docker-compose.redis.yml` unless it is actively used. If Dragonfly is a Redis replacement, the two should not run simultaneously on the same host.

---

## 6. Resource Limits

No service defines `deploy.resources` limits. A runaway or memory-leaking container can consume all available host memory or CPU, taking down other services.

### Recommended approach

Add limits appropriate to each service category. These are starting-point values — tune based on observed usage:

```yaml
# Lightweight sidecar / proxy
deploy:
  resources:
    limits:
      cpus: '0.25'
      memory: 128M

# Application service (Laravel, Node)
deploy:
  resources:
    limits:
      cpus: '1.0'
      memory: 512M

# Database
deploy:
  resources:
    limits:
      cpus: '2.0'
      memory: 2G

# Monitoring (Grafana, Prometheus, Loki)
deploy:
  resources:
    limits:
      cpus: '0.5'
      memory: 512M
```

> Note: `deploy.resources` is honoured by `docker compose` (v2) on a standalone host without Swarm. This is safe to add now.

---

## 7. External Network Pre-condition

`compose/docker-compose.networks.yml` declares `web` as `external: true`. If the network does not exist when a stack starts, Compose exits with a cryptic error. There is no automation to create it.

### Fix

Add a one-time setup step to `README.md` (already done) and optionally create a `setup.sh` at the repo root that creates the network idempotently and is safe to run on every deploy:

```bash
#!/bin/bash
# setup.sh — run once before first deployment or on each CI deploy
docker network inspect web >/dev/null 2>&1 || docker network create web
```
