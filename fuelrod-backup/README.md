# fuelrod-backup

**Interactive PostgreSQL backup and restore CLI — Docker-aware, wizard-driven.**

`fuelrod-backup` replaces fragile bash backup scripts with a Python CLI that gives you:

- Type-safe configuration loaded from a `.backup` or `.env` file
- Rich interactive wizards (database picker, schema filter, role analysis)
- Docker-aware subprocess handling — no binary pipe corruption, no env-var leakage
- Non-interactive mode for cron / CI (`--no-interactive`)
- `pg_dump` custom-format backups with optional gzip compression
- Automatic rotation of old backups

---

## Installation

```bash
pip install fuelrod-backup
```

Or with [pipx](https://pypa.github.io/pipx/) (recommended for CLI tools):

```bash
pipx install fuelrod-backup
```

Or inside a Poetry project:

```bash
poetry add fuelrod-backup
```

---

## Quick start

### 1. Create a config file

`fuelrod-backup` auto-discovers config in this order:

| Priority | File | Location searched |
|----------|------|-------------------|
| 1st | `.backup` | project dir, then repo root |
| 2nd | `.env` | project dir, then repo root |

You can also pass an explicit path with `--config /path/to/file`.

**`.backup`** (shell-style, used by the legacy bash scripts):

```bash
# .backup
PG_USERNAME=postgres
PG_PASSWORD=secret
PG_HOST=127.0.0.1
PG_PORT=5432
SERVICE=postgres        # Docker container name
USE_DOCKER=true
BASE_DIR=/var/backups/postgres
COMPRESS_FILE=false
KEEP_DAYS=7
```

**`.env`** (Docker Compose style — same key=value format, also supported):

```dotenv
# .env
PG_USERNAME=postgres
PG_PASSWORD=secret
PG_HOST=127.0.0.1
PG_PORT=5432
SERVICE=postgres
USE_DOCKER=true
BASE_DIR=/var/backups/postgres
COMPRESS_FILE=false
KEEP_DAYS=7
```

Both formats support:
- `# comments`
- `export KEY=value` (the `export` keyword is stripped)
- Single- and double-quoted values

> **Priority:** environment variables always override file values.

### 2. Run the interactive backup wizard

```bash
fuelrod-backup backup
```

### 3. Run the interactive restore wizard

```bash
fuelrod-backup restore
```

### 4. Non-interactive backup (cron / CI)

```bash
fuelrod-backup backup --no-interactive
```

---

## Commands

### `fuelrod-backup backup`

```
Usage: fuelrod-backup backup [OPTIONS]

  Back up one or more PostgreSQL databases.

Options:
  --no-interactive          Skip all wizard prompts; back up all databases.
  --compress / --no-compress
                            Compress output with gzip.
  --keep-days INTEGER       Delete backups older than N days (0 = keep forever).
  --db TEXT                 Database(s) to back up (repeatable). Default: all.
  --schemas TEXT            Comma-separated schemas to include (applied to every DB).
  --config PATH             Path to .backup or .env config file.
  --help                    Show this message and exit.
```

### `fuelrod-backup restore`

```
Usage: fuelrod-backup restore [OPTIONS]

  Interactively restore a PostgreSQL database from a dump file.

Options:
  --config PATH   Path to .backup or .env config file.
  --help          Show this message and exit.
```

---

## Restore wizard steps

1. **Connection** — review / override host, user, password; live connection test
2. **Database folder** — pick from directories under `BASE_DIR`
3. **Backup file** — sorted list with sizes; defaults to latest
4. **Schema selection** — parsed from dump TOC via `pg_restore --list`
5. **Table selection** — optional per-schema table filter
6. **Role analysis** — detect missing owners; offer: create / `--no-owner` / ignore
7. **Restore options** — full / schema-only / data-only, clean mode, parallel workers, dry-run
8. **Target database** — rename, drop-and-recreate, or overlay

---

## Configuration reference

| Key | Default | Description |
|-----|---------|-------------|
| `PG_USERNAME` | `postgres` | PostgreSQL role to connect as |
| `PG_PASSWORD` | *(required)* | Password |
| `PG_HOST` | `127.0.0.1` | Host (ignored in Docker mode) |
| `PG_PORT` | `5432` | Port (ignored in Docker mode) |
| `SERVICE` | `postgres` | Docker container name |
| `USE_DOCKER` | `true` | Use `docker exec` instead of direct connection |
| `BASE_DIR` | *(required)* | Root directory for backup files |
| `COMPRESS_FILE` | `false` | Gzip compress dump files |
| `KEEP_DAYS` | `7` | Retention in days (0 = keep forever) |
| `PSQL_CMD` | `psql` | Override psql binary path |
| `PG_DUMP_CMD` | `pg_dump` | Override pg_dump binary path |
| `PG_RESTORE_CMD` | `pg_restore` | Override pg_restore binary path |

---

## Config file lookup order

When no `--config` flag is given, the tool searches these locations in order and
uses the **first file found**:

```
<project-dir>/.backup      ← checked first
<project-dir>/.env
<repo-root>/.backup
<repo-root>/.env
```

This means you can drop either a `.backup` or a `.env` alongside the tool (or in
the repo root for monorepo layouts) and it will be picked up automatically.

---

## Docker notes

When `USE_DOCKER=true`, fuelrod-backup runs all commands via `docker exec`, explicitly
injecting `PGPASSWORD` and `PGUSER` as `-e` flags so the container's own
`POSTGRES_USER` env var cannot override them.

TOC reads use `docker cp` (not `docker exec -i`) to avoid binary stream corruption
under WSL/Docker Desktop.

---

## License

GNU General Public License v3 or later — see [LICENSE](LICENSE).
