# Host Port Allocation

Central registry of host port bindings per stack. All application-facing
services bind to `127.0.0.1` and are exposed publicly only through the Caddy
reverse proxy. Infrastructure ports (databases, cache, mail) keep their
standard ports for compatibility.

## Application stacks (9xxx)

| Stack | Service | Host port | Container port | Caddyfile |
|-------|---------|-----------|----------------|-----------|
| akilimo | api | 9100 | 80 | `stacks/akilimo/Caddyfile` |
| fuelrod | api | 9200 | 80 | `stacks/fuelrod/Caddyfile` |
| fuelrod | portal | 9201 | 80 | `stacks/fuelrod/Caddyfile` |
| farm | api | 9300 | 3001 | — |
| farm | web | 9301 | 80 | — |
| fees | api | 9400 | 80 | `stacks/fees/Caddyfile` |
| fees | dev api | 9401 | 80 | `stacks/fees/Caddyfile` |
| use-uptake | web | 9500 | 4242 | — |
| s3 | s3 api | 9612 | 3900 | `stacks/s3/Caddyfile` |
| kvuno | api | 9800 | 5000 | `stacks/kvuno/Caddyfile` |
| keycloak | keycloak | 9850 | 8080 | `stacks/keycloak/Caddyfile` |
| sonar | sonar | 9900 | 9000 | — |
| dozzle | dozzle | 9999 | 8080 | — |

> **Note:** `s3` is a single container; the S3 API (9612) is its only published
> port. The admin API and RPC bind to loopback inside the container and are
> reached via `docker exec s3 /garage ...`.

## Monitoring stack

| Service | Host port | Container port |
|---------|-----------|----------------|
| loki | 3100 | 3100 |
| prometheus | 9090 | 9090 |
| grafana | 9600 | 3000 |
| alloy | — (exposed, not published) | 12345 |

## Automation stack

| Service | Host port | Container port |
|---------|-----------|----------------|
| n8n | 9700 | 5678 |

## Infrastructure (standard ports)

| Stack | Service | Host port | Container port |
|-------|---------|-----------|----------------|
| databases | postgres | 5432 | 5432 |
| databases | pgbouncer | 6432 | 5432 |
| databases | maria | 3306 | 3306 |
| cache | redis | 6379 | 6379 |
| mail | mailpit | 1025 | 1025 |
| mssql | mssql | 1433 | 1433 |

## On-demand tools (db-tools)

| Service | Host port | Container port |
|---------|-----------|----------------|
| adminer | 8080 | 8080 |
| redis-insight | 5540 | 5540 |

> **Note:** `db-tools` is deployed only when actively needed, so 8080 remains
> free for it. If a permanent service ever needs 8080, reassign adminer first.

## Allocation rules

1. **9xxx range** — every application web service gets a port in this range,
   grouped per stack (e.g. fuelrod = 92xx, farm = 93xx, fees = 94xx).
2. **127.0.0.1 binding** — application and admin ports bind to loopback only.
   Do not add `host:container` mappings without the `127.0.0.1` prefix.
3. **Standard ports preserved** — databases and mail keep their well-known
   ports (3306, 5432, 6379, 1025, 1433) to avoid breaking client configs.
4. **New stack?** — pick the next free 9xxx slot and add a row to this table.
