"""PostgreSQL adapter — thin wrapper around PgRunner."""

from __future__ import annotations

from pathlib import Path

from ..config import Config
from ..runner import PgRunner
from .base import DbAdapter


class PostgresAdapter(DbAdapter):
    supports_schemas: bool = True
    supports_roles: bool = True
    supports_toc: bool = True
    dump_extension: str = ".dump"

    def __init__(self, cfg: Config) -> None:
        self._cfg = cfg
        self._runner = PgRunner(cfg)

    # ── mandatory ──────────────────────────────────────────────────

    def check_connection(self) -> None:
        self._runner.check_connection()

    def list_databases(self) -> list[str]:
        return self._runner.list_databases()

    def backup_db(
        self,
        dbname: str,
        out_file: Path,
        *,
        include_schemas: list[str],
        exclude_schemas: list[str],
    ) -> None:
        """Run pg_dump in custom format, streaming output to *out_file*.

        Schema filtering is intentionally NOT applied at dump time.
        Passing -n/-N to pg_dump causes ACL entries to be stored as
        "schema.TABLE tablename", which prevents pg_restore from correctly
        restoring sequences, constraints, indexes, and ACLs.
        Schema selection is handled at restore time via pg_restore -n.
        """
        base_args = [
            "-U", self._cfg.user,
            "-h", self._cfg.host,
            "-p", str(self._cfg.port),
            "-F", "c",
            "-b",
            dbname,
        ]

        with out_file.open("wb") as f_out:
            self._runner.pg_dump(*base_args, stdout=f_out.fileno())

    def restore_db(
        self,
        dbname: str,
        dump_file: Path,
        *,
        schemas: list[str],
        no_owner: bool,
    ) -> None:
        """Restore a custom-format dump.  The caller is responsible for building
        the full restore_args list; this method is not used directly by restore.py
        (restore.py calls _execute_restore for PG because it needs fine-grained
        control over scope / clean / jobs arguments)."""
        import gzip
        import shutil
        import subprocess
        import tempfile

        extra: list[str] = []
        if no_owner:
            extra += ["--no-owner", "--no-privileges"]
        for s in schemas:
            extra += ["-n", s]

        base_args = [
            "-U", self._cfg.user,
            "-h", self._cfg.host,
            "-p", str(self._cfg.port),
            "-d", dbname,
            "-v",
        ] + extra

        cfg = self._cfg
        if dump_file.suffix == ".gz":
            tmp = Path(tempfile.mktemp(suffix=".dump"))
            try:
                with gzip.open(dump_file, "rb") as gz_in, tmp.open("wb") as f_out:
                    shutil.copyfileobj(gz_in, f_out)
                with tmp.open("rb") as f_in:
                    self._runner.pg_restore(*base_args, stdin=f_in.fileno())
            finally:
                if tmp.exists():
                    tmp.unlink()
        else:
            with dump_file.open("rb") as f_in:
                self._runner.pg_restore(*base_args, stdin=f_in.fileno())

    # ── optional ───────────────────────────────────────────────────

    def get_db_size(self, dbname: str) -> str:
        return self._runner.get_db_size(dbname)

    def get_user_schemas(self, dbname: str) -> list[str]:
        return self._runner.get_user_schemas(dbname)

    def db_exists(self, dbname: str) -> bool:
        return self._runner.db_exists(dbname)

    def drop_db(self, dbname: str) -> None:
        self._runner.drop_db(dbname)

    def create_db(self, dbname: str, owner: str | None = None) -> None:
        self._runner.create_db(dbname, owner)

    def terminate_connections(self, dbname: str) -> int:
        return self._runner.terminate_connections(dbname)

    # ── PG-specific extras exposed for restore.py ──────────────────

    def read_toc(self, dump_file: Path) -> str:
        return self._runner.read_toc(dump_file)

    def role_exists(self, role: str) -> bool:
        return self._runner.role_exists(role)

    def create_role(
        self,
        role: str,
        *,
        superuser: bool = False,
        can_login: bool = True,
        password: str | None = None,
    ) -> None:
        self._runner.create_role(role, superuser=superuser, can_login=can_login, password=password)

    def ensure_schemas(self, dbname: str, schemas: list[str]) -> None:
        self._runner.ensure_schemas(dbname, schemas)

    def get_table_count(self, dbname: str, schema: str | None = None) -> str:
        return self._runner.get_table_count(dbname, schema)
