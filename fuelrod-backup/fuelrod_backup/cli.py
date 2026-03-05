"""Typer CLI entry point: `fuelrod-backup backup` and `fuelrod-backup restore`."""

from __future__ import annotations

from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console

from .config import load_config

app = typer.Typer(
    name="fuelrod-backup",
    help="Interactive PostgreSQL backup and restore tool.",
    add_completion=False,
)
console = Console()

# Reusable option definitions
_CONFIG_OPT = typer.Option("--config", help="Path to .backup or .env config file.", exists=True, dir_okay=False)
_DOCKER_OPT = typer.Option("--docker/--no-docker", help="Override USE_DOCKER from config (highest priority).")


def _apply_docker_override(cfg, use_docker: bool | None) -> None:
    """Apply --docker/--no-docker CLI flag if explicitly provided."""
    if use_docker is not None:
        cfg.use_docker = use_docker


@app.command()
def backup(
    no_interactive: Annotated[
        bool,
        typer.Option("--no-interactive", help="Skip all wizard prompts; back up all databases."),
    ] = False,
    compress: Annotated[
        bool | None,
        typer.Option("--compress/--no-compress", help="Compress output with gzip."),
    ] = None,
    keep_days: Annotated[
        int | None,
        typer.Option("--keep-days", help="Delete backups older than N days (0 = keep forever)."),
    ] = None,
    databases: Annotated[
        list[str],
        typer.Option("--db", help="Database(s) to back up (repeatable). Default: all."),
    ] = [],
    schemas: Annotated[
        str | None,
        typer.Option("--schemas", help="Comma-separated schemas to include (applied to every DB)."),
    ] = None,
    use_docker: Annotated[bool | None, _DOCKER_OPT] = None,
    config_file: Annotated[Path | None, _CONFIG_OPT] = None,
) -> None:
    """Back up one or more PostgreSQL databases."""
    from .backup import run_backup

    cfg = load_config(config_file)
    _apply_docker_override(cfg, use_docker)
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
    config_file: Annotated[Path | None, _CONFIG_OPT] = None,
) -> None:
    """Interactively restore a PostgreSQL database from a dump file."""
    from .restore import run_restore

    cfg = load_config(config_file)
    _apply_docker_override(cfg, use_docker)
    run_restore(cfg)


@app.command("test")
def test_connection(
    use_docker: Annotated[bool | None, _DOCKER_OPT] = None,
    config_file: Annotated[Path | None, _CONFIG_OPT] = None,
) -> None:
    """Test the PostgreSQL connection and print resolved settings."""
    from .runner import PgRunner, PgError

    cfg = load_config(config_file)
    _apply_docker_override(cfg, use_docker)

    pass_hint = f"{'*' * min(len(cfg.password), 6)}  ({len(cfg.password)} chars)" if cfg.password else "[red]NOT SET[/]"
    source = str(cfg.config_source) if cfg.config_source else "[red]none found — using defaults only[/]"
    docker_override = " [yellow](CLI override)[/]" if use_docker is not None else ""

    console.print()
    console.print("[bold]Resolved settings:[/]")
    console.print(f"  Config source : {source}")
    console.print(f"  Mode          : {'[cyan]Docker[/] — service ' + repr(cfg.service) if cfg.use_docker else 'Direct'}{docker_override}")
    console.print(f"  Host          : {cfg.host}:{cfg.port}")
    console.print(f"  User          : {cfg.user}")
    console.print(f"  Password      : {pass_hint}")
    console.print(f"  Base dir      : {cfg.base_dir}")
    console.print(f"  Compress      : {cfg.compress}")
    console.print(f"  Retain        : {cfg.days_to_keep} days")
    console.print()

    runner = PgRunner(cfg)
    try:
        runner.check_connection()
        console.print("[bold green]✓ Connection successful.[/]")
    except PgError as exc:
        console.print(f"[bold red]✗ Connection failed:[/] {exc}")
        raise typer.Exit(code=1)


if __name__ == "__main__":
    app()
