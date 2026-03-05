"""Typer CLI entry point: `fuelrod-backup backup` and `fuelrod-backup restore`."""

from __future__ import annotations

from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console

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
    ] = None,
    keep_days: Annotated[
        int | None,
        typer.Option("--keep-days", "-k", help="Delete backups older than N days (0 = keep forever)."),
    ] = None,
    databases: Annotated[
        list[str],
        typer.Option("--db", "-d", help="Database(s) to back up (repeatable). Default: all."),
    ] = [],
    schemas: Annotated[
        str | None,
        typer.Option("--schemas", "-s", help="Comma-separated schemas to include (applied to every DB)."),
    ] = None,
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
        schemas=schemas,
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
    console.print(f"  Mode          : {'[cyan]Docker[/] — service ' + repr(cfg.service) if cfg.use_docker else 'Direct'}{docker_override}")
    console.print(f"  Host          : {cfg.host}:{cfg.port}")
    console.print(f"  User          : {cfg.user}")
    console.print(f"  Password      : {pass_hint}")
    console.print(f"  Base dir      : {cfg.base_dir}")
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


if __name__ == "__main__":
    app()
