"""
PostgreSQL runner.

- All DB queries/admin ops use psycopg (native driver) — no psql subprocess.
- Subprocesses are used only for pg_dump, pg_restore, and docker cp (no Python alternative).
- Docker mode: psycopg connects to the exposed host:port directly; docker exec is used
  only for the dump/restore binaries so there is no env-var leakage from the container.
"""

from __future__ import annotations

import gzip
import shutil
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Generator

import psycopg
from psycopg import sql as pgsql

from .config import Config


class PgError(RuntimeError):
    """Raised when a pg operation fails with a diagnosable error."""


# ──────────────────────────────────────────────────────────────────────────────
#  Internal helpers
# ──────────────────────────────────────────────────────────────────────────────

def _classify_pg_error(exc: psycopg.Error, cfg: Config) -> PgError:
    """Turn a psycopg exception into a human-readable PgError."""
    msg = str(exc).lower()
    if "password authentication failed" in msg:
        return PgError(f"Wrong password for user '{cfg.user}'. Check PG_PASSWORD in your config.")
    if "role" in msg and "does not exist" in msg:
        return PgError(f"User '{cfg.user}' does not exist. Check PG_USERNAME in your config.")
    if "pg_hba.conf" in msg:
        return PgError(f"Connection blocked by pg_hba.conf for '{cfg.user}'.")
    if "connection refused" in msg or "could not connect" in msg:
        return PgError(f"Connection refused at {cfg.host}:{cfg.port}. Is PostgreSQL running?")
    if "no route to host" in msg or "network unreachable" in msg:
        return PgError(f"Network error reaching {cfg.host}:{cfg.port}. Check PG_HOST.")
    if "could not translate host name" in msg:
        return PgError(f"Hostname '{cfg.host}' not resolvable. Check PG_HOST.")
    if "ssl" in msg:
        return PgError("SSL negotiation failed. Try PGSSLMODE=disable in your config.")
    return PgError(str(exc))


class PgRunner:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg

    # ──────────────────────────────────────────────────────────────
    #  Native psycopg connection
    # ──────────────────────────────────────────────────────────────

    @contextmanager
    def _connect(
        self, dbname: str = "postgres", *, autocommit: bool = False
    ) -> Generator[psycopg.Connection, None, None]:
        """
        Open a psycopg connection to host:port with explicit credentials.

        Works for both Docker and non-Docker modes — psycopg connects to the
        exposed host:port directly, so there is no subprocess or env-var leakage.
        autocommit=True is required for CREATE/DROP DATABASE statements.
        """
        cfg = self.cfg
        try:
            conn = psycopg.connect(
                host=cfg.host,
                port=cfg.port,
                dbname=dbname,
                user=cfg.user,
                password=cfg.password,
                connect_timeout=cfg.connection_timeout,
                autocommit=autocommit,
            )
        except psycopg.Error as exc:
            raise _classify_pg_error(exc, cfg) from exc

        try:
            yield conn
        finally:
            conn.close()

    def _query_one(self, query: str, params: tuple = (), dbname: str = "postgres") -> str:
        """Run a query returning a single scalar value as a string."""
        with self._connect(dbname) as conn:
            with conn.cursor() as cur:
                cur.execute(query, params)
                row = cur.fetchone()
                return str(row[0]) if row else ""

    def _query_col(self, query: str, params: tuple = (), dbname: str = "postgres") -> list[str]:
        """Run a query returning a single-column result as a list of strings."""
        with self._connect(dbname) as conn:
            with conn.cursor() as cur:
                cur.execute(query, params)
                return [str(row[0]) for row in cur.fetchall()]

    def _execute(self, query: str | pgsql.Composed, params: tuple = (), dbname: str = "postgres") -> None:
        """Execute a DDL statement (with autocommit)."""
        with self._connect(dbname, autocommit=True) as conn:
            with conn.cursor() as cur:
                cur.execute(query, params)

    # ──────────────────────────────────────────────────────────────
    #  Docker subprocess helpers (dump/restore only)
    # ──────────────────────────────────────────────────────────────

    def _docker_dump_prefix(self) -> list[str]:
        """docker exec prefix for pg_dump — injects PGPASSWORD only (no PGUSER leakage risk)."""
        return [
            "docker", "exec", "-i",
            "-e", f"PGPASSWORD={self.cfg.password}",
            self.cfg.service,
        ]

    def _docker_restore_prefix(self) -> list[str]:
        """docker exec prefix for pg_restore — injects PGPASSWORD + PGUSER explicitly."""
        return [
            "docker", "exec", "-i",
            "-e", f"PGPASSWORD={self.cfg.password}",
            "-e", f"PGUSER={self.cfg.user}",
            self.cfg.service,
        ]

    def _host_env(self) -> dict[str, str]:
        """OS env with PGPASSWORD set, for non-Docker subprocess calls."""
        import os
        env = os.environ.copy()
        env["PGPASSWORD"] = self.cfg.password
        return env

    # ──────────────────────────────────────────────────────────────
    #  pg_dump / pg_restore (subprocesses — unavoidable)
    # ──────────────────────────────────────────────────────────────

    def pg_dump(self, *args: str, stdout: int | None = None) -> subprocess.CompletedProcess:
        """Run pg_dump, Docker-aware. stdout is typically a file descriptor."""
        if self.cfg.use_docker:
            cmd = self._docker_dump_prefix() + [self.cfg.pg_dump_cmd] + list(args)
            return subprocess.run(cmd, stdout=stdout, check=True)
        else:
            cmd = [self.cfg.pg_dump_cmd] + list(args)
            return subprocess.run(cmd, stdout=stdout, env=self._host_env(), check=True)

    def pg_restore(self, *args: str, stdin: int | None = None) -> subprocess.CompletedProcess:
        """Run pg_restore, Docker-aware."""
        if self.cfg.use_docker:
            cmd = self._docker_restore_prefix() + [self.cfg.pg_restore_cmd] + list(args)
            return subprocess.run(cmd, stdin=stdin, check=True)
        else:
            cmd = [self.cfg.pg_restore_cmd] + list(args)
            return subprocess.run(cmd, stdin=stdin, env=self._host_env(), check=True)

    def read_toc(self, dump_file: Path) -> str:
        """
        Read pg_restore --list TOC.

        Uses docker cp to avoid binary pipe corruption under WSL/Docker Desktop.
        Decompresses .gz files to a temp file first.
        """
        work_file = dump_file
        tmp_plain: Path | None = None

        try:
            if dump_file.suffix == ".gz":
                tmp_plain = Path(tempfile.mktemp(suffix=".dump"))
                with gzip.open(dump_file, "rb") as f_in, tmp_plain.open("wb") as f_out:
                    f_out.write(f_in.read())
                work_file = tmp_plain

            if self.cfg.use_docker:
                ctr_path = f"/tmp/pg_toc_{dump_file.stem}.dump"
                subprocess.run(
                    ["docker", "cp", str(work_file), f"{self.cfg.service}:{ctr_path}"],
                    check=True,
                )
                result = subprocess.run(
                    ["docker", "exec", self.cfg.service, self.cfg.pg_restore_cmd, "--list", ctr_path],
                    capture_output=True,
                    check=True,
                )
                subprocess.run(
                    ["docker", "exec", self.cfg.service, "rm", "-f", ctr_path],
                    check=False,
                )
                return result.stdout.decode(errors="replace")
            else:
                result = subprocess.run(
                    [self.cfg.pg_restore_cmd, "--list", str(work_file)],
                    capture_output=True,
                    check=True,
                    env=self._host_env(),
                )
                return result.stdout.decode(errors="replace")
        finally:
            if tmp_plain and tmp_plain.exists():
                tmp_plain.unlink()

    # ──────────────────────────────────────────────────────────────
    #  Pre-flight + connection check
    # ──────────────────────────────────────────────────────────────

    def check_connection(self) -> None:
        """
        Pre-flight checks then a live psycopg connection test.

        Docker mode: verifies container is running and pg_dump binary is present
        (psql is no longer required — queries use psycopg directly).
        Direct mode: verifies pg_dump binary is on PATH.
        Both modes: attempts a real psycopg connection to host:port.
        """
        cfg = self.cfg

        if cfg.use_docker:
            if not shutil.which("docker"):
                raise PgError(
                    "docker binary not found in PATH. Install Docker or set USE_DOCKER=false."
                )
            state = subprocess.run(
                ["docker", "inspect", "--format", "{{.State.Status}}", cfg.service],
                capture_output=True,
                timeout=cfg.connection_timeout,
            )
            status = state.stdout.decode().strip()
            if status != "running":
                raise PgError(
                    f"Container '{cfg.service}' is not running (state: {status or 'missing'}). "
                    "Start it or check SERVICE= in your config."
                )
            # Only pg_dump/pg_restore need to exist inside the container now
            for binary in (cfg.pg_dump_cmd, cfg.pg_restore_cmd):
                chk = subprocess.run(
                    ["docker", "exec", cfg.service, "which", binary],
                    capture_output=True,
                    timeout=cfg.connection_timeout,
                )
                if chk.returncode != 0:
                    raise PgError(
                        f"'{binary}' not found inside container '{cfg.service}'. "
                        "Is this a PostgreSQL container?"
                    )
        else:
            for binary in (cfg.pg_dump_cmd, cfg.pg_restore_cmd):
                if not shutil.which(binary):
                    raise PgError(
                        f"'{binary}' not found in PATH. Install postgresql-client."
                    )

        # Live connection via native psycopg — no subprocess, no output parsing
        try:
            with self._connect("postgres") as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT 1")
        except PgError:
            raise
        except psycopg.Error as exc:
            raise _classify_pg_error(exc, cfg) from exc

    # ──────────────────────────────────────────────────────────────
    #  Database helpers
    # ──────────────────────────────────────────────────────────────

    def list_databases(self) -> list[str]:
        """Return non-template database names, sorted."""
        return self._query_col(
            "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
        )

    def get_db_size(self, dbname: str) -> str:
        """Return human-readable size of a database."""
        try:
            return self._query_one(
                "SELECT pg_size_pretty(pg_database_size(%s))", (dbname,)
            ) or "?"
        except (PgError, psycopg.Error):
            return "?"

    def get_user_schemas(self, dbname: str) -> list[str]:
        """Return user-defined schema names for a database."""
        try:
            return self._query_col(
                "SELECT nspname FROM pg_namespace "
                "WHERE nspname NOT LIKE 'pg_%%' AND nspname <> 'information_schema' "
                "ORDER BY nspname",
                dbname=dbname,
            )
        except (PgError, psycopg.Error):
            return []

    def db_exists(self, dbname: str) -> bool:
        return (
            self._query_one("SELECT 1 FROM pg_database WHERE datname = %s", (dbname,)) == "1"
        )

    def terminate_connections(self, dbname: str) -> int:
        """
        Terminate all connections to a database except the current one.
        Returns the number of connections killed.
        """
        result = self._query_one(
            "SELECT COUNT(pg_terminate_backend(pid)) FROM pg_stat_activity "
            "WHERE datname = %s AND pid <> pg_backend_pid()",
            (dbname,),
        )
        return int(result or 0)

    def drop_db(self, dbname: str) -> None:
        """Terminate active connections then drop the database."""
        self.terminate_connections(dbname)
        self._execute(
            pgsql.SQL("DROP DATABASE {}").format(pgsql.Identifier(dbname))
        )

    def create_db(self, dbname: str, owner: str | None = None) -> None:
        if owner:
            stmt = pgsql.SQL("CREATE DATABASE {} OWNER {}").format(
                pgsql.Identifier(dbname), pgsql.Identifier(owner)
            )
        else:
            stmt = pgsql.SQL("CREATE DATABASE {}").format(pgsql.Identifier(dbname))
        self._execute(stmt)

    # ──────────────────────────────────────────────────────────────
    #  Role helpers
    # ──────────────────────────────────────────────────────────────

    def role_exists(self, role: str) -> bool:
        return (
            self._query_one("SELECT 1 FROM pg_roles WHERE rolname = %s", (role,)) == "1"
        )

    def create_role(
        self,
        role: str,
        *,
        superuser: bool = False,
        can_login: bool = True,
        password: str | None = None,
    ) -> None:
        """Create a PostgreSQL role using safe identifier quoting."""
        attrs: list[pgsql.Composable] = []
        attrs.append(pgsql.SQL("SUPERUSER" if superuser else "NOSUPERUSER NOCREATEDB NOCREATEROLE"))
        attrs.append(pgsql.SQL("LOGIN" if can_login else "NOLOGIN"))

        stmt = pgsql.SQL("CREATE ROLE {} WITH ").format(pgsql.Identifier(role)) + pgsql.SQL(" ").join(attrs)

        if password:
            stmt = stmt + pgsql.SQL(" PASSWORD {}").format(pgsql.Literal(password))

        self._execute(stmt)

    # ──────────────────────────────────────────────────────────────
    #  Stats helpers
    # ──────────────────────────────────────────────────────────────

    def ensure_schemas(self, dbname: str, schemas: list[str]) -> None:
        """
        Create any schemas that don't already exist in the target database.

        Called before pg_restore so that schema-qualified objects can be restored
        even when the dump's own CREATE SCHEMA statement hasn't run yet (e.g. when
        restoring a subset of objects with -n, pg_restore may encounter table
        references before it processes the SCHEMA entry).
        """
        with self._connect(dbname, autocommit=True) as conn:
            with conn.cursor() as cur:
                for schema in schemas:
                    cur.execute(
                        pgsql.SQL("CREATE SCHEMA IF NOT EXISTS {}").format(
                            pgsql.Identifier(schema)
                        )
                    )

    def get_table_count(self, dbname: str, schema: str | None = None) -> str:
        """Return count of user tables, optionally filtered to a schema."""
        try:
            if schema:
                return self._query_one(
                    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = %s",
                    (schema,),
                    dbname=dbname,
                )
            return self._query_one(
                "SELECT COUNT(*) FROM information_schema.tables "
                "WHERE table_schema NOT IN ('pg_catalog', 'information_schema')",
                dbname=dbname,
            )
        except (PgError, psycopg.Error):
            return "?"
