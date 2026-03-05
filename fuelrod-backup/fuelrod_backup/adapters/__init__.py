"""Adapter factory — returns the right DbAdapter for the configured db_type."""

from __future__ import annotations

from ..config import Config, DbType
from .base import DbAdapter


def get_adapter(cfg: Config) -> DbAdapter:
    """Instantiate and return the appropriate DbAdapter for *cfg.db_type*."""
    if cfg.db_type == DbType.POSTGRES:
        from .postgres import PostgresAdapter
        return PostgresAdapter(cfg)
    if cfg.db_type == DbType.MARIADB:
        from .mariadb import MariaDbAdapter
        return MariaDbAdapter(cfg)
    if cfg.db_type == DbType.MSSQL:
        from .mssql import MssqlAdapter
        return MssqlAdapter(cfg)
    raise ValueError(f"Unknown db_type: {cfg.db_type!r}")


__all__ = ["DbAdapter", "get_adapter"]
