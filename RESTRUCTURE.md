# Repository Restructure Implementation Plan

## Goals

- Remove clutter from the repo root
- Separate service definitions from supporting infrastructure files
- Normalize inconsistent config directory layout
- Clean up tracked files that should not be in the repo

---

## Phase 1 — Quick Wins (no path changes required)

### 1.1 Delete `workdir.sh`

A 71-byte debugging artifact that prints the script's own working directory. Not referenced anywhere.

```bash
git rm workdir.sh
```

### 1.2 Delete `.env-orig`

A committed backup of the original `.env` file containing credentials. Already tracked by git — must be removed from history awareness.

```bash
git rm .env-orig
```

Add to `.gitignore` to prevent recurrence:

```
.env-orig
```

### 1.3 Verify runtime directories are gitignored

The following directories exist at root and each contain a `.gitignore` that excludes their contents. They are already safe but add them explicitly to the root `.gitignore` for clarity:

```
db-backup/
db-restore/
log/
uploads/
downloads/
static/
```

---

## Phase 2 — Scripts consolidation

Move all shell scripts into a `scripts/` directory and move the `migration/` directory under it.

### Files to move

| Current path | New path |
|---|---|
| `auto_commit.sh` | `scripts/auto_commit.sh` |
| `generic_replace.sh` | `scripts/generic_replace.sh` |
| `autobackup.sample.sh` | `scripts/autobackup.sample.sh` |
| `migration/batch-exporter.sh` | `scripts/migration/batch-exporter.sh` |
| `migration/execute-loads.sh` | `scripts/migration/execute-loads.sh` |
| `migration/import_csv_to_pg.sh` | `scripts/migration/import_csv_to_pg.sh` |

### Commands

```bash
mkdir -p scripts/migration
git mv auto_commit.sh scripts/auto_commit.sh
git mv generic_replace.sh scripts/generic_replace.sh
git mv autobackup.sample.sh scripts/autobackup.sample.sh
git mv migration/batch-exporter.sh scripts/migration/batch-exporter.sh
git mv migration/execute-loads.sh scripts/migration/execute-loads.sh
git mv migration/import_csv_to_pg.sh scripts/migration/import_csv_to_pg.sh
git rm -r migration/   # remove empty dir
```

### Path impact

`auto_commit.sh` has a hardcoded path (`/home/agwise/services/proxy/.env`) which is unrelated to this move — no change needed for the move itself.

The `autobackup.sample.sh` instructs users to copy it to `autobackup.sh` at the repo root; update the comment in the file to reflect the new location:

```bash
# Copy to repo root: cp scripts/autobackup.sample.sh autobackup.sh
```

`.gitignore` already excludes `autobackup.sh` — no change needed there.

---

## Phase 3 — Normalize `config/` supervisor structure

Currently inconsistent:

```
config/akilimo/supervisor/conf.d/        ← missing component level
config/fees/api/supervisor/conf.d/       ← has api/ level
config/fuelrod/api/supervisor/conf.d/    ← has api/ level
config/fuelrod/exporter/supervisor/      ← has exporter/ level
```

Normalize akilimo to match by adding the `api/` component level:

```
config/akilimo/api/supervisor/conf.d/    ← add api/ level
```

### Commands

```bash
mkdir -p config/akilimo/api/supervisor
git mv config/akilimo/supervisor config/akilimo/api/supervisor
```

### Path impact — files requiring updates

| File | Current path | Updated path |
|---|---|---|
| `compose/services/docker-compose.akilimo-new.yml:22` | `${PWD}/config/akilimo/supervisor/conf.d` | `${PWD}/config/akilimo/api/supervisor/conf.d` |

---

## Phase 4 — Consolidate `db_conf/` into `config/`

`db_conf/` at root holds MariaDB config. Postgres config is in `compose/services/config/pgsql/`. These belong together.

### Proposed target layout

```
config/
  db/
    mariadb/       ← from db_conf/fuelrod/ (MariaDB my.cnf files)
    postgres/      ← from compose/services/config/pgsql/
```

### Commands

```bash
mkdir -p config/db/mariadb config/db/postgres
git mv db_conf/fuelrod/* config/db/mariadb/
git rm -r db_conf/
git mv compose/services/config/pgsql/* config/db/postgres/
git rm -r compose/services/config/
```

### Path impact — files requiring updates

| File | Current bind-mount | Updated bind-mount |
|---|---|---|
| `compose/services/docker-compose.maria.yml:17` | `${PWD}/db_conf/fuelrod` | `${PWD}/config/db/mariadb` |
| `compose/services/docker-compose.postgres-stable.yml:20` | `./config/pgsql/postgres.conf` | `../../config/db/postgres/postgres.conf` |

---

## Phase 5 — Move `nginx/` into `infra/`

NGINX config lives at the repo root but is service configuration. Move it alongside other infrastructure config.

### Commands

```bash
mkdir -p infra
git mv nginx infra/nginx
```

### Path impact — files requiring updates

| File | Current bind-mount | Updated bind-mount |
|---|---|---|
| `compose/services/docker-compose.akilimo-new.yml:57` | `${PWD}/nginx/compute/nginx.conf` | `${PWD}/infra/nginx/compute/nginx.conf` |
| `compose/services/docker-compose.minio.yml:43` | `${PWD}/nginx/storage/nginx.conf` | `${PWD}/infra/nginx/storage/nginx.conf` |
| `compose/services/docker-compose.ana.yml:24` | `./nginx/nginx.conf` | `../../infra/nginx/nginx.conf` |

---

## Phase 6 — Move `compose/services/init/` and `compose/services/metrics/` out of `services/`

These are not service definition files. They are bind-mounted config/init data that happen to live next to the service files.

### Proposed target layout

```
compose/
  services/          ← *.yml files only
  init/
    mssql/           ← from compose/services/init/mssql/
    pgsql/           ← from compose/services/init/pgsql/
  metrics/           ← from compose/services/metrics/
```

### Commands

```bash
git mv compose/services/init compose/init
git mv compose/services/metrics compose/metrics
```

### Path impact — files requiring updates

| File | Current bind-mount | Updated bind-mount |
|---|---|---|
| `compose/services/docker-compose.mssql.yml:28` | `./init/mssql` | `../init/mssql` |
| `compose/services/docker-compose.postgres-stable.yml:18` | `./init/pgsql` | `../init/pgsql` |
| `compose/services/docker-compose.metrics.yml:15` | `./metrics/loki-config.yaml` | `../metrics/loki-config.yaml` |
| `compose/services/docker-compose.metrics.yml:48` | `./metrics/grafana/provisioning/...` | `../metrics/grafana/provisioning/...` |
| `compose/services/docker-compose.metrics.yml:49` | `./metrics/grafana/dashboards` | `../metrics/grafana/dashboards` |
| `compose/services/docker-compose.metrics.yml:50` | `./metrics/grafana/dashboards/...` | `../metrics/grafana/dashboards/...` |
| `compose/services/docker-compose.metrics.yml:66` | `./metrics/prometheus.yml` | `../metrics/prometheus.yml` |
| `compose/services/docker-compose.metrics.yml:83` | `./metrics/agent` | `../metrics/agent` |

---

## Final Target Structure

```
proxy-tool/
├── compose/
│   ├── docker-compose.base.yml
│   ├── docker-compose.networks.yml
│   ├── init/
│   │   ├── mssql/
│   │   └── pgsql/
│   ├── metrics/
│   │   ├── agent/
│   │   ├── grafana/
│   │   ├── loki-config.yaml
│   │   └── prometheus.yml
│   └── services/
│       └── docker-compose.*.yml   ← service definitions only
├── config/
│   ├── akilimo/api/supervisor/conf.d/
│   ├── db/
│   │   ├── mariadb/
│   │   └── postgres/
│   ├── fees/api/supervisor/conf.d/
│   └── fuelrod/
│       ├── api/supervisor/conf.d/
│       └── exporter/supervisor/
├── infra/
│   └── nginx/
│       ├── compute/
│       ├── html/
│       └── storage/
├── scripts/
│   ├── auto_commit.sh
│   ├── autobackup.sample.sh
│   ├── generic_replace.sh
│   └── migration/
│       ├── batch-exporter.sh
│       ├── execute-loads.sh
│       └── import_csv_to_pg.sh
├── docker-compose-fuelrod.yml
├── docker-compose-akilimo.yml
├── docker-compose-monitor.yml
├── .env, .env-fuelrod, .env-akilimo, .env-fees
├── .gitignore
├── README.md
└── CLAUDE.md
```

---

## Execution Order

| Phase | Description | Risk | Path updates needed |
|---|---|---|---|
| 1 | Delete `workdir.sh`, `.env-orig`, update `.gitignore` | None | No |
| 2 | Move scripts to `scripts/` | Low | Comment in `autobackup.sample.sh` |
| 3 | Normalize `config/akilimo/` structure | Low | 1 compose file |
| 4 | Consolidate `db_conf/` into `config/db/` | Medium | 2 compose files |
| 5 | Move `nginx/` to `infra/nginx/` | Medium | 3 compose files |
| 6 | Move `compose/services/init/` and `metrics/` up one level | Medium | 9 compose files |

Each phase should be a separate commit.

---

## README updates required after restructure

- Update backup section: `autobackup.sample.sh` new location → `scripts/autobackup.sample.sh`
- Update migration section: `migration/` new location → `scripts/migration/`
- Update architecture section: reflect new `infra/`, `scripts/`, `compose/init/`, `compose/metrics/` layout
