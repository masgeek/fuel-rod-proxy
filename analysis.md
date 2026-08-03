# Codebase Analysis & Improvement Suggestions

> **Reanalysis completed:** 2026-05-15 — 85+ files audited, cross-referenced, and verified.

---

## Critical Issues (Will Cause Failures)

### 1. All `./config/` bind-mounts in fuelrod, akilimo, and fees stacks are broken

Every compose file in `stacks/fuelrod/`, `stacks/akilimo/`, and `stacks/fees/` uses paths like `./config/supervisor/...` — but the `--project-directory .` flag means paths are relative to the **repo root**, not the compose file's directory. The actual config files live at `config/supervisor/...` (repo root), but `./config/...` resolves to `stacks/fuelrod/config/...` which doesn't exist.

**Affected files:**
- `stacks/fuelrod/docker-compose.yml:43-53` — supervisor configs + log dirs
- `stacks/akilimo/docker-compose.yml:27` — supervisor configs  
- `stacks/fees/docker-compose.yml:44-46,86-88` — supervisor configs + log dirs

**Fix:** Change `./config/` to `../../config/` in fuelrod/fees/akilimo compose files. Or use absolute paths from repo root: `./config/supervisor/...` → `config/supervisor/...`.

### 2. Dockerfile copies non-existent path

`Dockerfile:2`: `COPY infra/nginx/nginx.conf` — the file is at `config/nginx/nginx.conf`, not `infra/nginx/nginx.conf`. The Dockerfile cannot build.

### 3. Dockerfile's nginx config references non-existent upstream

`config/nginx/nginx.conf:24` proxies to `ana-django:8000` — no such service exists in any compose file. This is a leftover from another project.

### 4. Duplicate release workflows

`.github/workflows/release.yml` and `.github/workflows/bump-and-tag.yml` are identical — both trigger on push to `main`, create tags via `masgeek/github-tag-action`, and create releases via `ncipollo/release-action`. This creates duplicate tags/releases on every push.

### 5. Supervisor scheduler script doesn't exist

`config/supervisor/common/laravel-scheduler.conf:4` references `/etc/scheduler/laravel-scheduler.sh` — but this file exists nowhere in the repo or any container image. The supervisor program will fail to start.

### 6. Migration scripts compute wrong PROJECT_ROOT

`scripts/migration/import_csv_to_pg.sh`, `execute-loads.sh`, and `batch-exporter.sh` all compute `PROJECT_ROOT` as `dirname "$SCRIPT_DIR"`, which resolves to `scripts/` instead of the repo root. All downstream paths (`.env`, `exports/`) are wrong.

### 7. `services/` directory documented but doesn't exist

Both `README.md` and `CLAUDE.md` describe a `services/` directory with composable units (`base.yml`, `networks.yml`, `postgres.yml`, etc.) used via `include:`. This directory **does not exist** — all stacks are self-contained.

---

## High Priority

### 8. Nginx upstreams reference services that don't exist

| Config | Upstream | Exists? |
|--------|----------|---------|
| `config/nginx/nginx.conf` | `ana-django:8000` | ✗ |
| `config/nginx/storage/nginx.conf` | `minio:9000`, `minio:9001` | ✗ |
| `config/nginx/compute/nginx.conf` | `akilimo-compute-1..4` | ✗ |

All three nginx configs are stale orphans from projects not deployed here.

### 9. PostgreSQL init script fails on first deploy

`config/init/pgsql/01-init.sql`:
- `CREATE ROLE fuelrod` — commented out
- `CREATE DATABASE fuelrod` — commented out
- `ALTER ROLE fuelrod WITH SUPERUSER` — this fails if the role doesn't exist

On a fresh PostgreSQL volume, the script crashes because it assumes `fuelrod` role pre-exists.

### 10. PostgreSQL user is SUPERUSER

`ALTER ROLE fuelrod WITH SUPERUSER CREATEDB CREATEROLE REPLICATION` grants excessive privileges to the application user.

### 11. Automation stack uses bare env vars with no fallback

`stacks/automation/docker-compose.yml:41-42`:
```yaml
DB_POSTGRESDB_USER: ${POSTGRES_USER}
DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
```
No `:-` default, no `:?` fail-fast. If unset, Docker Compose silently substitutes empty strings. All other stacks use `:?` or `:-`.

### 12. `merge-to-develop.yml` triggers self-PRs on develop

Pushing to `develop` triggers `merge-to-develop.yml`, which tries to create a PR from `develop` to `develop` — a self-referencing no-op.

### 13. Renovate won't update Docker image tags

`renovate.json` has no `docker:enable` preset and no Docker-specific `packageRules`. Docker tags will never be updated by Renovate.

### 14. Grafana dashboard provisioning does nothing

`config/monitoring/grafana/dashboards/dashboards.yaml` configures a provider that scans a directory with zero JSON dashboard files. Provisioning succeeds but loads nothing.

### 15. `application.yml` references non-existent Kafka

`application.yml:5`: `bootstrap.servers: "kafka:9092"` — no Kafka service exists in any compose file. AKHQ is also not deployed.

### 16. Docs reference wrong network name

| Doc | Says | Reality |
|-----|------|---------|
| `README.md` | `coolify` | `dokploy-network` |
| `CLAUDE.md` | `dokploy-network` | Correct ✓ |

### 17. CLAUDE.md has dead/invalid references

| Reference | Issue |
|-----------|-------|
| `cd fuelrod-backup && poetry run fuelrod-backup` | `fuelrod-backup/` directory doesn't exist |
| `./migration/batch-exporter.sh` | Actual path is `./scripts/migration/batch-exporter.sh` |
| `./archive-sql.sh`, `./build-images.sh` | Neither file exists |
| `config/db/` path | Configs are in `stacks/databases/` |

---

## Medium Priority

### 18. .env.example files missing documented vars

| Stack | Missing Vars |
|-------|-------------|
| **databases** | `PGBOUNCER_POOL_MODE`, `PGBOUNCER_MAX_CLIENT_CONN`, `PGBOUNCER_POOL_SIZE` |
| **automation** | `N8N_TAG`, `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS`, `N8N_RUNNERS_ENABLED`, `N8N_METRICS`, `N8N_QUEUE_HEALTH_CHECK_ACTIVE`, `N8N_EXECUTIONS_DATA_PRUNE`, `N8N_EXECUTIONS_TIMEOUT` |

### 19. `depends_on` uses `service_started` instead of `service_healthy`

- `fuelrod` → `gateway`
- `grafana` → `loki`  
- `agent` → `loki`

Target services also lack healthchecks.

### 20. `POSTGRES_SCHEMA` in databases `.env.example` has no consumer

`stacks/databases/.env.example` documents `POSTGRES_SCHEMA`, but no compose file or config references it for the databases stack. It's consumed by Grafana's datasource config, not databases.

### 21. `ADDITIONAL_DBS` has no consumer anywhere

`stacks/databases/.env.example:11`: `ADDITIONAL_DBS=akilimo,shirakalu` — not referenced in any compose file or config.

### 22. pr-automation auto-approves all non-owner PRs

`.github/workflows/pr-automation.yml` auto-approves PRs from `github.actor != 'masgeek'`. This means any external fork PR is auto-approved.

### 23. `generic_replace.sh` advertises long options but uses `getopts`

Usage message says `--search`, `--replace`, `--files` but `getopts` only handles single-letter flags. Long options always fail.

### 24. Fuelrod supervisor mount risks file collision

Mounts a whole directory (`config/supervisor/common/`) AND individual files (`config/supervisor/fuelrod/*.conf`) to the same container path `/etc/supervisor/conf.d`. No collision currently, but fragile.

### 25. `GRAFANA_ADMIN_PASSWORD` `:?` has no error message

`stacks/monitoring/docker-compose.yml:84`: `${GRAFANA_ADMIN_PASSWORD:?}` — should have a descriptive message like `:?GRAFANA_ADMIN_PASSWORD is required`.

---

## Low Priority

| # | Issue | Location |
|---|-------|----------|
| 26 | `migrate copy.template` has space in filename | `migrate copy.template` |
| 27 | `fees/disabled/sync-mpesa.conf` missing `inherit=defaults` | `config/supervisor/fees/disabled/sync-mpesa.conf` |
| 28 | `.vscode/settings.json` missing file associations for `.env-fees`, `.backup` | `.vscode/settings.json` |
| 29 | `.backup-example` missing docs for `DB_TYPE`, `USE_DOCKER`, `PG_HOST` | `.backup-example` |
| 30 | `deployment.md` lists `FARM_TAG` under fuelrod (should be farm) | `docs/deployment.md` |
| 31 | 9 images on `:latest` or no pinned tag | Multiple compose files |
| 32 | 12 services missing healthchecks | Multiple compose files |
| 33 | 10 empty supervisor queue `.conf` files in `config/supervisor/common/` | `config/supervisor/common/queue-*.conf` |

---

## Summary

| Priority | Count | Key Actions |
|----------|-------|-------------|
| **Critical** | 7 | Fix bind-mount paths (fuelrod/akilimo/fees), fix Dockerfile, remove duplicate release workflow, fix scheduler script ref, fix migration PROJECT_ROOT, create or remove services/ dir |
| **High** | 10 | Remove orphaned nginx configs, fix PG init script, tighten PG permissions, fix automation bare env vars, fix merge-to-develop trigger, enable Renovate Docker, remove stale Grafana dashboards stub, fix AKHQ config, update docs |
| **Medium** | 10 | Complete .env.example coverage, add healthchecks, fix depends_on conditions, audit stale env vars, tighten pr-automation, fix generic_replace.sh, improve error messages |
| **Low** | 8 | Filename cleanup, missing config associations, doc corrections, pin image tags |
