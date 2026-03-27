"""Typer CLI entry point: `fuelrod-backup backup` and `fuelrod-backup restore`."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console
from rich.panel import Panel

from .config import DbType, load_config

app = typer.Typer(
    name="fuelrod-backup",
    help="Interactive database backup and restore tool (PostgreSQL, MariaDB, MSSQL).",
    add_completion=False,
)
console = Console()

# Reusable option definitions
_CONFIG_OPT = typer.Option("--config", "-c", help="Path to .backup or .env config file.", exists=True, dir_okay=False)
_DOCKER_OPT = typer.Option("--docker/--no-docker", help="Override USE_DOCKER from config (highest priority).")
_DB_TYPE_OPT = typer.Option("--db-type", "-t", help="Database engine: postgres | mariadb | mssql.")


def _apply_docker_override(cfg, use_docker: bool | None) -> None:
    """Apply --docker/--no-docker CLI flag if explicitly provided."""
    if use_docker is not None:
        cfg.use_docker = use_docker


def _apply_db_type_override(cfg, db_type: str | None) -> None:
    """Apply --db-type CLI flag if explicitly provided."""
    if db_type is not None:
        try:
            cfg.db_type = DbType(db_type.lower())
        except ValueError:
            console.print(f"[bold red]ERROR:[/] Unknown --db-type '{db_type}'. Choose: postgres, mariadb, mssql")
            raise typer.Exit(code=1)


@app.command()
def backup(
        no_interactive: Annotated[
            bool,
            typer.Option("--no-interactive", "-n", help="Skip all wizard prompts; back up all databases."),
        ] = False,
        compress: Annotated[
            bool | None,
            typer.Option("--compress/--no-compress", help="Compress output with gzip."),
        ] = True,
        keep_days: Annotated[
            int | None,
            typer.Option("--keep-days", "-k", help="Delete backups older than N days (0 = keep forever)."),
        ] = None,
        databases: Annotated[
            list[str],
            typer.Option("--db", "-d", help="Database(s) to back up (repeatable). Default: all."),
        ] = [],
        use_docker: Annotated[bool | None, _DOCKER_OPT] = None,
        db_type: Annotated[str | None, _DB_TYPE_OPT] = None,
        config_file: Annotated[Path | None, _CONFIG_OPT] = None,
) -> None:
    """Back up one or more databases (postgres | mariadb | mssql)."""
    from .backup import run_backup

    cfg = load_config(config_file)
    _apply_docker_override(cfg, use_docker)
    _apply_db_type_override(cfg, db_type)
    run_backup(
        cfg,
        interactive=not no_interactive,
        databases=list(databases) or None,
        compress=compress,
        keep_days=keep_days,
    )


@app.command()
def restore(
        use_docker: Annotated[bool | None, _DOCKER_OPT] = None,
        db_type: Annotated[str | None, _DB_TYPE_OPT] = None,
        config_file: Annotated[Path | None, _CONFIG_OPT] = None,
) -> None:
    """Interactively restore a database from a dump file (postgres | mariadb | mssql)."""
    from .restore import run_restore

    cfg = load_config(config_file)
    _apply_docker_override(cfg, use_docker)
    _apply_db_type_override(cfg, db_type)
    run_restore(cfg)


@app.command("test")
def test_connection(
        use_docker: Annotated[bool | None, _DOCKER_OPT] = None,
        db_type: Annotated[str | None, _DB_TYPE_OPT] = None,
        config_file: Annotated[Path | None, _CONFIG_OPT] = None,
) -> None:
    """Test the database connection and print resolved settings."""
    from .adapters import get_adapter

    cfg = load_config(config_file)
    _apply_docker_override(cfg, use_docker)
    _apply_db_type_override(cfg, db_type)

    pass_hint = f"{'*' * min(len(cfg.password), 6)}  ({len(cfg.password)} chars)" if cfg.password else "[red]NOT SET[/]"
    source = str(cfg.config_source) if cfg.config_source else "[red]none found — using defaults only[/]"
    docker_override = " [yellow](CLI override)[/]" if use_docker is not None else ""

    console.print()
    console.print("[bold]Resolved settings:[/]")
    console.print(f"  Config source : {source}")
    console.print(f"  DB type       : [cyan]{cfg.db_type.value}[/]")
    console.print(
        f"  Mode          : {'[cyan]Docker[/] — service ' + repr(cfg.service) if cfg.use_docker else 'Direct'}{docker_override}")
    console.print(f"  Host          : {cfg.host}:{cfg.port}")
    console.print(f"  User          : {cfg.user}")
    console.print(f"  Password      : {pass_hint}")
    console.print(f"  Backup dir    : {cfg.backup_dir}")
    console.print(f"  Compress      : {cfg.compress}")
    console.print(f"  Retain        : {cfg.days_to_keep} days")
    console.print()

    adapter = get_adapter(cfg)
    try:
        adapter.check_connection()
        console.print("[bold green]✓ Connection successful.[/]")
    except Exception as exc:
        console.print(f"[bold red]✗ Connection failed:[/] {exc}")
        raise typer.Exit(code=1)


@app.command("init")
def init_config(
        output: Annotated[
            Path,
            typer.Option("--output", "-o", help="Where to write the config file.", dir_okay=False),
        ] = Path(".backup"),
) -> None:
    """Interactively create a .backup config file."""
    from . import prompt as q

    console.print()
    console.print(Panel("[bold cyan]fuelrod-backup — init wizard[/]\nCreates a .backup config file by walking through all settings.", expand=False))
    console.print()

    # ── Output path ────────────────────────────────────────────────
    if output.exists():
        overwrite = q.confirm(f"  '{output}' already exists. Overwrite?", default=False).ask()
        if not overwrite:
            console.print("[yellow]Aborted.[/]")
            raise typer.Exit(0)

    # ── Engine ─────────────────────────────────────────────────────
    console.rule("[bold cyan]Database engine[/]")
    db_type: str = q.select(
        "Database engine",
        choices=[
            q.Choice("PostgreSQL", value="postgres"),
            q.Choice("MariaDB / MySQL", value="mariadb"),
            q.Choice("Microsoft SQL Server", value="mssql"),
        ],
    ).ask()

    # Per-engine defaults
    if db_type == "mariadb":
        _def_user, _def_port, _def_service = "root", "3306", "mariadb"
        _def_dump_cmd, _def_client_cmd = "mariadb-dump", "mysql"
    elif db_type == "mssql":
        _def_user, _def_port, _def_service = "sa", "1433", "mssql"
    else:
        _def_user, _def_port, _def_service = "postgres", "5432", "postgres"

    # ── Docker mode ────────────────────────────────────────────────
    console.print()
    console.rule("[bold cyan]Connection mode[/]")
    use_docker: bool = q.select(
        "How does the tool connect to the database?",
        choices=[
            q.Choice("Docker  (exec into a running container)", value=True),
            q.Choice("Direct  (host:port, no Docker)", value=False),
        ],
    ).ask()

    if use_docker:
        service = q.text("Container name (SERVICE)", default=_def_service).ask() or _def_service
        host = "127.0.0.1"
        port = _def_port
    else:
        service = _def_service
        host = q.text("Host (PG_HOST)", default="127.0.0.1").ask() or "127.0.0.1"
        port = q.text("Port (PG_PORT)", default=_def_port).ask() or _def_port

    # ── Credentials ────────────────────────────────────────────────
    console.print()
    console.rule("[bold cyan]Credentials[/]")
    username = q.text("Username (PG_USERNAME)", default=_def_user).ask() or _def_user
    password = q.password("Password (PG_PASSWORD)").ask() or ""

    # ── Backup storage ─────────────────────────────────────────────
    console.print()
    console.rule("[bold cyan]Backup storage[/]")
    default_base = str(output.resolve().parent / "db-backup")
    base_dir = q.text(
        "Backup root directory (BASE_DIR)\n  /<db_type> is appended automatically",
        default=default_base,
    ).ask() or default_base

    compress: bool = q.confirm("Compress backups with gzip? (COMPRESS_FILE)", default=True).ask()

    keep_days_str = q.text("Retain backups for N days — 0 = keep forever (KEEP_DAYS)", default="7").ask() or "7"
    try:
        keep_days = max(0, int(keep_days_str))
    except ValueError:
        keep_days = 7

    # ── Timeouts / advanced ────────────────────────────────────────
    console.print()
    console.rule("[bold cyan]Advanced[/]")
    timeout_str = q.text("Connection timeout in seconds (CONNECTION_TIMEOUT)", default="30").ask() or "30"
    try:
        conn_timeout = max(1, int(timeout_str))
    except ValueError:
        conn_timeout = 30

    # Engine-specific binary / path overrides
    if db_type == "postgres":
        pg_dump_cmd = q.text("pg_dump command (PG_DUMP_CMD)", default="pg_dump").ask() or "pg_dump"
        pg_restore_cmd = q.text("pg_restore command (PG_RESTORE_CMD)", default="pg_restore").ask() or "pg_restore"
    elif db_type == "mariadb":
        mysql_dump_cmd = q.text("Dump command (MYSQL_DUMP_CMD)", default=_def_dump_cmd).ask() or _def_dump_cmd
        mysql_cmd = q.text("Client command (MYSQL_CMD)", default=_def_client_cmd).ask() or _def_client_cmd
    else:  # mssql
        mssql_backup_dir = q.text(
            "Backup directory inside container (MSSQL_BACKUP_DIR)",
            default="/var/opt/mssql/backups",
        ).ask() or "/var/opt/mssql/backups"

    # ── Summary ────────────────────────────────────────────────────
    console.print()
    console.print(Panel("[bold]Config summary[/]", expand=False))
    console.print(f"  Output file   : [bold]{output}[/]")
    console.print(f"  Engine        : [cyan]{db_type}[/]")
    console.print(f"  Mode          : {'Docker — ' + service if use_docker else f'Direct — {host}:{port}'}")
    console.print(f"  User          : {username}")
    console.print(f"  Password      : {'(set)' if password else '[red]NOT SET[/]'}")
    console.print(f"  Backup dir    : {base_dir}/<db_type>/")
    console.print(f"  Compress      : {compress}")
    console.print(f"  Retain        : {keep_days} days")
    console.print(f"  Timeout       : {conn_timeout}s")
    console.print()

    if not q.confirm("Write config file?", default=True).ask():
        console.print("[yellow]Aborted.[/]")
        raise typer.Exit(0)

    # ── Write file ─────────────────────────────────────────────────
    lines: list[str] = [
        "# fuelrod-backup configuration",
        "# Generated by: fuelrod-backup init",
        "#",
        "# Place this file in the directory you run fuelrod-backup from,",
        "# or pass it explicitly with --config /path/to/.backup",
        "",
        f"DB_TYPE={db_type}",
        "",
        "# ── Connection ──────────────────────────────────────────────────",
        f"PG_USERNAME={username}",
        f"PG_PASSWORD={password}",
        f"PG_HOST={host}",
        f"PG_PORT={port}",
        "",
        "# ── Docker ──────────────────────────────────────────────────────",
        f"USE_DOCKER={'true' if use_docker else 'false'}",
        f"SERVICE={service}",
        "",
        "# ── Backup storage ──────────────────────────────────────────────",
        f"BASE_DIR={base_dir}",
        f"COMPRESS_FILE={'true' if compress else 'false'}",
        f"KEEP_DAYS={keep_days}",
        "",
        "# ── Timeouts ────────────────────────────────────────────────────",
        f"CONNECTION_TIMEOUT={conn_timeout}",
        "",
    ]

    if db_type == "postgres":
        lines += [
            "# ── PostgreSQL binaries (on PATH or inside container) ───────────",
            f"PG_DUMP_CMD={pg_dump_cmd}",
            f"PG_RESTORE_CMD={pg_restore_cmd}",
            "",
        ]
    elif db_type == "mariadb":
        lines += [
            "# ── MariaDB / MySQL binaries ────────────────────────────────────",
            f"MYSQL_DUMP_CMD={mysql_dump_cmd}",
            f"MYSQL_CMD={mysql_cmd}",
            "",
        ]
    else:
        lines += [
            "# ── MSSQL ───────────────────────────────────────────────────────",
            f"MSSQL_BACKUP_DIR={mssql_backup_dir}",
            "",
        ]

    output.write_text("\n".join(lines), encoding="utf-8")
    console.print(f"[bold green]✓[/] Config written to [bold]{output.resolve()}[/]")
    console.print()
    console.print("  Run [bold]fuelrod-backup test --config {output}[/] to verify the connection.")
    console.print()


if __name__ == "__main__":
    app()
