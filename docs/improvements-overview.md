# Improvement Overview

Analysis of the current state of this repository across deployment reliability, maintainability, and security hardening. Findings are based on static analysis of all compose files, configs, init scripts, and shell scripts.

## Priority Table

| # | Area | Severity | Effort | Files Affected |
|---|------|----------|--------|----------------|
| 1 | Image version pinning | High | Low | 35 service files |
| 2 | Healthcheck intervals | High | Low | 5 service files |
| 3 | Missing healthchecks | High | Medium | 23 service files |
| 4 | `depends_on` conditions | High | Low | 3 service files |
| 5 | Duplicate port mappings | High | Low | 8 service files |
| 6 | PostgreSQL superuser privilege | High | Low | 1 init script |
| 7 | Restart policy inconsistency | Medium | Low | 6 service files |
| 8 | Hardcoded values in compose | Medium | Medium | 10+ service files |
| 9 | No resource limits | Medium | Medium | All services |
| 10 | `listen_addresses = '*'` in postgres | Medium | Low | 1 config file |
| 11 | No `.env.example` files | Medium | Low | — |
| 12 | Hardcoded path in `auto_commit.sh` | Medium | Low | 1 script |
| 13 | Renovate not configured for Docker | Low | Low | `renovate.json` |

## Documents

- [deployment.md](./improvements-deployment.md) — image versions, healthchecks, depends_on, ports, resource limits
- [maintainability.md](./improvements-maintainability.md) — patterns, consistency, onboarding
- [security.md](./improvements-security.md) — privilege hardening, network exposure, credential hygiene
