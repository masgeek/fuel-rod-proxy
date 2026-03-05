"""Abstract base class for all database adapters."""

from __future__ import annotations

from abc import ABC, abstractmethod
from pathlib import Path


class DbAdapter(ABC):
    """
    Common interface for backup/restore across database engines.

    Capability flags (adapters override as needed):
      supports_schemas  – engine has named schemas inside a database (PG, MSSQL)
      supports_roles    – engine has role/ownership semantics readable from dump (PG)
      supports_toc      – engine can read a table-of-contents from the dump (PG)
      dump_extension    – default file extension for dump files
    """

    supports_schemas: bool = False
    supports_roles: bool = False
    supports_toc: bool = False
    dump_extension: str = ".dump"

    # ──────────────────────────────────────────────────────────────
    #  Mandatory — every adapter must implement these
    # ──────────────────────────────────────────────────────────────

    @abstractmethod
    def check_connection(self) -> None:
        """Verify connectivity; raise a descriptive error on failure."""

    @abstractmethod
    def list_databases(self) -> list[str]:
        """Return sorted list of non-system database names."""

    @abstractmethod
    def backup_db(
        self,
        dbname: str,
        out_file: Path,
        *,
        include_schemas: list[str],
        exclude_schemas: list[str],
    ) -> None:
        """Dump *dbname* to *out_file*."""

    @abstractmethod
    def restore_db(
        self,
        dbname: str,
        dump_file: Path,
        *,
        schemas: list[str],
        no_owner: bool,
    ) -> None:
        """Restore *dump_file* into *dbname*."""

    # ──────────────────────────────────────────────────────────────
    #  Optional — sensible defaults; adapters override what they need
    # ──────────────────────────────────────────────────────────────

    def get_db_size(self, dbname: str) -> str:
        return "?"

    def get_user_schemas(self, dbname: str) -> list[str]:
        return []

    def db_exists(self, dbname: str) -> bool:
        return False

    def drop_db(self, dbname: str) -> None:
        raise NotImplementedError(f"{type(self).__name__} does not support drop_db")

    def create_db(self, dbname: str, owner: str | None = None) -> None:
        raise NotImplementedError(f"{type(self).__name__} does not support create_db")

    def terminate_connections(self, dbname: str) -> int:
        return 0
