"""Backup wizard and execution logic."""

from __future__ import annotations

import gzip
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from . import prompt as questionary
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from .adapters import get_adapter
from .adapters.base import DbAdapter
from .config import Config

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

def _wizard_connection(cfg: Config, adapter: DbAdapter) -> None:
    """Optionally override connection settings, then test."""
    _section("Connection")

    console.print(f"  Engine: [cyan]{cfg.db_type.value}[/]")
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
        _die("Password is required. Set the appropriate *_PASSWORD variable in .backup.")

    console.print()
    with console.status("Testing connection..."):
        adapter.check_connection()
    console.print("[green]Connection OK.[/]")


def _wizard_databases(cfg: Config, adapter: DbAdapter) -> list[str]:
    """Let user pick which databases to back up."""
    _section("Select Databases")

    all_dbs = adapter.list_databases()
    if not all_dbs:
        _die("No databases found on server.")

    table = Table(show_header=True, header_style="bold")
    table.add_column("#", style="dim", width=4)
    table.add_column("Database", min_width=24)
    table.add_column("Size", justify="right")
    for i, db in enumerate(all_dbs):
        size = adapter.get_db_size(db)
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


def _wizard_schemas(db: str, adapter: DbAdapter) -> tuple[list[str], list[str]]:
    """Return (include_schemas, exclude_schemas) for a database (only if supported)."""
    schemas = adapter.get_user_schemas(db)
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
    adapter: DbAdapter,
    include_schemas: list[str],
    exclude_schemas: list[str],
) -> Path:
    """Dump a single database. Returns the final dump file path."""
    db_dir = Path(cfg.base_dir) / db
    db_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    ext = adapter.dump_extension
    dump_file = db_dir / f"{db}_{timestamp}{ext}"
    manifest_file = db_dir / f"manifest_{timestamp}.txt"

    # Write manifest
    with manifest_file.open("w") as mf:
        mf.write(f"Database  : {db}\n")
        mf.write(f"Engine    : {cfg.db_type.value}\n")
        mf.write(f"Timestamp : {timestamp}\n")
        mf.write(f"Host      : {cfg.host}:{cfg.port}\n")
        mf.write(f"User      : {cfg.user}\n")
        mf.write(f"Docker    : {cfg.use_docker}\n")
        if include_schemas:
            mf.write(f"Included  : {','.join(include_schemas)}\n")
        if exclude_schemas:
            mf.write(f"Excluded  : {','.join(exclude_schemas)}\n")
        mf.write(f"Compressed: {cfg.compress}\n")

    adapter.backup_db(
        db,
        dump_file,
        include_schemas=include_schemas,
        exclude_schemas=exclude_schemas,
    )

    if cfg.compress and not dump_file.suffix == ".bak":
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
    for pattern in ("**/*.dump", "**/*.dump.gz", "**/*.sql", "**/*.sql.gz", "**/*.bak", "**/manifest_*.txt"):
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
    adapter = get_adapter(cfg)

    # Apply CLI overrides before wizard (wizard may further override)
    if compress is not None:
        cfg.compress = compress
    if keep_days is not None:
        cfg.days_to_keep = keep_days

    # Per-DB schema maps
    include_map: dict[str, list[str]] = {}
    exclude_map: dict[str, list[str]] = {}

    if interactive:
        console.print(Panel(f"[bold cyan]{cfg.db_type.value.upper()} Backup Wizard[/]", expand=False))

        _wizard_connection(cfg, adapter)

        selected_dbs = _wizard_databases(cfg, adapter)

        if adapter.supports_schemas:
            for db in selected_dbs:
                inc, exc = _wizard_schemas(db, adapter)
                if inc:
                    include_map[db] = inc
                if exc:
                    exclude_map[db] = exc

        _wizard_options(cfg)

        # Summary + confirm
        _section("Summary")
        console.print(f"  Engine      : [cyan]{cfg.db_type.value}[/]")
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
            _die("Password is required. Set it in .backup.")

        with console.status("Testing connection..."):
            adapter.check_connection()
        console.print("[green]Connection OK.[/]")

        if databases:
            dbs_to_backup = databases
        else:
            dbs_to_backup = adapter.list_databases()
            if not dbs_to_backup:
                _die("No databases found.")

        # CLI schema override (applies to all DBs, only for engines that support schemas)
        if schemas and adapter.supports_schemas:
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
                adapter,
                include_schemas=include_map.get(db, []),
                exclude_schemas=exclude_map.get(db, []),
            )
        except subprocess.CalledProcessError as exc:
            _die(f"Backup failed for '{db}': exit code {exc.returncode}")
        except Exception as exc:
            _die(f"Backup failed for '{db}': {exc}")

    _cleanup_old(cfg.base_dir, cfg.days_to_keep)

    console.print()
    console.print(Panel("[bold green]BACKUP COMPLETE[/]", expand=False))
