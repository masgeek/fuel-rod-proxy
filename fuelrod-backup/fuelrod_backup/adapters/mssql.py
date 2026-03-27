"""Microsoft SQL Server adapter.

Driver  : pymssql (queries — check_connection, list_databases, …)
Backup  : T-SQL BACKUP DATABASE … TO DISK (via pymssql — no subprocess)
Restore : T-SQL RESTORE DATABASE … FROM DISK (via pymssql — no subprocess)

Docker mode: backup writes to a path *inside* the container.
After dumping, the .bak file is copied out with `docker cp`.
For restore, the .bak is first copied into the container, then RESTORE is run.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from ..config import Config
from .base import DbAdapter


class MssqlError(RuntimeError):
    """Raised when an MSSQL operation fails with a diagnosable error."""


class MssqlAdapter(DbAdapter):
    supports_schemas: bool = True
    supports_roles: bool = False
    supports_toc: bool = False
    dump_extension: str = ".bak"

    def __init__(self, cfg: Config) -> None:
        self._cfg = cfg

    # ── internal helpers ───────────────────────────────────────────

    def _connect(self, dbname: str = "master"):
        """Return a pymssql connection. Imports lazily."""
        try:
            import pymssql
        except ImportError as exc:
            raise MssqlError(
                "pymssql is required for MSSQL support. "
                "Install it: pip install pymssql"
            ) from exc

        cfg = self._cfg
        try:
            return pymssql.connect(
                server=cfg.host,
                port=str(cfg.port),
                user=cfg.user,
                password=cfg.password,
                database=dbname,
                login_timeout=cfg.connection_timeout,
                as_dict=False,
            )
        except Exception as exc:
            raise MssqlError(_classify_mssql_error(exc, cfg)) from exc

    def _execute(self, sql: str, dbname: str = "master") -> None:
        conn = self._connect(dbname)
        conn.autocommit(True)
        try:
            with conn.cursor() as cur:
                cur.execute(sql)
        finally:
            conn.close()

    def _query_col(self, sql: str, dbname: str = "master") -> list[str]:
        conn = self._connect(dbname)
        try:
            with conn.cursor() as cur:
                cur.execute(sql)
                return [str(row[0]) for row in cur.fetchall()]
        finally:
            conn.close()

    def _query_one(self, sql: str, dbname: str = "master") -> str:
        conn = self._connect(dbname)
        try:
            with conn.cursor() as cur:
                cur.execute(sql)
                row = cur.fetchone()
                return str(row[0]) if row else ""
        finally:
            conn.close()

    # ── mandatory ──────────────────────────────────────────────────

    def check_connection(self) -> None:
        cfg = self._cfg

        if cfg.use_docker:
            import shutil
            if not shutil.which("docker"):
                raise MssqlError(
                    "docker binary not found in PATH. Install Docker or set USE_DOCKER=false."
                )
            state = subprocess.run(
                ["docker", "inspect", "--format", "{{.State.Status}}", cfg.service],
                capture_output=True,
                timeout=cfg.connection_timeout,
            )
            status = state.stdout.decode().strip()
            if status != "running":
                raise MssqlError(
                    f"Container '{cfg.service}' is not running (state: {status or 'missing'}). "
                    "Start it or check SERVICE= in your config."
                )

        # Live connection test
        conn = self._connect("master")
        conn.close()

    def list_databases(self) -> list[str]:
        system = {"master", "tempdb", "model", "msdb"}
        return sorted(
            db for db in self._query_col(
                "SELECT name FROM sys.databases WHERE state_desc = 'ONLINE' ORDER BY name"
            )
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
        """
        Run T-SQL BACKUP DATABASE writing to the container/host backup directory,
        then copy the .bak to *out_file* on the host.
        """
        cfg = self._cfg
        bak_name = out_file.stem + ".bak"

        if cfg.use_docker:
            ctr_path = f"{cfg.mssql_backup_dir}/{bak_name}"
            sql = (
                f"BACKUP DATABASE [{dbname}] "
                f"TO DISK = N'{ctr_path}' "
                "WITH FORMAT, INIT, COMPRESSION, STATS = 10"
            )
            self._execute(sql, "master")

            # Ensure the host directory exists
            out_file.parent.mkdir(parents=True, exist_ok=True)

            subprocess.run(
                ["docker", "cp", f"{cfg.service}:{ctr_path}", str(out_file)],
                check=True,
            )
            # Clean up inside container
            subprocess.run(
                ["docker", "exec", cfg.service, "rm", "-f", ctr_path],
                check=False,
            )
        else:
            sql = (
                f"BACKUP DATABASE [{dbname}] "
                f"TO DISK = N'{out_file}' "
                "WITH FORMAT, INIT, COMPRESSION, STATS = 10"
            )
            self._execute(sql, "master")

    def restore_db(
        self,
        dbname: str,
        dump_file: Path,
        *,
        schemas: list[str],
        no_owner: bool,
    ) -> None:
        """
        Copy the .bak into the container (Docker mode), then run RESTORE DATABASE.
        """
        cfg = self._cfg

        if cfg.use_docker:
            ctr_path = f"{cfg.mssql_backup_dir}/{dump_file.name}"
            subprocess.run(
                ["docker", "cp", str(dump_file), f"{cfg.service}:{ctr_path}"],
                check=True,
            )
            bak_path = ctr_path
        else:
            bak_path = str(dump_file)

        sql = (
            f"RESTORE DATABASE [{dbname}] "
            f"FROM DISK = N'{bak_path}' "
            "WITH REPLACE, RECOVERY, STATS = 10"
        )
        try:
            self._execute(sql, "master")
        finally:
            if cfg.use_docker:
                subprocess.run(
                    ["docker", "exec", cfg.service, "rm", "-f", ctr_path],
                    check=False,
                )

    # ── optional ───────────────────────────────────────────────────

    def get_db_size(self, dbname: str) -> str:
        try:
            val = self._query_one(
                f"SELECT CAST(SUM(size * 8.0 / 1024) AS DECIMAL(10,1)) "
                f"FROM sys.master_files WHERE DB_NAME(database_id) = '{dbname}'",
                "master",
            )
            return f"{val} MB" if val else "?"
        except MssqlError:
            return "?"

    def get_user_schemas(self, dbname: str) -> list[str]:
        try:
            system = {"dbo", "guest", "sys", "INFORMATION_SCHEMA"}
            return sorted(
                s for s in self._query_col(
                    "SELECT name FROM sys.schemas ORDER BY name",
                    dbname,
                )
                if s not in system
            )
        except MssqlError:
            return []

    def db_exists(self, dbname: str) -> bool:
        val = self._query_one(
            f"SELECT COUNT(*) FROM sys.databases WHERE name = '{dbname}'"
        )
        return val == "1"

    def drop_db(self, dbname: str) -> None:
        self.terminate_connections(dbname)
        self._execute(f"DROP DATABASE [{dbname}]", "master")

    def create_db(self, dbname: str, owner: str | None = None) -> None:
        self._execute(f"CREATE DATABASE [{dbname}]", "master")

    def terminate_connections(self, dbname: str) -> int:
        sql = (
            f"DECLARE @sql NVARCHAR(MAX) = ''; "
            f"SELECT @sql = @sql + 'KILL ' + CAST(spid AS NVARCHAR) + '; ' "
            f"FROM sys.sysprocesses WHERE dbid = DB_ID('{dbname}') AND spid <> @@SPID; "
            f"EXEC sp_executesql @sql;"
        )
        try:
            self._execute(sql, "master")
        except MssqlError:
            pass
        return 0


# ──────────────────────────────────────────────────────────────────────────────
#  Error classifier
# ──────────────────────────────────────────────────────────────────────────────

def _classify_mssql_error(exc: Exception, cfg: Config) -> str:
    msg = str(exc).lower()
    if "login failed" in msg:
        return f"Login failed for user '{cfg.user}'. Check MSSQL_USERNAME / MSSQL_PASSWORD."
    if "connection refused" in msg or "could not connect" in msg:
        return f"Connection refused at {cfg.host}:{cfg.port}. Is SQL Server running?"
    if "cannot open" in msg and "database" in msg:
        return f"Cannot open database. Check MSSQL_HOST and that SQL Server is accessible."
    return str(exc)
