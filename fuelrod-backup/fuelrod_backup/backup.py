"""Backup wizard and execution logic."""

from __future__ import annotations

import gzip
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import questionary
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from .config import Config
from .runner import PgError, PgRunner

console = Console()


# ──────────────────────────────────────────────────────────────────────────────
#  Helpers
# ──────────────────────────────────────────────────────────────────────────────

def _section(title: str) -> None:
    console.print()
    console.rule(f"[bold cyan]{title}[/]")
    console.print()


def _die(msg: str) -> None:
    console.print(f"[bold red]ERROR:[/] {msg}")
    sys.exit(1)


# ──────────────────────────────────────────────────────────────────────────────
#  Interactive wizard
# ──────────────────────────────────────────────────────────────────────────────

def _wizard_connection(cfg: Config, runner: PgRunner) -> None:
    """Optionally override connection settings, then test."""
    _section("Connection")

    if cfg.use_docker:
        console.print(f"  Mode  : [cyan]Docker[/] — service '[bold]{cfg.service}[/]'")
    else:
        console.print(f"  Mode  : Direct — {cfg.host}:{cfg.port}")
    console.print(f"  User  : {cfg.user}")
    console.print()

    if questionary.confirm("Override connection settings?", default=False).ask():
        if not cfg.use_docker:
            cfg.host = questionary.text("Host", default=cfg.host).ask() or cfg.host
            cfg.port = int(questionary.text("Port", default=str(cfg.port)).ask() or cfg.port)
        cfg.user = questionary.text("Username", default=cfg.user).ask() or cfg.user
        new_pass = questionary.password("Password (blank to keep current)").ask() or ""
        if new_pass:
            cfg.password = new_pass

    if not cfg.password:
        _die("Password is required. Set PG_PASSWORD in .backup or enter it above.")

    console.print()
    with console.status("Testing connection..."):
        runner.check_connection()
    console.print("[green]Connection OK.[/]")


def _wizard_databases(cfg: Config, runner: PgRunner) -> list[str]:
    """Let user pick which databases to back up."""
    _section("Select Databases")

    all_dbs = runner.list_databases()
    if not all_dbs:
        _die("No databases found on server.")

    table = Table(show_header=True, header_style="bold")
    table.add_column("#", style="dim", width=4)
    table.add_column("Database", min_width=24)
    table.add_column("Size", justify="right")
    for i, db in enumerate(all_dbs):
        size = runner.get_db_size(db)
        table.add_row(str(i), db, size)
    console.print(table)

    choices = [questionary.Choice(title=db, value=db) for db in all_dbs]
    selected = questionary.checkbox(
        "Select databases to back up (Space to toggle, Enter to confirm, none = all)",
        choices=choices,
    ).ask()

    if not selected:
        console.print("  No selection — backing up [bold]all[/] databases.")
        return all_dbs
    return selected


def _wizard_schemas(db: str, runner: PgRunner) -> tuple[list[str], list[str]]:
    """Return (include_schemas, exclude_schemas) for a database."""
    schemas = runner.get_user_schemas(db)
    if not schemas:
        return [], []

    _section(f"Schema Selection — {db}")

    action = questionary.select(
        f"Schema filter for '{db}'",
        choices=[
            questionary.Choice("All schemas (default)", value="all"),
            questionary.Choice("Include specific schemas only", value="include"),
            questionary.Choice("Exclude specific schemas", value="exclude"),
        ],
    ).ask()

    if action == "all":
        return [], []

    choices = [questionary.Choice(title=s, value=s) for s in schemas]
    if action == "include":
        selected = questionary.checkbox("Schemas to include", choices=choices).ask() or []
        return selected, []
    else:
        selected = questionary.checkbox("Schemas to exclude", choices=choices).ask() or []
        return [], selected


def _wizard_options(cfg: Config) -> None:
    """Override compress / keep-days / base_dir."""
    _section("Backup Options")

    cfg.compress = questionary.confirm("Compress output with gzip?", default=cfg.compress).ask()

    days_str = questionary.text(
        "Keep backups for N days (0 = forever)",
        default=str(cfg.days_to_keep),
    ).ask()
    try:
        cfg.days_to_keep = int(days_str or cfg.days_to_keep)
    except ValueError:
        pass

    cfg.base_dir = questionary.text("Output directory", default=cfg.base_dir).ask() or cfg.base_dir


# ──────────────────────────────────────────────────────────────────────────────
#  Backup one database
# ──────────────────────────────────────────────────────────────────────────────

def _backup_one(
    db: str,
    cfg: Config,
    runner: PgRunner,
    include_schemas: list[str],
    exclude_schemas: list[str],
) -> Path:
    """Dump a single database. Returns the final dump file path."""
    db_dir = Path(cfg.base_dir) / db
    db_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    dump_file = db_dir / f"{db}_{timestamp}.dump"
    manifest_file = db_dir / f"manifest_{timestamp}.txt"

    # Build schema args
    schema_args: list[str] = []
    system_schemas = {"pg_catalog", "information_schema", "pg_toast"}
    if include_schemas:
        for s in include_schemas:
            schema_args += ["-n", s]
    else:
        all_exclude = list(exclude_schemas) + list(system_schemas)
        for s in all_exclude:
            schema_args += ["-N", s]

    # Write manifest
    with manifest_file.open("w") as mf:
        mf.write(f"Database  : {db}\n")
        mf.write(f"Timestamp : {timestamp}\n")
        mf.write(f"Host      : {cfg.host}:{cfg.port}\n")
        mf.write(f"User      : {cfg.user}\n")
        mf.write(f"Docker    : {cfg.use_docker}\n")
        mf.write("Format    : custom\n")
        if include_schemas:
            mf.write(f"Included  : {','.join(include_schemas)}\n")
        if exclude_schemas:
            mf.write(f"Excluded  : {','.join(exclude_schemas)}\n")
        mf.write(f"Compressed: {cfg.compress}\n")

    # Build pg_dump command
    base_dump_args = [
        "-U", cfg.user,
        "-h", cfg.host,
        "-p", str(cfg.port),
        "-F", "c",
        "-b",
    ] + schema_args + [db]

    # Run pg_dump, streaming stdout to the dump file
    if cfg.use_docker:
        import os
        env = None
        cmd = (
            ["docker", "exec", "-i",
             "-e", f"PGPASSWORD={cfg.password}",
             cfg.service,
             cfg.pg_dump_cmd]
            + base_dump_args
        )
    else:
        import os
        env = os.environ.copy()
        env["PGPASSWORD"] = cfg.password
        cmd = [cfg.pg_dump_cmd] + base_dump_args

    with dump_file.open("wb") as out_f:
        result = subprocess.run(
            cmd,
            stdout=out_f,
            env=env if not cfg.use_docker else None,
            check=True,
        )

    if cfg.compress:
        gz_file = Path(str(dump_file) + ".gz")
        with dump_file.open("rb") as f_in, gzip.open(gz_file, "wb", compresslevel=9) as f_out:
            shutil.copyfileobj(f_in, f_out)
        dump_file.unlink()
        dump_file = gz_file

    size = dump_file.stat().st_size
    human = f"{size / 1024 / 1024:.1f} MB" if size > 1024 * 1024 else f"{size / 1024:.1f} KB"
    console.print(f"  [green]✓[/] {dump_file.name}  ([dim]{human}[/])")
    return dump_file


# ──────────────────────────────────────────────────────────────────────────────
#  Cleanup old backups
# ──────────────────────────────────────────────────────────────────────────────

def _cleanup_old(base_dir: str, days: int) -> None:
    if days <= 0:
        return
    import time
    cutoff = time.time() - days * 86400
    base = Path(base_dir)
    for pattern in ("**/*.dump", "**/*.dump.gz", "**/manifest_*.txt"):
        for f in base.glob(pattern):
            if f.stat().st_mtime < cutoff:
                f.unlink()
                console.print(f"  [dim]Removed old backup: {f.name}[/]")


# ──────────────────────────────────────────────────────────────────────────────
#  Public entry point
# ──────────────────────────────────────────────────────────────────────────────

def run_backup(
    cfg: Config,
    *,
    interactive: bool = True,
    databases: list[str] | None = None,
    schemas: str | None = None,
    compress: bool | None = None,
    keep_days: int | None = None,
) -> None:
    """Main backup workflow."""
    runner = PgRunner(cfg)

    # Apply CLI overrides before wizard (wizard may further override)
    if compress is not None:
        cfg.compress = compress
    if keep_days is not None:
        cfg.days_to_keep = keep_days

    # Per-DB schema maps
    include_map: dict[str, list[str]] = {}
    exclude_map: dict[str, list[str]] = {}

    if interactive:
        console.print(Panel("[bold cyan]PostgreSQL Backup Wizard[/]", expand=False))

        _wizard_connection(cfg, runner)

        selected_dbs = _wizard_databases(cfg, runner)

        for db in selected_dbs:
            inc, exc = _wizard_schemas(db, runner)
            if inc:
                include_map[db] = inc
            if exc:
                exclude_map[db] = exc

        _wizard_options(cfg)

        # Summary + confirm
        _section("Summary")
        console.print(f"  Databases   : [bold]{', '.join(selected_dbs)}[/]")
        console.print(f"  Compress    : {cfg.compress}")
        console.print(f"  Retention   : {cfg.days_to_keep} days")
        console.print(f"  Output dir  : {cfg.base_dir}")
        console.print()

        if not questionary.confirm("Proceed with backup?", default=True).ask():
            console.print("[yellow]Aborted by user.[/]")
            sys.exit(0)

        dbs_to_backup = selected_dbs
    else:
        # Non-interactive path
        if not cfg.password:
            _die("PG_PASSWORD is required. Set it in .backup.")

        with console.status("Testing connection..."):
            runner.check_connection()
        console.print("[green]Connection OK.[/]")

        if databases:
            dbs_to_backup = databases
        else:
            dbs_to_backup = runner.list_databases()
            if not dbs_to_backup:
                _die("No databases found.")

        # CLI schema override (applies to all DBs)
        if schemas:
            for db in dbs_to_backup:
                include_map[db] = [s.strip() for s in schemas.split(",")]

    if not cfg.base_dir:
        _die("BASE_DIR is not set. Add it to .backup or pass --output-dir.")

    Path(cfg.base_dir).mkdir(parents=True, exist_ok=True)

    _section("Running Backup")

    for db in dbs_to_backup:
        console.print(f"\n  Backing up: [bold]{db}[/]")
        try:
            _backup_one(
                db,
                cfg,
                runner,
                include_schemas=include_map.get(db, []),
                exclude_schemas=exclude_map.get(db, []),
            )
        except subprocess.CalledProcessError as exc:
            _die(f"pg_dump failed for '{db}': exit code {exc.returncode}")

    _cleanup_old(cfg.base_dir, cfg.days_to_keep)

    console.print()
    console.print(Panel("[bold green]BACKUP COMPLETE[/]", expand=False))
