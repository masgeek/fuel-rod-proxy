#!/bin/bash
# database-restore-postgres.sh
# Fully interactive PostgreSQL restore wizard
set -euo pipefail

# ══════════════════════════════════════════════════════════════
#  Terminal colours
# ══════════════════════════════════════════════════════════════
if [[ -t 1 ]]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
    CYAN='\033[0;36m' BOLD='\033[1m' DIM='\033[2m' RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' RESET=''
fi

# ══════════════════════════════════════════════════════════════
#  Logging
# ══════════════════════════════════════════════════════════════
ts()   { date +'%Y-%m-%d %H:%M:%S'; }
log()  { echo -e "${DIM}[$(ts)]${RESET} $*"; }
info() { echo -e "${CYAN}[$(ts)]${RESET} $*"; }
ok()   { echo -e "${GREEN}[$(ts)]${RESET} $*"; }
warn() { echo -e "${YELLOW}[$(ts)] WARN:${RESET} $*"; }
die()  { echo -e "${RED}[$(ts)] ERROR:${RESET} $*" >&2; exit 1; }

section() {
    echo ""
    echo -e "${BOLD}  ══════════════════════════════════════${RESET}"
    echo -e "${BOLD}    $*${RESET}"
    echo -e "${BOLD}  ══════════════════════════════════════${RESET}"
    echo ""
}

# ══════════════════════════════════════════════════════════════
#  Load .backup environment
# ══════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/.backup" ]] && source "$SCRIPT_DIR/.backup"

# ══════════════════════════════════════════════════════════════
#  Defaults
# ══════════════════════════════════════════════════════════════
PG_USER="${PG_USERNAME:-postgres}"
PG_PASS="${PG_PASSWORD:-}"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
SERVICE="${SERVICE:-postgres}"
USE_DOCKER="${USE_DOCKER:-true}"; USE_DOCKER="${USE_DOCKER,,}"  # normalise: true/True/TRUE → true
BASE_DIR="${BASE_DIR:-$SCRIPT_DIR/db-backup}"
psql_cmd="psql"
pg_restore_cmd="pg_restore"

[[ -z "$PG_PASS" ]]    && die "PG_PASSWORD is required. Set it in .backup."
[[ ! -d "$BASE_DIR" ]] && die "Backup directory not found: $BASE_DIR"

# ══════════════════════════════════════════════════════════════
#  Low-level helpers
# ══════════════════════════════════════════════════════════════
psql_exec() {
    if [[ "$USE_DOCKER" == "true" ]]; then
        # Pass PGUSER explicitly so the container's own POSTGRES_USER env var
        # cannot override the role we intend to use when -U is empty or unset.
        # docker exec -e PGPASSWORD="$PG_PASS" -e PGUSER="$PG_USER" "$SERVICE" "$psql_cmd" "$@"
        docker exec -e PGPASSWORD="$PG_PASS" "$SERVICE" "$psql_cmd" "$@"
    else
        PGPASSWORD="$PG_PASS" "$psql_cmd" "$@"
    fi
}


restore_stream() {
    if [[ "$USE_DOCKER" == "true" ]]; then
        docker exec -i -e PGPASSWORD="$PG_PASS" -e PGUSER="$PG_USER" "$SERVICE" "$pg_restore_cmd" "$@"
    else
        PGPASSWORD="$PG_PASS" "$pg_restore_cmd" "$@"
    fi
}

read_dump_toc() {
    local file="$1"
    local work_file="$file"
    local tmp_file=""

    # Always work with a plain (uncompressed) dump file
    if [[ "$file" == *.gz ]]; then
        tmp_file=$(mktemp /tmp/pg_toc_XXXXXX.dump)
        gunzip -c "$file" > "$tmp_file"
        work_file="$tmp_file"
    fi

    if [[ "$USE_DOCKER" == "true" ]]; then
        # Use docker cp — piping binary data through docker exec -i is unreliable
        # (WSL/Docker Desktop can corrupt the stream). pg_restore --list needs no
        # database connection so no password is required.
        local ctr_path="/tmp/pg_toc_$$.dump"
        docker cp "$work_file" "${SERVICE}:${ctr_path}"
        docker exec "$SERVICE" "$pg_restore_cmd" --list "$ctr_path"
        docker exec "$SERVICE" rm -f "$ctr_path" &>/dev/null || true
    else
        "$pg_restore_cmd" --list "$work_file"
    fi

    [[ -n "$tmp_file" ]] && rm -f "$tmp_file"
}

db_exists() {
    psql_exec -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres \
        -At -c "SELECT 1 FROM pg_database WHERE datname='$1'" 2>/dev/null | grep -q 1
}

role_exists() {
    psql_exec -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres \
        -At -c "SELECT 1 FROM pg_roles WHERE rolname='$1'" 2>/dev/null | grep -q 1
}

check_connection() {
    log "Testing connection → host=${PG_HOST} port=${PG_PORT} user=${PG_USER} docker=${USE_DOCKER}"

    # ── Pre-flight checks ────────────────────────────────────
    if [[ "$USE_DOCKER" == "true" ]]; then
        command -v docker &>/dev/null \
            || die "docker binary not found in PATH. Install Docker or set USE_DOCKER=false in .backup."

        local state
        state=$(docker inspect --format '{{.State.Status}}' "$SERVICE" 2>/dev/null || echo "missing")
        [[ "$state" == "running" ]] \
            || die "Container '$SERVICE' is not running (state: $state). Start it or check SERVICE= in .backup."

        docker exec "$SERVICE" which "$psql_cmd" &>/dev/null \
            || die "'$psql_cmd' not found inside container '$SERVICE'. Is this a PostgreSQL container?"
    else
        command -v "$psql_cmd" &>/dev/null \
            || die "'$psql_cmd' not found in PATH. Install postgresql-client or add it to your PATH."

        # Best-effort port reachability (bash built-in TCP, no nc required)
        if ! timeout 5 bash -c ">/dev/tcp/${PG_HOST}/${PG_PORT}" 2>/dev/null; then
            die "Cannot reach ${PG_HOST}:${PG_PORT}. PostgreSQL may not be running or the port is blocked."
        fi
    fi

    # ── Attempt connection — check exit code, not stderr content ─────────
    # stderr may contain harmless warnings (version mismatch, NOTICEs) even
    # on a successful connection, so we must not treat any stderr as failure.
    local err exit_code=0
    if [[ "$USE_DOCKER" == "true" ]]; then
        # -T: no pseudo-TTY — prevents Docker/WSL injecting escape sequences
        err=$(docker exec -e PGPASSWORD="$PG_PASS" "$SERVICE" \
            "$psql_cmd" -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres \
            -c "SELECT 1" -q 2>&1 >/dev/null) || exit_code=$?
    else
        err=$(PGPASSWORD="$PG_PASS" "$psql_cmd" \
            -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres \
            -c "SELECT 1" -q 2>&1 >/dev/null) || exit_code=$?
    fi

    if [[ $exit_code -eq 0 ]]; then
        ok "Connection OK."
        return 0
    fi

    # Parse stderr for an actionable failure reason
    if   echo "$err" | grep -qi "password authentication failed";        then die "Wrong password for user '$PG_USER'. Check PG_PASSWORD in .backup."
    elif echo "$err" | grep -qi "role.*does not exist";                  then die "User '$PG_USER' does not exist on the server. Check PG_USERNAME in .backup."
    elif echo "$err" | grep -qi "pg_hba.conf";                           then die "Connection blocked by pg_hba.conf for '$PG_USER'. Check server auth config."
    elif echo "$err" | grep -qi "Connection refused\|could not connect"; then die "Connection refused at ${PG_HOST}:${PG_PORT}. Is PostgreSQL accepting connections?"
    elif echo "$err" | grep -qi "No route to host\|Network unreachable"; then die "Network error reaching ${PG_HOST}:${PG_PORT}. Check PG_HOST in .backup."
    elif echo "$err" | grep -qi "could not translate host name";         then die "Hostname '${PG_HOST}' not resolvable. Check PG_HOST in .backup."
    elif echo "$err" | grep -qi "SSL";                                   then die "SSL negotiation failed. Try adding PGSSLMODE=disable to .backup."
    else die "Connection failed (exit $exit_code): ${err}"
    fi
}

prompt_default() {
    local label="$1" default="$2" ans
    read -rp "  ${label} [${default}]: " ans || true
    echo "${ans:-$default}"
}

prompt_yn() {
    # Returns 0 for yes, 1 for no. Second arg is default: "y" or "n".
    local prompt="$1" default="${2:-y}" hint ans
    [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    read -rp "  ${prompt} ${hint}: " ans || true
    ans="${ans:-$default}"
    [[ "${ans,,}" == "y" ]]
}

psql_count() {
    # Usage: psql_count <db> <query>
    psql_exec -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d "$1" -At -c "$2" 2>/dev/null || echo "?"
}

# ══════════════════════════════════════════════════════════════
#  Banner
# ══════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║    PostgreSQL Restore Wizard             ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${RESET}"

# ══════════════════════════════════════════════════════════════
#  Step 1 — Connection settings
# ══════════════════════════════════════════════════════════════
section "Step 1 of 7 — Connection"

echo -e "  ${BOLD}Current settings:${RESET}"
if [[ "$USE_DOCKER" == "true" ]]; then
    echo -e "  Mode     : ${CYAN}Docker${RESET} (service: $SERVICE)"
else
    echo -e "  Mode     : Direct — ${PG_HOST}:${PG_PORT}"
fi
echo -e "  User     : $PG_USER"
echo -e "  Source   : $BASE_DIR"
echo ""

if prompt_yn "Override connection settings?" n; then
    if [[ "$USE_DOCKER" != "true" ]]; then
        PG_HOST=$(prompt_default "Host" "$PG_HOST")
        PG_PORT=$(prompt_default "Port" "$PG_PORT")
    else
        warn "Docker mode: host/port are determined by the container. Set USE_DOCKER=false in .backup to connect directly."
    fi
    PG_USER=$(prompt_default "Username" "$PG_USER")
    PASS_HINT="not set"; [[ -n "$PG_PASS" ]] && PASS_HINT="***set***"
    NEW_PASS=""
    read -rsp "  Password [${PASS_HINT}]: " NEW_PASS || true; echo ""
    [[ -n "$NEW_PASS" ]] && PG_PASS="$NEW_PASS"
fi

# check_connection

# ══════════════════════════════════════════════════════════════
#  Step 2 — Select database folder
# ══════════════════════════════════════════════════════════════
section "Step 2 of 7 — Select Database"

mapfile -t DB_DIRS < <(find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
[[ ${#DB_DIRS[@]} -eq 0 ]] && die "No database folders found in $BASE_DIR"

echo -e "  ${BOLD}Available databases:${RESET}"
echo ""
for i in "${!DB_DIRS[@]}"; do
    DIR_SIZE=$(du -sh "${DB_DIRS[$i]}" 2>/dev/null | cut -f1)
    FILE_COUNT=$(find "${DB_DIRS[$i]}" -name "*.dump*" 2>/dev/null | wc -l)
    printf "    [%2d]  %-28s  %6s  (%s backup files)\n" \
        "$i" "$(basename "${DB_DIRS[$i]}")" "$DIR_SIZE" "$FILE_COUNT"
done
echo ""

read -rp "  Select database: " DB_CHOICE || true
[[ "$DB_CHOICE" =~ ^[0-9]+$ ]]         || die "Invalid input: expected a number."
(( DB_CHOICE < ${#DB_DIRS[@]} ))        || die "Out of range."

DB_DIR="${DB_DIRS[$DB_CHOICE]}"
DATABASE="$(basename "$DB_DIR")"
log "Selected database: ${BOLD}${DATABASE}${RESET}"

# ══════════════════════════════════════════════════════════════
#  Step 3 — Select backup file
# ══════════════════════════════════════════════════════════════
section "Step 3 of 7 — Select Backup File"

mapfile -t BACKUPS < <(find "$DB_DIR" -type f -name "${DATABASE}_*.dump*" | sort)
[[ ${#BACKUPS[@]} -eq 0 ]] && die "No backup files found for '$DATABASE' in $DB_DIR"

echo -e "  ${BOLD}Available backups (oldest → newest):${RESET}"
echo ""
for i in "${!BACKUPS[@]}"; do
    BNAME=$(basename "${BACKUPS[$i]}")
    BSIZE=$(du -sh "${BACKUPS[$i]}" 2>/dev/null | cut -f1)
    BDATE=$(date -r "${BACKUPS[$i]}" +'%Y-%m-%d %H:%M' 2>/dev/null || echo "?")
    printf "    [%2d]  %-45s  %6s  %s\n" "$i" "$BNAME" "$BSIZE" "$BDATE"
done
echo ""

read -rp "  Select backup (Enter = latest): " BACKUP_CHOICE || true
if [[ -z "$BACKUP_CHOICE" ]]; then
    BACKUP_FILE="${BACKUPS[-1]}"
else
    [[ "$BACKUP_CHOICE" =~ ^[0-9]+$ ]]            || die "Invalid input."
    (( BACKUP_CHOICE < ${#BACKUPS[@]} ))           || die "Out of range."
    BACKUP_FILE="${BACKUPS[$BACKUP_CHOICE]}"
fi

[[ -f "$BACKUP_FILE" ]] || die "Backup file missing: $BACKUP_FILE"
log "Selected: $(basename "$BACKUP_FILE")"

# ══════════════════════════════════════════════════════════════
#  Read dump TOC
# ══════════════════════════════════════════════════════════════
section "Analysing Dump"

log "Reading table of contents..."
TOC=$(read_dump_toc "$BACKUP_FILE") \
    || die "Failed to read dump TOC. File may be corrupt or is not a pg_dump custom/directory archive."

echo ""
echo -e "  ${BOLD}Dump metadata:${RESET}"
echo "$TOC" | grep '^;' \
    | grep -E '(dbname|Dump Version|Dumped from|Dumped by|Format|Compression)' \
    | sed 's/^;\s*/    /' || true
echo ""

# ══════════════════════════════════════════════════════════════
#  Step 4 — Schema selection
# ══════════════════════════════════════════════════════════════
section "Step 4 of 7 — Schema Selection"

SCHEMA_ARGS=()
SELECTED_SCHEMA_NAMES=()
SKIP_SCHEMAS_RE="^(pg_catalog|information_schema|pg_toast|pg_temp.*|-|pg_)$"

mapfile -t SCHEMAS < <(
    echo "$TOC" | grep -v '^;' | awk '
        NF < 5 { next }
        $4 == "SCHEMA" { print $6; next }
        $5 != "-"       { print $5 }
    ' | grep -Ev "$SKIP_SCHEMAS_RE" | sort -u
)

if [[ ${#SCHEMAS[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}Schemas found in dump:${RESET}"
    echo ""
    for i in "${!SCHEMAS[@]}"; do
        printf "    [%2d]  %s\n" "$i" "${SCHEMAS[$i]}"
    done
    echo "    [a]   All schemas  (default)"
    echo ""

    read -rp "  Select schemas (comma-sep indices, blank or 'a' for all): " SCHEMA_CHOICE || true

    if [[ -z "$SCHEMA_CHOICE" || "${SCHEMA_CHOICE,,}" == "a" ]]; then
        log "All schemas will be restored."
        SELECTED_SCHEMA_NAMES=("${SCHEMAS[@]}")
    else
        IFS=',' read -ra SEL_IDXS <<< "$SCHEMA_CHOICE"
        for idx in "${SEL_IDXS[@]}"; do
            idx="${idx// /}"
            [[ "$idx" =~ ^[0-9]+$ ]]     || die "Invalid schema index: $idx"
            (( idx < ${#SCHEMAS[@]} ))    || die "Schema index out of range: $idx"
            SCHEMA_ARGS+=("-n" "${SCHEMAS[$idx]}")
            SELECTED_SCHEMA_NAMES+=("${SCHEMAS[$idx]}")
        done
        log "Schema filter: ${SELECTED_SCHEMA_NAMES[*]}"
    fi
else
    log "No named user schemas detected in dump — restoring everything."
fi

# ══════════════════════════════════════════════════════════════
#  Step 4b — Optional table selection
# ══════════════════════════════════════════════════════════════
TABLE_ARGS=()

if [[ ${#SELECTED_SCHEMA_NAMES[@]} -gt 0 ]]; then
    # Gather tables in the TOC that belong to selected schemas
    ALL_TABLES=()
    for TSCHEMA in "${SELECTED_SCHEMA_NAMES[@]}"; do
        mapfile -t SCHEMA_TABLES < <(
            echo "$TOC" | grep -v '^;' | awk -v s="$TSCHEMA" '
                NF >= 7 && $4 == "TABLE" && $5 == s { print s "." $6 }
            '
        )
        if [[ ${#SCHEMA_TABLES[@]} -gt 0 ]]; then
            ALL_TABLES+=("${SCHEMA_TABLES[@]}")
        fi
    done

    if [[ ${#ALL_TABLES[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${BOLD}Tables in selected schemas (${#ALL_TABLES[@]} total):${RESET}"
        echo "  ${DIM}Skip this step to restore all tables.${RESET}"
        echo ""
        for i in "${!ALL_TABLES[@]}"; do
            printf "    [%3d]  %s\n" "$i" "${ALL_TABLES[$i]}"
        done
        echo "    [a]    All tables  (default)"
        echo ""

        read -rp "  Select tables (comma-sep indices, blank or 'a' for all): " TABLE_CHOICE || true

        if [[ -n "$TABLE_CHOICE" && "${TABLE_CHOICE,,}" != "a" ]]; then
            IFS=',' read -ra TABLE_IDXS <<< "$TABLE_CHOICE"
            for idx in "${TABLE_IDXS[@]}"; do
                idx="${idx// /}"
                [[ "$idx" =~ ^[0-9]+$ ]]        || die "Invalid table index: $idx"
                (( idx < ${#ALL_TABLES[@]} ))    || die "Table index out of range: $idx"
                TBL_ENTRY="${ALL_TABLES[$idx]}"
                TBL_SCHEMA="${TBL_ENTRY%%.*}"
                TBL_NAME="${TBL_ENTRY##*.}"
                # Only add -n if not already included via schema filter
                if [[ ${#SCHEMA_ARGS[@]} -eq 0 ]]; then
                    TABLE_ARGS+=("-n" "$TBL_SCHEMA")
                fi
                TABLE_ARGS+=("-t" "$TBL_NAME")
            done
            log "Table filter applied: ${TABLE_ARGS[*]}"
        else
            log "All tables in selected schemas will be restored."
        fi
    fi
fi

# ══════════════════════════════════════════════════════════════
#  Step 5 — Role analysis and creation
# ══════════════════════════════════════════════════════════════
section "Step 5 of 7 — Role Analysis"

RESTORE_NO_OWNER=false

mapfile -t DUMP_OWNERS < <(
    echo "$TOC" | grep -v '^;' | awk 'NF >= 5 { print $NF }' \
        | grep -Ev '^(-|pg_[a-z_]+)$' | sort -u
)

MISSING_ROLES=()
if [[ ${#DUMP_OWNERS[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}Roles referenced in dump:${RESET}"
    echo ""
    for OWNER in "${DUMP_OWNERS[@]}"; do
        if role_exists "$OWNER"; then
            echo -e "    ${GREEN}[EXISTS ]${RESET}  $OWNER"
        else
            echo -e "    ${RED}[MISSING]${RESET}  $OWNER"
            MISSING_ROLES+=("$OWNER")
        fi
    done
else
    log "No role information found in dump TOC."
fi

if [[ ${#MISSING_ROLES[@]} -gt 0 ]]; then
    echo ""
    warn "${#MISSING_ROLES[@]} role(s) are missing on the target server."
    echo ""
    echo "    [1]  Create missing roles interactively"
    echo "    [2]  Restore with --no-owner --no-privileges  (skip ownership)"
    echo "    [3]  Ignore  (restore will warn/fail on ownership)"
    echo ""
    read -rp "  Choose [1/2/3]: " ROLE_CHOICE || true

    case "${ROLE_CHOICE:-3}" in
        1)
            for ROLE in "${MISSING_ROLES[@]}"; do
                echo ""
                info "  Creating role: ${BOLD}${ROLE}${RESET}"

                read -rp "    Superuser? [y/N]: " IS_SUPER   || true
                read -rp "    Can login? [Y/n]: " CAN_LOGIN  || true
                read -rsp "    Password   (blank = no password): " ROLE_PASS || true; echo ""

                SUPER_OPT="NOSUPERUSER NOCREATEDB NOCREATEROLE"
                [[ "${IS_SUPER,,}" == "y" ]] && SUPER_OPT="SUPERUSER"

                LOGIN_OPT="LOGIN"
                [[ "${CAN_LOGIN,,}" == "n" ]] && LOGIN_OPT="NOLOGIN"

                PASS_OPT=""
                [[ -n "${ROLE_PASS:-}" ]] && PASS_OPT="PASSWORD '${ROLE_PASS}'"

                ROLE_SQL="CREATE ROLE \"${ROLE}\" WITH ${SUPER_OPT} ${LOGIN_OPT} ${PASS_OPT};"
                log "  → CREATE ROLE \"${ROLE}\" WITH ${SUPER_OPT} ${LOGIN_OPT} [PASSWORD ***]"
                psql_exec -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres -c "$ROLE_SQL"
                ok "  Role '${ROLE}' created."
            done
            ;;
        2)
            RESTORE_NO_OWNER=true
            log "Will use --no-owner --no-privileges."
            ;;
        3)
            warn "Ignoring missing roles — ownership errors may appear in restore output."
            ;;
        *)
            die "Invalid choice: ${ROLE_CHOICE:-}"
            ;;
    esac
else
    ok "All roles present. No action needed."
fi

# ══════════════════════════════════════════════════════════════
#  Step 6 — Restore options
# ══════════════════════════════════════════════════════════════
section "Step 6 of 7 — Restore Options"

# Scope
echo -e "  ${BOLD}Restore scope:${RESET}"
echo "    [1]  Full restore — schema + data  (default)"
echo "    [2]  Schema only  (structure, no rows)"
echo "    [3]  Data only    (rows into existing tables)"
echo ""
read -rp "  Choose [1/2/3, Enter=1]: " SCOPE_CHOICE || true
SCOPE_ARGS=()
case "${SCOPE_CHOICE:-1}" in
    1) log "Scope: full (schema + data)" ;;
    2) SCOPE_ARGS+=(--schema-only); log "Scope: schema only" ;;
    3) SCOPE_ARGS+=(--data-only);   log "Scope: data only"   ;;
    *) die "Invalid choice: ${SCOPE_CHOICE}" ;;
esac
echo ""

# Clean mode (skip for data-only — DROP doesn't apply to rows)
CLEAN_ARGS=()
if [[ "${SCOPE_CHOICE:-1}" != "3" ]]; then
    echo -e "  ${BOLD}Object handling:${RESET}"
    echo "    [1]  Clean — DROP existing objects then recreate  (default)"
    echo "    [2]  Append — overlay onto existing objects"
    echo ""
    read -rp "  Choose [1/2, Enter=1]: " CLEAN_CHOICE || true
    if [[ "${CLEAN_CHOICE:-1}" == "1" ]]; then
        CLEAN_ARGS+=(--clean --if-exists)
        log "Object handling: clean (--clean --if-exists)"
    else
        log "Object handling: append (no --clean)"
    fi
    echo ""
fi

# Parallel workers
read -rp "  Parallel restore workers [1]: " JOBS || true
JOBS="${JOBS:-1}"
[[ "$JOBS" =~ ^[0-9]+$ ]] || die "Invalid worker count: $JOBS"
JOBS_ARGS=()
[[ "$JOBS" -gt 1 ]] && JOBS_ARGS+=(-j "$JOBS")

# Dry run
echo ""
DRY_RUN=false
if prompt_yn "Dry run? (show plan only — no changes made)" n; then
    DRY_RUN=true
    warn "Dry-run mode: no restore will be performed."
fi

# ══════════════════════════════════════════════════════════════
#  Target database
# ══════════════════════════════════════════════════════════════
section "Step 7 of 7 — Target Database"

read -rp "  Restore into database name [$DATABASE]: " TARGET_DB || true
TARGET_DB="${TARGET_DB:-$DATABASE}"

if [[ "$DRY_RUN" == "false" ]]; then
    if db_exists "$TARGET_DB"; then
        warn "Database '${TARGET_DB}' already exists."
        echo ""
        echo "    [1]  Drop and recreate  (clean slate)"
        echo "    [2]  Keep existing      (restore will overwrite matching objects)"
        echo ""
        read -rp "  Choose [1/2, Enter=2]: " DBEXISTS_CHOICE || true
        if [[ "${DBEXISTS_CHOICE:-2}" == "1" ]]; then
            log "Dropping '${TARGET_DB}'..."
            log "Dropping '${TARGET_DB}' (user=${PG_USER} host=${PG_HOST}:${PG_PORT})..."
            psql_exec -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres \
                -c "DROP DATABASE \"${TARGET_DB}\""
            log "Creating '${TARGET_DB}' (user=${PG_USER} host=${PG_HOST}:${PG_PORT})..."
            psql_exec -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres \
                -c "CREATE DATABASE \"${TARGET_DB}\""
        else
            log "Keeping existing database."
        fi
    else
        log "Database '${TARGET_DB}' does not exist — creating (user=${PG_USER} host=${PG_HOST}:${PG_PORT})..."
        # psql_exec -U "$PG_USER" -h "$PG_HOST" -p "$PG_PORT" -d postgres \
        #     -c "CREATE DATABASE \"${TARGET_DB}\""
    fi
fi

# ══════════════════════════════════════════════════════════════
#  Assemble restore arguments
# ══════════════════════════════════════════════════════════════
RESTORE_ARGS=(
    -U "$PG_USER"
    -h "$PG_HOST"
    -p "$PG_PORT"
    -d "$TARGET_DB"
    -v
)

if [[ ${#CLEAN_ARGS[@]}  -gt 0 ]]; then RESTORE_ARGS+=("${CLEAN_ARGS[@]}");  fi
if [[ ${#SCOPE_ARGS[@]}  -gt 0 ]]; then RESTORE_ARGS+=("${SCOPE_ARGS[@]}");  fi
if [[ ${#SCHEMA_ARGS[@]} -gt 0 ]]; then RESTORE_ARGS+=("${SCHEMA_ARGS[@]}"); fi
if [[ ${#TABLE_ARGS[@]}  -gt 0 ]]; then RESTORE_ARGS+=("${TABLE_ARGS[@]}");  fi
if [[ ${#JOBS_ARGS[@]}   -gt 0 ]]; then RESTORE_ARGS+=("${JOBS_ARGS[@]}");   fi
if [[ "$RESTORE_NO_OWNER" == "true" ]]; then
    RESTORE_ARGS+=(--no-owner --no-privileges)
fi

# ══════════════════════════════════════════════════════════════
#  Final summary + confirmation
# ══════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ┌─────────────────────────────────────────────┐"
echo "  │              RESTORE SUMMARY                │"
echo "  └─────────────────────────────────────────────┘"
echo -e "${RESET}"

SUMMARY_SCHEMAS="${SELECTED_SCHEMA_NAMES[*]:-all}"
SUMMARY_SCOPE="full"
[[ "${SCOPE_CHOICE:-1}" == "2" ]] && SUMMARY_SCOPE="schema only"
[[ "${SCOPE_CHOICE:-1}" == "3" ]] && SUMMARY_SCOPE="data only"
SUMMARY_CLEAN="no (append)"
[[ ${#CLEAN_ARGS[@]} -gt 0 ]] && SUMMARY_CLEAN="yes (--clean --if-exists)"

printf "  %-20s %s\n"  "Source file:"    "$(basename "$BACKUP_FILE")"
printf "  %-20s %s\n"  "Target DB:"      "$TARGET_DB"
printf "  %-20s %s\n"  "Schemas:"        "$SUMMARY_SCHEMAS"
if [[ ${#TABLE_ARGS[@]} -gt 0 ]]; then
    printf "  %-20s %s\n" "Tables:"      "${TABLE_ARGS[*]}"
fi
printf "  %-20s %s\n"  "Scope:"          "$SUMMARY_SCOPE"
printf "  %-20s %s\n"  "Drop first:"     "$SUMMARY_CLEAN"
printf "  %-20s %s\n"  "Workers:"        "$JOBS"
printf "  %-20s %s\n"  "No-owner mode:"  "$RESTORE_NO_OWNER"
printf "  %-20s %s\n"  "Dry run:"        "$DRY_RUN"
echo ""
echo -e "  ${DIM}Command: $pg_restore_cmd ${RESTORE_ARGS[*]}${RESET}"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    warn "Dry run complete. No changes were made."
    exit 0
fi

prompt_yn "Proceed with restore? This may be destructive." n \
    || { warn "Aborted by user."; exit 0; }

# ══════════════════════════════════════════════════════════════
#  Execute restore
# ══════════════════════════════════════════════════════════════
echo ""
info "Starting restore of '$(basename "$BACKUP_FILE")' → '${TARGET_DB}'..."
echo ""

if [[ "$BACKUP_FILE" == *.gz ]]; then
    log "Backup is gzipped — piping through gunzip..."
    gunzip -c "$BACKUP_FILE" | restore_stream "${RESTORE_ARGS[@]}"
else
    log "Streaming backup directly..."
    restore_stream "${RESTORE_ARGS[@]}" < "$BACKUP_FILE"
fi

# ══════════════════════════════════════════════════════════════
#  Post-restore stats
# ══════════════════════════════════════════════════════════════
section "Post-Restore Report"

TABLE_COUNT=$(psql_count "$TARGET_DB" \
    "SELECT COUNT(*) FROM information_schema.tables
     WHERE table_schema NOT IN ('pg_catalog','information_schema')")

SEQ_COUNT=$(psql_count "$TARGET_DB" \
    "SELECT COUNT(*) FROM information_schema.sequences
     WHERE sequence_schema NOT IN ('pg_catalog','information_schema')")

VIEW_COUNT=$(psql_count "$TARGET_DB" \
    "SELECT COUNT(*) FROM information_schema.views
     WHERE table_schema NOT IN ('pg_catalog','information_schema')")

printf "  %-22s %s\n" "Tables restored:"    "$TABLE_COUNT"
printf "  %-22s %s\n" "Sequences restored:" "$SEQ_COUNT"
printf "  %-22s %s\n" "Views restored:"     "$VIEW_COUNT"

if [[ ${#SELECTED_SCHEMA_NAMES[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${BOLD}Tables per schema:${RESET}"
    for RSCHEMA in "${SELECTED_SCHEMA_NAMES[@]}"; do
        CNT=$(psql_count "$TARGET_DB" \
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${RSCHEMA}'")
        printf "    %-28s %s tables\n" "$RSCHEMA" "$CNT"
    done
fi

echo ""
ok "═══════════════════════════════════════════════"
ok " RESTORE COMPLETE → ${TARGET_DB}"
ok "═══════════════════════════════════════════════"
