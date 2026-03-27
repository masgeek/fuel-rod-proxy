"""MariaDB / MySQL adapter.

Driver  : pymysql  (queries — check_connection, list_databases, db_exists, …)
Backup  : mysqldump subprocess (Docker-aware)
Restore : mysql subprocess (Docker-aware)

MySQL has no schemas separate from databases, so supports_schemas = False.
"""

from __future__ import annotations

import gzip
import os
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

from ..config import Config
from .base import DbAdapter


class MariaDbError(RuntimeError):
    """Raised when a MariaDB operation fails with a diagnosable error."""


class MariaDbAdapter(DbAdapter):
    supports_schemas: bool = False
    supports_roles: bool = False
    supports_toc: bool = False
    dump_extension: str = ".sql"

    def __init__(self, cfg: Config) -> None:
        self._cfg = cfg

    # ── internal helpers ───────────────────────────────────────────

    def _connect(self, dbname: str = ""):
        """Return a pymysql connection. Imports lazily so the package works
        without pymysql installed when using other adapters."""
        try:
            import pymysql
        except ImportError as exc:
            raise MariaDbError(
                "pymysql is required for MariaDB support. "
                "Install it: pip install pymysql"
            ) from exc

        cfg = self._cfg
        kwargs: dict = dict(
            host=cfg.host,
            port=cfg.port,
            user=cfg.user,
            password=cfg.password,
            connect_timeout=cfg.connection_timeout,
            charset="utf8mb4",
        )
        if dbname:
            kwargs["database"] = dbname

        try:
            return pymysql.connect(**kwargs)
        except pymysql.err.OperationalError as exc:
            raise MariaDbError(_classify_mysql_error(exc, cfg)) from exc

    def _query_col(self, sql: str, dbname: str = "") -> list[str]:
        conn = self._connect(dbname)
        try:
            with conn.cursor() as cur:
                cur.execute(sql)
                return [str(row[0]) for row in cur.fetchall()]
        finally:
            conn.close()

    def _query_one(self, sql: str, params: tuple = (), dbname: str = "") -> str:
        conn = self._connect(dbname)
        try:
            with conn.cursor() as cur:
                cur.execute(sql, params)
                row = cur.fetchone()
                return str(row[0]) if row else ""
        finally:
            conn.close()

    def _execute(self, sql: str, dbname: str = "") -> None:
        conn = self._connect(dbname)
        conn.autocommit(True)
        try:
            with conn.cursor() as cur:
                cur.execute(sql)
        finally:
            conn.close()

    def _docker_prefix(self) -> list[str]:
        """docker exec prefix that injects MYSQL_PWD to avoid password on CLI."""
        return [
            "docker", "exec", "-i",
            "-e", f"MYSQL_PWD={self._cfg.password}",
            self._cfg.service,
        ]

    def _host_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env["MYSQL_PWD"] = self._cfg.password
        return env

    # ── mandatory ──────────────────────────────────────────────────

    def check_connection(self) -> None:
        cfg = self._cfg

        if cfg.use_docker:
            if not shutil.which("docker"):
                raise MariaDbError(
                    "docker binary not found in PATH. Install Docker or set USE_DOCKER=false."
                )
            state = subprocess.run(
                ["docker", "inspect", "--format", "{{.State.Status}}", cfg.service],
                capture_output=True,
                timeout=cfg.connection_timeout,
            )
            status = state.stdout.decode().strip()
            if status != "running":
                raise MariaDbError(
                    f"Container '{cfg.service}' is not running (state: {status or 'missing'}). "
                    "Start it or check SERVICE= in your config."
                )
            for binary in (cfg.mysql_dump_cmd, cfg.mysql_cmd):
                chk = subprocess.run(
                    ["docker", "exec", cfg.service, "which", binary],
                    capture_output=True,
                    timeout=cfg.connection_timeout,
                )
                if chk.returncode != 0:
                    raise MariaDbError(
                        f"'{binary}' not found inside container '{cfg.service}'. "
                        "Is this a MariaDB/MySQL container?"
                    )
        else:
            for binary in (cfg.mysql_dump_cmd, cfg.mysql_cmd):
                if not shutil.which(binary):
                    raise MariaDbError(
                        f"'{binary}' not found in PATH. Install mariadb-client or mysql-client."
                    )

        # Live connection test
        conn = self._connect()
        conn.close()

    def list_databases(self) -> list[str]:
        system = {"information_schema", "performance_schema", "mysql", "sys"}
        return sorted(
            db for db in self._query_col("SHOW DATABASES")
            if db not in system
        )

    def backup_db(
        self,
        dbname: str,
        out_file: Path,
        *,
        include_schemas: list[str],
        exclude_schemas: list[str],
    ) -> None:
        """Run mysqldump and write SQL to *out_file*.

        include_schemas / exclude_schemas are table-level for MySQL.
        (MySQL has no schemas; schemas map to tables for basic filtering.)
        """
        cfg = self._cfg
        base_args = [
            cfg.mysql_dump_cmd,
            "-u", cfg.user,
            "-h", cfg.host,
            "-P", str(cfg.port),
            "--single-transaction",
            "--routines",
            "--triggers",
            "--events",
            dbname,
        ]

        if cfg.use_docker:
            cmd = self._docker_prefix() + base_args
            env = None
        else:
            cmd = base_args
            env = self._host_env()

        with out_file.open("wb") as f_out:
            subprocess.run(cmd, stdout=f_out, env=env, check=True)

    def restore_db(
        self,
        dbname: str,
        dump_file: Path,
        *,
        schemas: list[str],
        no_owner: bool,
    ) -> None:
        """Restore a .sql / .sql.gz / .zip dump into *dbname*."""
        cfg = self._cfg
        suffix = dump_file.suffix.lower()

        # Decompress if needed
        tmp_sql: Path | None = None
        work_file = dump_file

        try:
            if suffix == ".gz":
                tmp_sql = Path(tempfile.mktemp(suffix=".sql"))
                with gzip.open(dump_file, "rb") as gz_in, tmp_sql.open("wb") as f_out:
                    shutil.copyfileobj(gz_in, f_out)
                work_file = tmp_sql
            elif suffix == ".zip":
                with zipfile.ZipFile(dump_file, "r") as zf:
                    sql_names = [n for n in zf.namelist() if n.endswith(".sql")]
                    if not sql_names:
                        raise MariaDbError(f"No .sql file found inside {dump_file.name}")
                    tmp_sql = Path(tempfile.mktemp(suffix=".sql"))
                    with zf.open(sql_names[0]) as src, tmp_sql.open("wb") as dst:
                        shutil.copyfileobj(src, dst)
                work_file = tmp_sql

            base_args = [
                cfg.mysql_cmd,
                "-u", cfg.user,
                "-h", cfg.host,
                "-P", str(cfg.port),
                dbname,
            ]

            if cfg.use_docker:
                cmd = self._docker_prefix() + base_args
                env = None
            else:
                cmd = base_args
                env = self._host_env()

            with work_file.open("rb") as f_in:
                subprocess.run(cmd, stdin=f_in, env=env, check=True)

        finally:
            if tmp_sql and tmp_sql.exists():
                tmp_sql.unlink()

    # ── optional ───────────────────────────────────────────────────

    def get_db_size(self, dbname: str) -> str:
        try:
            sql = (
                "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) "
                "FROM information_schema.tables "
                "WHERE table_schema = %s"
            )
            val = self._query_one(sql, (dbname,))
            return f"{val} MB" if val and val != "None" else "?"
        except MariaDbError:
            return "?"

    def db_exists(self, dbname: str) -> bool:
        return dbname in self.list_databases()

    def drop_db(self, dbname: str) -> None:
        self._execute(f"DROP DATABASE IF EXISTS `{dbname}`")

    def create_db(self, dbname: str, owner: str | None = None) -> None:
        self._execute(
            f"CREATE DATABASE IF NOT EXISTS `{dbname}` "
            "CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
        )

    def terminate_connections(self, dbname: str) -> int:
        try:
            threads = self._query_col(
                f"SELECT ID FROM information_schema.PROCESSLIST WHERE DB = '{dbname}'"
            )
            conn = self._connect()
            try:
                killed = 0
                with conn.cursor() as cur:
                    for tid in threads:
                        try:
                            cur.execute(f"KILL {tid}")
                            killed += 1
                        except Exception:
                            pass
                return killed
            finally:
                conn.close()
        except MariaDbError:
            return 0


# ──────────────────────────────────────────────────────────────────────────────
#  Error classifier
# ──────────────────────────────────────────────────────────────────────────────

def _classify_mysql_error(exc: Exception, cfg: Config) -> str:
    msg = str(exc).lower()
    if "access denied" in msg:
        return f"Access denied for user '{cfg.user}'. Check DB_USERNAME / DB_PASSWORD."
    if "connection refused" in msg or "can't connect" in msg:
        return f"Connection refused at {cfg.host}:{cfg.port}. Is MariaDB/MySQL running?"
    if "unknown host" in msg or "name or service not known" in msg:
        return f"Hostname '{cfg.host}' not resolvable. Check DB_HOST."
    return str(exc)
