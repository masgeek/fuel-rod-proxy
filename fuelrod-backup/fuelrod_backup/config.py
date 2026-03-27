"""Configuration dataclass and config file parser (.backup / .env)."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

from rich.console import Console as _Console

_console = _Console(stderr=True)


class DbType(str, Enum):
    POSTGRES = "postgres"
    MARIADB = "mariadb"
    MSSQL = "mssql"


@dataclass
class Config:
    user: str = "postgres"
    password: str = ""
    host: str = "127.0.0.1"
    port: int = 5432
    service: str = "postgres"  # Docker container name
    use_docker: bool = True
    base_dir: str = ""  # backup root directory (raw root)
    compress: bool = False
    days_to_keep: int = 7
    connection_timeout: int = 30  # seconds; applies to driver connect + docker subprocess checks
    psql_cmd: str = "psql"
    pg_dump_cmd: str = "pg_dump"
    pg_restore_cmd: str = "pg_restore"
    # Engine selector
    db_type: DbType = DbType.POSTGRES
    # MariaDB / MySQL specific
    mysql_dump_cmd: str = "mariadb-dump"
    mysql_cmd: str = "mysql"
    # MSSQL specific
    mssql_backup_dir: str = "/var/opt/mssql/backups"  # path inside container
    config_source: Path | None = field(default=None, repr=False)  # which file was loaded

    @property
    def backup_dir(self) -> Path:
        """
        Return the effective backup directory with db_type suffix appended.
        Example: /backups/postgres, /backups/mariadb, /backups/mssql
        """
        return Path(self.base_dir) / self.db_type.value


def _parse_env_file(path: Path) -> dict[str, str]:
    """
    Parse a shell-style key=value file (.backup or .env).

    Rules (matches docker-compose / python-dotenv behaviour):
    - Blank lines and lines starting with # are ignored
    - Leading `export ` is stripped
    - Quoted values  ("..." or '...'):  inner content is used verbatim, no comment stripping
    - Unquoted values: trailing whitespace stripped, then inline # comments stripped
      (a space or tab before # is required to distinguish '#' in a value from a comment)
    """
    result: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        line = re.sub(r"^export\s+", "", line)
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip()

        if len(val) >= 2 and val[0] in ('"', "'") and val[-1] == val[0]:
            # Quoted value — use content verbatim (no comment stripping inside quotes)
            val = val[1:-1]
        else:
            # Unquoted value — strip trailing inline comment (space/tab + # required)
            val = re.sub(r"[ \t]#.*$", "", val).rstrip()

        result[key] = val
    return result


def _find_config_file() -> Path | None:
    """
    Search for a config file, checking these locations in order:

    1. Current working directory  (.backup then .env)
    2. Package project directory  (.backup then .env)
    3. Repo root / one level up   (.backup then .env)

    Returns the first file found, or None.
    """
    pkg_dir = Path(__file__).parent.parent  # fuelrod-backup/
    repo_root = pkg_dir.parent  # proxy-tool/
    cwd = Path.cwd()

    search_dirs = [cwd, pkg_dir]
    if repo_root != cwd and repo_root != pkg_dir:
        search_dirs.append(repo_root)

    for directory in search_dirs:
        for name in (".backup", ".env-backup"):
            candidate = directory / name
            if candidate.is_file():
                return candidate

    return None


def load_config(config_file: Path | None = None) -> Config:
    """
    Build a Config by merging (lowest → highest priority):
      1. Dataclass defaults
      2. .backup or .env file (auto-discovered, or explicit --config path)
      3. Environment variables (always win)

    The resolved config_source field records which file was actually used.
    """
    cfg = Config()

    if config_file is None:
        config_file = _find_config_file()

    raw: dict[str, str] = {}
    if config_file and config_file.is_file():
        raw = _parse_env_file(config_file)
        cfg.config_source = config_file.resolve()
        _console.print(f"[dim]config:[/] {cfg.config_source}")
    else:
        _console.print("[dim]config:[/] [yellow]no config file found — using defaults[/]")

    def _get(key: str, default: str = "") -> str:
        return os.environ.get(key, raw.get(key, default))

    # Engine selector
    try:
        cfg.db_type = DbType(_get("DB_TYPE", "postgres").lower())
    except ValueError:
        cfg.db_type = DbType.POSTGRES

    # Default BASE_DIR: next to the config file if one was found, else cwd/db-backup.
    # Never fall back into site-packages (Path(__file__) is wrong after pip install).
    if config_file:
        _fallback_base = str(config_file.parent / "db-backup")
    else:
        _fallback_base = str(Path.cwd() / "db-backup")

    raw_base = _get("BASE_DIR", _fallback_base)
    cfg.base_dir = str(Path(raw_base))

    # Per-engine defaults for user, port, and service container name
    if cfg.db_type == DbType.MARIADB:
        _default_user, _default_port, _default_service = "root", "3306", "mariadb"
    elif cfg.db_type == DbType.MSSQL:
        _default_user, _default_port, _default_service = "sa", "1433", "mssql"
    else:
        _default_user, _default_port, _default_service = "postgres", "5432", "postgres"

    cfg.user = _get("PG_USERNAME", _default_user)
    cfg.password = _get("PG_PASSWORD", "")
    cfg.host = _get("PG_HOST", "127.0.0.1")
    cfg.service = _get("SERVICE", _default_service)
    cfg.use_docker = _get("USE_DOCKER", "true").strip().lower() in ("true", "1", "yes")
    cfg.compress = _get("COMPRESS_FILE", "false").strip().lower() in ("true", "1", "yes")
    try:
        cfg.connection_timeout = int(_get("CONNECTION_TIMEOUT", "30"))
    except ValueError:
        cfg.connection_timeout = 30

    cfg.psql_cmd = _get("PSQL_CMD", "psql")
    cfg.pg_dump_cmd = _get("PG_DUMP_CMD", "pg_dump")
    cfg.pg_restore_cmd = _get("PG_RESTORE_CMD", "pg_restore")

    # MariaDB / MySQL
    cfg.mysql_dump_cmd = _get("MYSQL_DUMP_CMD", "mysqldump")
    cfg.mysql_cmd = _get("MYSQL_CMD", "mysql")

    # MSSQL
    cfg.mssql_backup_dir = _get("MSSQL_BACKUP_DIR", "/var/opt/mssql/backups")

    try:
        cfg.port = int(_get("PG_PORT", _default_port))
    except ValueError:
        cfg.port = int(_default_port)

    try:
        cfg.days_to_keep = int(_get("KEEP_DAYS", "7"))
    except ValueError:
        cfg.days_to_keep = 7

    return cfg