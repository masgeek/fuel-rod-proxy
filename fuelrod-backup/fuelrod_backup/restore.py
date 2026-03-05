"""Interactive restore wizard."""

from __future__ import annotations

import gzip
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import questionary
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from .config import Config
from .runner import PgRunner

console = Console()

_SYSTEM_SCHEMA_RE = re.compile(
    r"^(pg_catalog|information_schema|pg_toast|pg_temp.*|-|pg_)$"
)
_SYSTEM_ROLE_RE = re.compile(r"^(-|pg_[a-z_]+)$")


def _section(title: str) -> None:
    console.print()
    console.rule(f"[bold cyan]{title}[/]")
    console.print()


def _die(msg: str) -> None:
    console.print(f"[bold red]ERROR:[/] {msg}")
    sys.exit(1)


def _human_size(path: Path) -> str:
    size = path.stat().st_size
    if size > 1024 * 1024:
        return f"{size / 1024 / 1024:.1f} MB"
    return f"{size / 1024:.1f} KB"


# ──────────────────────────────────────────────────────────────────────────────
#  TOC parsing helpers
# ──────────────────────────────────────────────────────────────────────────────

def _parse_schemas_from_toc(toc: str) -> list[str]:
    """Extract user schema names from pg_restore --list output."""
    schemas: set[str] = set()
    for line in toc.splitlines():
        if line.startswith(";"):
            continue
        parts = line.split()
        if len(parts) < 5:
            continue
        # Schema objects: field[3] == "SCHEMA", name is field[5]
        if parts[3] == "SCHEMA" and len(parts) >= 6:
            name = parts[5]
            if not _SYSTEM_SCHEMA_RE.match(name):
                schemas.add(name)
            continue
        # Other objects: field[4] is the schema they belong to
        schema = parts[4] if len(parts) >= 5 else "-"
        if schema != "-" and not _SYSTEM_SCHEMA_RE.match(schema):
            schemas.add(schema)
    return sorted(schemas)


def _parse_owners_from_toc(toc: str) -> list[str]:
    """Extract object owner names from pg_restore --list output."""
    owners: set[str] = set()
    for line in toc.splitlines():
        if line.startswith(";"):
            continue
        parts = line.split()
        if len(parts) < 1:
            continue
        owner = parts[-1]
        if not _SYSTEM_ROLE_RE.match(owner):
            owners.add(owner)
    return sorted(owners)


def _parse_tables_from_toc(toc: str, schemas: list[str]) -> list[str]:
    """Return 'schema.table' pairs found in the TOC for the given schemas."""
    tables: list[str] = []
    schema_set = set(schemas)
    for line in toc.splitlines():
        if line.startswith(";"):
            continue
        parts = line.split()
        if len(parts) >= 7 and parts[3] == "TABLE" and parts[4] in schema_set:
            tables.append(f"{parts[4]}.{parts[5]}")
    return tables


# ──────────────────────────────────────────────────────────────────────────────
#  Step implementations
# ──────────────────────────────────────────────────────────────────────────────

def _step_connection(cfg: Config, runner: PgRunner) -> None:
    _section("Step 1 — Connection")

    if cfg.use_docker:
        console.print(f"  Mode   : [cyan]Docker[/] (service: {cfg.service})")
    else:
        console.print(f"  Mode   : Direct — {cfg.host}:{cfg.port}")
    console.print(f"  User   : {cfg.user}")
    console.print(f"  Source : {cfg.base_dir}")
    console.print()

    if questionary.confirm("Override connection settings?", default=False).ask():
        if not cfg.use_docker:
            cfg.host = questionary.text("Host", default=cfg.host).ask() or cfg.host
            cfg.port = int(questionary.text("Port", default=str(cfg.port)).ask() or cfg.port)
        cfg.user = questionary.text("Username", default=cfg.user).ask() or cfg.user
        new_pass = questionary.password("Password (blank to keep current)").ask() or ""
        if new_pass:
            cfg.password = new_pass

    with console.status("Testing connection..."):
        runner.check_connection()
    console.print("[green]Connection OK.[/]")


def _step_select_db_dir(cfg: Config) -> tuple[Path, str]:
    """Step 2: pick a database folder from BASE_DIR."""
    _section("Step 2 — Select Database")

    base = Path(cfg.base_dir)
    db_dirs = sorted([d for d in base.iterdir() if d.is_dir()])
    if not db_dirs:
        _die(f"No database folders found in {base}")

    table = Table(show_header=True, header_style="bold")
    table.add_column("#", style="dim", width=4)
    table.add_column("Database", min_width=24)
    table.add_column("Size", justify="right")
    table.add_column("Backups", justify="right")
    for i, d in enumerate(db_dirs):
        size = subprocess.run(
            ["du", "-sh", str(d)], capture_output=True
        ).stdout.decode().split("\t")[0] if shutil.which("du") else "?"
        count = len(list(d.glob("*.dump*")))
        table.add_row(str(i), d.name, size, str(count))
    console.print(table)

    choices = [questionary.Choice(title=d.name, value=d) for d in db_dirs]
    db_dir: Path = questionary.select("Select database", choices=choices).ask()
    database = db_dir.name
    console.print(f"  Selected: [bold]{database}[/]")
    return db_dir, database


def _step_select_file(db_dir: Path, database: str) -> Path:
    """Step 3: pick a backup file from the database folder."""
    _section("Step 3 — Select Backup File")

    backups = sorted(db_dir.glob(f"{database}_*.dump*"))
    if not backups:
        _die(f"No backup files found for '{database}' in {db_dir}")

    table = Table(show_header=True, header_style="bold")
    table.add_column("#", style="dim", width=4)
    table.add_column("File", min_width=40)
    table.add_column("Size", justify="right")
    for i, f in enumerate(backups):
        table.add_row(str(i), f.name, _human_size(f))
    console.print(table)

    choices = [questionary.Choice(title=f.name, value=f) for f in backups]
    chosen: Path = questionary.select(
        "Select backup file (latest = last entry)", choices=choices, default=backups[-1]
    ).ask()
    console.print(f"  Selected: [bold]{chosen.name}[/]")
    return chosen


def _step_schema_selection(toc: str) -> tuple[list[str], list[str]]:
    """Step 4: parse schemas from TOC, let user pick."""
    _section("Step 4 — Schema Selection")

    schemas = _parse_schemas_from_toc(toc)

    if not schemas:
        console.print("  No named user schemas detected — restoring everything.")
        return [], []

    choices = [questionary.Choice(title=s, value=s) for s in schemas]
    selected = questionary.checkbox(
        "Select schemas to restore (blank = all)", choices=choices
    ).ask() or []

    schema_args: list[str] = []
    if selected:
        for s in selected:
            schema_args += ["-n", s]
        console.print(f"  Schema filter: [bold]{', '.join(selected)}[/]")
    else:
        console.print("  All schemas will be restored.")
        selected = schemas

    return schema_args, selected


def _step_table_selection(toc: str, selected_schemas: list[str]) -> list[str]:
    """Step 4b: optional table selection within chosen schemas."""
    if not selected_schemas:
        return []

    tables = _parse_tables_from_toc(toc, selected_schemas)
    if not tables:
        return []

    console.print()
    console.print(f"  [bold]Tables in selected schemas ({len(tables)} total):[/]")

    choices = [questionary.Choice(title=t, value=t) for t in tables]
    selected = questionary.checkbox(
        "Select tables (blank = all)", choices=choices
    ).ask() or []

    table_args: list[str] = []
    if selected:
        seen_schemas: set[str] = set()
        for entry in selected:
            schema, tname = entry.split(".", 1)
            if schema not in seen_schemas and not any(
                a == schema for a in table_args if table_args
            ):
                seen_schemas.add(schema)
            table_args += ["-t", tname]
        console.print(f"  Table filter applied: {', '.join(selected)}")
    return table_args


def _step_role_analysis(toc: str, runner: PgRunner) -> list[str]:
    """Step 5: find missing roles, offer create / no-owner / ignore."""
    _section("Step 5 — Role Analysis")

    owners = _parse_owners_from_toc(toc)
    extra_args: list[str] = []

    if not owners:
        console.print("  No role information found in dump TOC.")
        return extra_args

    missing: list[str] = []
    for owner in owners:
        exists = runner.role_exists(owner)
        marker = "[green]EXISTS [/]" if exists else "[red]MISSING[/]"
        console.print(f"  [{marker}]  {owner}")
        if not exists:
            missing.append(owner)

    if not missing:
        console.print("\n  [green]All roles present.[/]")
        return extra_args

    console.print()
    console.print(f"  [yellow]WARN:[/] {len(missing)} role(s) are missing on the target server.")
    console.print()

    action = questionary.select(
        "How should missing roles be handled?",
        choices=[
            questionary.Choice("Create missing roles interactively", value="create"),
            questionary.Choice("Restore with --no-owner --no-privileges (skip ownership)", value="no_owner"),
            questionary.Choice("Ignore (restore will warn/fail on ownership)", value="ignore"),
        ],
    ).ask()

    if action == "create":
        for role in missing:
            console.print(f"\n  Creating role: [bold]{role}[/]")
            superuser = questionary.confirm("  Superuser?", default=False).ask()
            can_login = questionary.confirm("  Can login?", default=True).ask()
            password = questionary.password("  Password (blank = no password)").ask() or None
            runner.create_role(role, superuser=superuser, can_login=can_login, password=password)
            console.print(f"  [green]Role '{role}' created.[/]")
    elif action == "no_owner":
        extra_args += ["--no-owner", "--no-privileges"]
        console.print("  Will use --no-owner --no-privileges.")
    else:
        console.print("  [yellow]Ignoring missing roles — errors may appear in restore output.[/]")

    return extra_args


def _step_restore_options() -> tuple[list[str], list[str], int, bool]:
    """Step 6: scope, clean mode, parallelism, dry-run."""
    _section("Step 6 — Restore Options")

    scope_choice = questionary.select(
        "Restore scope",
        choices=[
            questionary.Choice("Full restore — schema + data", value="full"),
            questionary.Choice("Schema only", value="schema"),
            questionary.Choice("Data only", value="data"),
        ],
    ).ask()

    scope_args: list[str] = []
    if scope_choice == "schema":
        scope_args = ["--schema-only"]
    elif scope_choice == "data":
        scope_args = ["--data-only"]

    clean_args: list[str] = []
    if scope_choice != "data":
        clean_choice = questionary.select(
            "Object handling",
            choices=[
                questionary.Choice("Clean — DROP existing then recreate", value="clean"),
                questionary.Choice("Append — overlay onto existing objects", value="append"),
            ],
        ).ask()
        if clean_choice == "clean":
            clean_args = ["--clean", "--if-exists"]

    jobs_str = questionary.text("Parallel restore workers", default="1").ask() or "1"
    try:
        jobs = max(1, int(jobs_str))
    except ValueError:
        jobs = 1

    dry_run = questionary.confirm("Dry run? (show plan only — no changes made)", default=False).ask()

    return scope_args, clean_args, jobs, dry_run


def _step_target_db(database: str, dry_run: bool, runner: PgRunner) -> str:
    """Step 7: confirm target database, drop/recreate if needed."""
    _section("Step 7 — Target Database")

    target = questionary.text(
        "Restore into database name", default=database
    ).ask() or database

    if not dry_run:
        if runner.db_exists(target):
            console.print(f"  [yellow]Database '{target}' already exists.[/]")
            drop_it = questionary.select(
                "Action",
                choices=[
                    questionary.Choice("Drop and recreate (clean slate)", value="drop"),
                    questionary.Choice("Keep existing (overlay)", value="keep"),
                ],
                default="keep",
            ).ask()
            if drop_it == "drop":
                killed = runner.terminate_connections(target)
                if killed:
                    console.print(f"  [yellow]Terminated {killed} active connection(s) to '{target}'.[/]")
                console.print(f"  Dropping '{target}'...")
                runner.drop_db(target)
                console.print(f"  Creating '{target}'...")
                runner.create_db(target)
        else:
            console.print(f"  Creating '{target}'...")
            runner.create_db(target)

    return target


# ──────────────────────────────────────────────────────────────────────────────
#  Execute restore
# ──────────────────────────────────────────────────────────────────────────────

def _execute_restore(
    backup_file: Path,
    target_db: str,
    restore_args: list[str],
    cfg: Config,
) -> None:
    """Stream the dump file into pg_restore."""
    import os

    base_args = [
        "-U", cfg.user,
        "-h", cfg.host,
        "-p", str(cfg.port),
        "-d", target_db,
        "-v",
    ] + restore_args

    if cfg.use_docker:
        cmd = (
            ["docker", "exec", "-i",
             "-e", f"PGPASSWORD={cfg.password}",
             "-e", f"PGUSER={cfg.user}",
             cfg.service,
             cfg.pg_restore_cmd]
            + base_args
        )
        env = None
    else:
        cmd = [cfg.pg_restore_cmd] + base_args
        env = os.environ.copy()
        env["PGPASSWORD"] = cfg.password

    if backup_file.suffix == ".gz":
        # gzip.open() has no real file descriptor so it cannot be passed directly
        # as stdin to a subprocess. Decompress to a temp file first.
        console.print("  Backup is gzipped — decompressing to temp file...")
        tmp = Path(tempfile.mktemp(suffix=".dump"))
        try:
            with gzip.open(backup_file, "rb") as gz_in, tmp.open("wb") as f_out:
                shutil.copyfileobj(gz_in, f_out)
            with tmp.open("rb") as f_in:
                subprocess.run(cmd, stdin=f_in, env=env, check=True)
        finally:
            if tmp.exists():
                tmp.unlink()
    else:
        with backup_file.open("rb") as f_in:
            subprocess.run(cmd, stdin=f_in, env=env, check=True)


# ──────────────────────────────────────────────────────────────────────────────
#  Public entry point
# ──────────────────────────────────────────────────────────────────────────────

def run_restore(cfg: Config) -> None:
    """Main restore workflow (always interactive)."""
    runner = PgRunner(cfg)

    if not cfg.password:
        _die("PG_PASSWORD is required. Set it in .backup.")
    if not cfg.base_dir or not Path(cfg.base_dir).is_dir():
        _die(f"Backup directory not found: {cfg.base_dir}")

    console.print(Panel("[bold cyan]PostgreSQL Restore Wizard[/]", expand=False))

    # Step 1 — Connection
    _step_connection(cfg, runner)

    # Step 2 — Select database folder
    db_dir, database = _step_select_db_dir(cfg)

    # Step 3 — Select backup file
    backup_file = _step_select_file(db_dir, database)

    # Read TOC
    _section("Analysing Dump")
    with console.status("Reading table of contents..."):
        try:
            toc = runner.read_toc(backup_file)
        except subprocess.CalledProcessError as exc:
            _die(f"Failed to read dump TOC: {exc}")

    # Show dump metadata from TOC comments
    meta_lines = [
        line.lstrip("; ") for line in toc.splitlines()
        if line.startswith(";") and any(
            kw in line for kw in ("dbname", "Dump Version", "Dumped from", "Dumped by", "Format", "Compression")
        )
    ]
    if meta_lines:
        console.print("\n  [bold]Dump metadata:[/]")
        for ml in meta_lines:
            console.print(f"    {ml}")

    # Step 4 — Schema selection
    schema_args, selected_schemas = _step_schema_selection(toc)

    # Step 4b — Table selection
    table_args = _step_table_selection(toc, selected_schemas)

    # Step 5 — Role analysis
    role_args = _step_role_analysis(toc, runner)

    # Step 6 — Restore options
    scope_args, clean_args, jobs, dry_run = _step_restore_options()

    # Step 7 — Target database
    target_db = _step_target_db(database, dry_run, runner)

    # Assemble restore args
    restore_args: list[str] = []
    restore_args += clean_args
    restore_args += scope_args
    restore_args += schema_args
    restore_args += table_args
    restore_args += role_args
    if jobs > 1:
        restore_args += ["-j", str(jobs)]

    # Summary
    console.print()
    console.print(Panel("[bold]RESTORE SUMMARY[/]", expand=False))
    console.print(f"  Source file : [bold]{backup_file.name}[/]")
    console.print(f"  Target DB   : [bold]{target_db}[/]")
    console.print(f"  Schemas     : {', '.join(selected_schemas) or 'all'}")
    console.print(f"  Scope       : {scope_args[0].lstrip('-') if scope_args else 'full'}")
    console.print(f"  Drop first  : {'yes' if clean_args else 'no'}")
    console.print(f"  Workers     : {jobs}")
    console.print(f"  No-owner    : {'yes' if '--no-owner' in role_args else 'no'}")
    console.print(f"  Dry run     : {dry_run}")
    console.print(f"\n  [dim]pg_restore {' '.join(restore_args)}[/]")
    console.print()

    if dry_run:
        console.print("[yellow]Dry run complete. No changes were made.[/]")
        return

    if not questionary.confirm("Proceed with restore? This may be destructive.", default=False).ask():
        console.print("[yellow]Aborted by user.[/]")
        sys.exit(0)

    # Ensure all required schemas exist before pg_restore runs.
    # pg_restore may encounter schema-qualified object references before it processes
    # the SCHEMA entry itself (especially with -n filtering), causing "schema does not exist".
    schemas_to_ensure = selected_schemas or _parse_schemas_from_toc(toc)
    if schemas_to_ensure:
        console.print(f"  Ensuring schemas exist: {', '.join(schemas_to_ensure)}")
        runner.ensure_schemas(target_db, schemas_to_ensure)

    # Execute
    console.print()
    console.print(f"  Starting restore of '[bold]{backup_file.name}[/]' → '[bold]{target_db}[/]'...")
    console.print()

    try:
        _execute_restore(backup_file, target_db, restore_args, cfg)
    except subprocess.CalledProcessError as exc:
        _die(f"Restore failed (exit {exc.returncode}). Check output above for details.")

    # Post-restore stats
    _section("Post-Restore Report")

    table_count = runner.get_table_count(target_db)
    console.print(f"  Tables restored : {table_count}")

    for schema in selected_schemas:
        cnt = runner.get_table_count(target_db, schema=schema)
        console.print(f"    {schema:<28} {cnt} tables")

    console.print()
    console.print(Panel(f"[bold green]RESTORE COMPLETE → {target_db}[/]", expand=False))
