# Stack Improvement Checklist

## High Priority — Correctness

- [x] **Add `postgres-exporter` to monitoring stack** — orphaned `pg-export:9187` scrape target removed from `prometheus.yml`; exporter block left as commented template
- [x] **Add `MARIADB_DATABASE` to databases `.env.example`** — added with default value `akilimo` to match `MARIADB_USER`
- [x] **Fix Loki `depends_on` order** — removed inverted dependency; grafana now depends on loki instead
- [x] **Add `restart: unless-stopped` to `grafana-agent`** — already present; audit finding was a false positive
- [x] **Fix healthcheck interval on `farm-api` and `akilimo/api`** — changed from `3600s` to `60s`

## Medium Priority — Reliability

### Missing healthchecks on production services
- [ ] `fuelrod/portal`
- [ ] `fuelrod/gateway`
- [ ] `farm/farm-web`
- [ ] `akilimo/use-uptake`
- [ ] `monitoring/agent`
- [ ] `sonar/sonar`
- [ ] `metabase/mbase`
- [ ] `mail/mailpit`

### Missing resource limits (`deploy.resources.limits`)
- [ ] `fuelrod/portal`
- [ ] `fuelrod/gateway`
- [ ] `farm/farm-api`
- [ ] `farm/farm-web`
- [ ] `farm/farm-migrate`
- [ ] `akilimo/api`
- [ ] `akilimo/use-uptake`
- [ ] `metabase/mbase`
- [ ] `mail/mailpit`
- [ ] `sonar/sonar`
- [ ] `monitoring/loki`
- [ ] `monitoring/grafana`
- [ ] `monitoring/prometheus`
- [ ] `monitoring/agent`
- [ ] `db-tools/adminer`
- [ ] `db-tools/redis-admin`
- [ ] `dozzle/dozzle`

### Structural
- [x] **Remove dead `internal` network from `db-tools`** — was already absent; audit false positive
- [x] **Fix `akilimo/api` hostname** — `container_name` and `hostname` both changed to `akilimo-api`
- [x] **Align metabase naming** — `container_name` changed from `mbase` to `metabase` to match hostname
- [x] **Add `start_period` to postgres and pgbouncer healthchecks** — added `start_period: 30s` to both

## Low Priority — Housekeeping

- [ ] **Remove dead beszel volumes from monitoring** — `beszel-data` and `beszel-agent-data` are declared but services are commented out
- [ ] **Parameterise `use-uptake` image tag** — hardcoded `1.0.0`; should be `${USE_UPTAKE_TAG:-1.0.0}`
- [ ] **Tidy `akilimo` commented compute blocks** — `compute` and `compute-proxy` are large commented-out blocks; if unused, remove them; if planned, declare their volumes
- [ ] **Fix `fees` log directory permissions** — `./log/supervisor/fees.prod` and `./log/supervisor/fees.dev` don't exist on a fresh clone; Docker creates them as root-owned which can cause permission issues
