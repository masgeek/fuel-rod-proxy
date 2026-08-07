# Backlog

Items deferred from active work. Revisit when time and risk tolerance allow.

---

## Security

### Per-application PostgreSQL roles
**Priority:** Medium
**Risk if deferred:** High blast radius on credential compromise

Currently all application stacks connect to PostgreSQL as the superuser (`POSTGRES_USER`). The proper pattern is one dedicated role per application database with only the privileges that application needs.

**Proposed approach:**
- Add an init script (`02-roles.sh`) that creates one role per database:
  - `fuelrod_user` → owner of `fuelrod` database
  - `shirakalu_user` → owner of `shirakalu` database
  - `sonar_user` → owner of `sonar` database
  - `metabase_user` → owner of `metabase` database
- Each role gets: `LOGIN`, `NOSUPERUSER`, schema-level `ALL PRIVILEGES` on its own database only
- Each application stack `.env` gets its own `DB_USER` / `DB_PASSWORD` pointing at the scoped role
- The superuser (`POSTGRES_USER`) is used only by pgbouncer and init scripts, never by applications

**Why deferred:** Requires coordinated credential changes across all application stacks and container image configs. Low risk in a single-tenant self-hosted environment with port 5432 not exposed to the public internet.
