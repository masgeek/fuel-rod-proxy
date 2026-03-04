#!/bin/bash
# database-backup-postgres.sh
# Interactive PostgreSQL backup wizard (falls back to non-interactive when piped/cron)
set -euo pipefail

# ══════════════════════════════════════════════════════════════
#  Terminal colours  (auto-disabled when not a TTY)
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
user="${PG_USERNAME:-postgres}"
pass="${PG_PASSWORD:-}"
host="${PG_HOST:-127.0.0.1}"
port="${PG_PORT:-5432}"
service="${SERVICE:-postgres}"
use_docker="${USE_DOCKER:-true}"
compress="${COMPRESS_FILE:-false}"
days_to_keep=7
backup_all_databases=true
base_dir="${BASE_DIR:-$SCRIPT_DIR/db-backup}"
databases=""
selected_schemas=""
exclude_schemas=""
interactive_mode=false
system_schemas=(pg_catalog information_schema pg_toast pg_temp)

# Per-DB schema maps (populated by wizard)
declare -A SCHEMA_INCLUDES=()
declare -A SCHEMA_EXCLUDES=()

# ══════════════════════════════════════════════════════════════
#  Parse CLI arguments
# ══════════════════════════════════════════════════════════════
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)          shift; user="$1" ;;
        -p|--pass)          shift; pass="$1" ;;
        -H|--host)          shift; host="$1" ;;
        --port)             shift; port="$1" ;;
        -s|--service)       shift; service="$1" ;;
        -db|--databases)    shift; databases="$1"; backup_all_databases=false ;;
        --schemas)          shift; selected_schemas="$1" ;;
        --exclude)          shift; exclude_schemas="$1" ;;
        --docker)           use_docker=true ;;
        --no-docker)        use_docker=false ;;
        --compress)         compress=true ;;
        --keep-days)        shift; days_to_keep="$1" ;;
        --all-databases)    backup_all_databases=true ;;
        -i|--interactive)   interactive_mode=true ;;
        *) die "Unknown argument: $1. Use -i for interactive mode." ;;
    esac
    shift
done

# Auto-enable interactive wizard when running in a real terminal with no targeting args
if [[ -t 0 && -t 1 && -z "$databases" && -z "$selected_schemas" && "$backup_all_databases" == "true" ]]; then
    interactive_mode=true
fi

# ══════════════════════════════════════════════════════════════
#  Low-level helpers
# ══════════════════════════════════════════════════════════════
psql_exec() {
    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" psql "$@"
    else
        PGPASSWORD="$pass" psql "$@"
    fi
}

dump_exec() {
    if [[ "$use_docker" == "true" ]]; then
        docker exec -e PGPASSWORD="$pass" "$service" pg_dump "$@"
    else
        PGPASSWORD="$pass" pg_dump "$@"
    fi
}

get_all_databases() {
    psql_exec -U "$user" -h "$host" -p "$port" -d postgres -At \
        -c "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
}

get_db_size() {
    psql_exec -U "$user" -h "$host" -p "$port" -d postgres -At \
        -c "SELECT pg_size_pretty(pg_database_size('$1'))" 2>/dev/null || echo "?"
}

get_user_schemas() {
    psql_exec -U "$user" -h "$host" -p "$port" -d "$1" -At \
        -c "SELECT nspname FROM pg_namespace
            WHERE nspname NOT LIKE 'pg_%' AND nspname <> 'information_schema'
            ORDER BY nspname" 2>/dev/null || true
}

check_connection() {
    log "Testing connection → ${host}:${port} (user: $user, docker: $use_docker)..."
    psql_exec -U "$user" -h "$host" -p "$port" -d postgres -c "SELECT 1" -q >/dev/null 2>&1 \
        || die "Cannot reach PostgreSQL at ${host}:${port} as '$user'. Check .backup credentials."
    ok "Connection OK."
}

# ══════════════════════════════════════════════════════════════
#  Interactive prompt helpers
# ══════════════════════════════════════════════════════════════
prompt_default() {
    # Usage: val=$(prompt_default "Label" "default")
    local label="$1" default="$2" ans
    read -rp "  ${label} [${default}]: " ans || true
    echo "${ans:-$default}"
}

prompt_yn() {
    # Returns 0 (yes) or 1 (no).  default: "y" or "n"
    local prompt="$1" default="${2:-y}" ans
    local hint; [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    read -rp "  ${prompt} ${hint}: " ans || true
    ans="${ans:-$default}"
    [[ "${ans,,}" == "y" ]]
}


# ══════════════════════════════════════════════════════════════
#  Interactive wizard
# ══════════════════════════════════════════════════════════════
run_wizard() {
    section "PostgreSQL Backup Wizard"

    # ── Connection ───────────────────────────────────────────
    echo -e "  ${BOLD}Connection${RESET}  (Enter to accept defaults)"
    echo ""

    if [[ "$use_docker" == "true" ]]; then
        echo -e "  Mode    : ${CYAN}Docker${RESET} — service '${service}'"
        echo -e "  ${DIM}(set USE_DOCKER=false in .backup to connect directly)${RESET}"
    else
        host=$(prompt_default "Host" "$host")
        port=$(prompt_default "Port" "$port")
    fi

    user=$(prompt_default "Username" "$user")

    local pass_hint; [[ -n "$pass" ]] && pass_hint="***set***" || pass_hint="not set"
    local new_pass
    read -rsp "  Password [${pass_hint}]: " new_pass || true; echo ""
    [[ -n "$new_pass" ]] && pass="$new_pass"
    [[ -z "$pass" ]] && die "Password is required."

    check_connection

    # ── Database selection ───────────────────────────────────
    section "Select Databases"

    mapfile -t ALL_DBS < <(get_all_databases)
    [[ ${#ALL_DBS[@]} -eq 0 ]] && die "No databases found on server."

    echo -e "  ${BOLD}Available databases:${RESET}"
    echo ""
    for i in "${!ALL_DBS[@]}"; do
        local sz; sz=$(get_db_size "${ALL_DBS[$i]}")
        printf "    [%2d]  %-30s  %s\n" "$i" "${ALL_DBS[$i]}" "$sz"
    done
    echo ""

    local db_sel
    read -rp "  Databases to back up (indices, comma-sep; Enter = all): " db_sel || true
    db_sel="${db_sel:-ALL}"

    declare -a SELECTED_DBS=()
    if [[ "$db_sel" == "ALL" ]]; then
        SELECTED_DBS=("${ALL_DBS[@]}")
        backup_all_databases=true
    else
        backup_all_databases=false
        IFS=',' read -ra IDXS <<< "$db_sel"
        for idx in "${IDXS[@]}"; do
            idx="${idx// /}"
            [[ "$idx" =~ ^[0-9]+$ ]] || die "Invalid index: $idx"
            (( idx < ${#ALL_DBS[@]} )) || die "Index out of range: $idx"
            SELECTED_DBS+=("${ALL_DBS[$idx]}")
        done
    fi

    # ── Schema selection per DB ──────────────────────────────
    for db in "${SELECTED_DBS[@]}"; do
        section "Schema Selection — ${db}"

        mapfile -t DB_SCHEMAS < <(get_user_schemas "$db")

        if [[ ${#DB_SCHEMAS[@]} -eq 0 ]]; then
            log "No user schemas found in '$db' — will back up entire database."
            continue
        fi

        echo -e "  ${BOLD}Schemas in ${db}:${RESET}"
        echo ""
        echo "  [1] All schemas  (default)"
        echo "  [2] Include specific schemas only"
        echo "  [3] Exclude specific schemas"
        echo ""
        local sc_choice
        read -rp "  Choose [1/2/3, Enter=1]: " sc_choice || true
        sc_choice="${sc_choice:-1}"

        case "$sc_choice" in
            1) ;;  # no filter — leave maps empty
            2)
                echo ""
                echo -e "  ${BOLD}Available schemas:${RESET}"
                for i in "${!DB_SCHEMAS[@]}"; do printf "    [%2d] %s\n" "$i" "${DB_SCHEMAS[$i]}"; done
                local incl_sel
                read -rp "  Indices to include (comma-sep): " incl_sel || true
                local incl_names=()
                IFS=',' read -ra INCL_IDXS <<< "$incl_sel"
                for idx in "${INCL_IDXS[@]}"; do
                    idx="${idx// /}"
                    [[ "$idx" =~ ^[0-9]+$ ]] || die "Invalid index: $idx"
                    (( idx < ${#DB_SCHEMAS[@]} )) || die "Index out of range: $idx"
                    incl_names+=("${DB_SCHEMAS[$idx]}")
                done
                SCHEMA_INCLUDES["$db"]=$(IFS=','; echo "${incl_names[*]}")
                ;;
            3)
                echo ""
                echo -e "  ${BOLD}Available schemas:${RESET}"
                for i in "${!DB_SCHEMAS[@]}"; do printf "    [%2d] %s\n" "$i" "${DB_SCHEMAS[$i]}"; done
                local excl_sel
                read -rp "  Indices to exclude (comma-sep): " excl_sel || true
                local excl_names=()
                IFS=',' read -ra EXCL_IDXS <<< "$excl_sel"
                for idx in "${EXCL_IDXS[@]}"; do
                    idx="${idx// /}"
                    [[ "$idx" =~ ^[0-9]+$ ]] || die "Invalid index: $idx"
                    (( idx < ${#DB_SCHEMAS[@]} )) || die "Index out of range: $idx"
                    excl_names+=("${DB_SCHEMAS[$idx]}")
                done
                SCHEMA_EXCLUDES["$db"]=$(IFS=','; echo "${excl_names[*]}")
                ;;
            *) die "Invalid choice: $sc_choice" ;;
        esac
    done

    # ── Options ──────────────────────────────────────────────
    section "Backup Options"

    local default_compress; [[ "$compress" == "true" ]] && default_compress="y" || default_compress="n"
    if prompt_yn "Compress output with gzip?" "$default_compress"; then
        compress=true
    else
        compress=false
    fi

    days_to_keep=$(prompt_default "Keep backups for N days (0 = forever)" "$days_to_keep")
    base_dir=$(prompt_default "Output directory" "$base_dir")

    # ── Summary + confirm ─────────────────────────────────────
    section "Summary"

    echo -e "  ${BOLD}Databases   :${RESET} ${SELECTED_DBS[*]}"
    echo -e "  ${BOLD}Compress    :${RESET} $compress"
    echo -e "  ${BOLD}Retention   :${RESET} $days_to_keep days"
    echo -e "  ${BOLD}Output dir  :${RESET} $base_dir"
    for db in "${!SCHEMA_INCLUDES[@]}"; do
        echo -e "  ${BOLD}  ${db} include:${RESET} ${SCHEMA_INCLUDES[$db]}"
    done
    for db in "${!SCHEMA_EXCLUDES[@]}"; do
        echo -e "  ${BOLD}  ${db} exclude:${RESET} ${SCHEMA_EXCLUDES[$db]}"
    done
    echo ""

    prompt_yn "Proceed with backup?" y || { log "Aborted by user."; exit 0; }

    # Store selected DBs as comma-sep for main loop
    databases=$(IFS=','; echo "${SELECTED_DBS[*]}")
    backup_all_databases=false
}

# ══════════════════════════════════════════════════════════════
#  Backup one database
# ══════════════════════════════════════════════════════════════
backup_database() {
    local db="$1"
    local db_dir="$base_dir/$db"
    mkdir -p "$db_dir"

    local timestamp; timestamp="$(date +%Y%m%d_%H%M%S)"
    local dump_file="$db_dir/${db}_${timestamp}.dump"
    local manifest="$db_dir/manifest_${timestamp}.txt"

    info "Backing up: ${BOLD}$db${RESET}"

    # Resolve schema args
    declare -a schema_args=()
    local incl="${SCHEMA_INCLUDES[$db]:-}"
    local excl="${SCHEMA_EXCLUDES[$db]:-}"

    # CLI flags override wizard (wizard already populated global maps)
    [[ -z "$incl" && -n "$selected_schemas" ]] && incl="$selected_schemas"
    [[ -z "$excl" && -n "$exclude_schemas" ]]  && excl="$exclude_schemas"

    if [[ -n "$incl" ]]; then
        IFS=',' read -ra arr <<< "$incl"
        for s in "${arr[@]}"; do schema_args+=("-n" "$s"); done
    else
        local excl_list=()
        [[ -n "$excl" ]] && IFS=',' read -ra excl_list <<< "$excl"
        for s in "${excl_list[@]}" "${system_schemas[@]}"; do
            schema_args+=("-N" "$s")
        done
    fi

    # Write manifest
    {
        echo "Database  : $db"
        echo "Timestamp : $timestamp"
        echo "Host      : ${host}:${port}"
        echo "User      : $user"
        echo "Docker    : $use_docker"
        echo "Format    : custom"
        [[ -n "$incl" ]] && echo "Included  : $incl"
        [[ -n "$excl" ]] && echo "Excluded  : $excl"
        echo "Compressed: $compress"
    } > "$manifest"

    # Run pg_dump (stdout → host file; Docker-safe)
    if [[ ${#schema_args[@]} -gt 0 ]]; then
        dump_exec -U "$user" -h "$host" -p "$port" -F c -b "${schema_args[@]}" "$db" > "$dump_file"
    else
        dump_exec -U "$user" -h "$host" -p "$port" -F c -b "$db" > "$dump_file"
    fi

    if [[ "$compress" == "true" ]]; then
        gzip -9 "$dump_file"
        dump_file="${dump_file}.gz"
    fi

    local size; size=$(du -sh "$dump_file" 2>/dev/null | cut -f1)
    ok "  → $(basename "$dump_file")  (${size})"
}

# ══════════════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════════════
if [[ "$interactive_mode" == "true" ]]; then
    run_wizard
fi

[[ -z "$pass" ]] && die "PG_PASSWORD is required. Set it in .backup or pass -p."
mkdir -p "$base_dir"

# Build final DB list
declare -a databases_to_backup=()
if [[ "$backup_all_databases" == "true" ]]; then
    mapfile -t databases_to_backup < <(get_all_databases)
elif [[ -n "$databases" ]]; then
    IFS=',' read -ra databases_to_backup <<< "$databases"
else
    die "Nothing to back up. Use --all-databases, --databases <list>, or run interactively."
fi

[[ ${#databases_to_backup[@]} -eq 0 ]] && die "No databases found to back up."

# Validate connection (wizard already did this; skip to avoid double check)
[[ "$interactive_mode" != "true" ]] && check_connection

section "Running Backup"
for db in "${databases_to_backup[@]}"; do
    backup_database "$db"
done

# Cleanup old backups
if [[ "$days_to_keep" -gt 0 ]]; then
    log "Removing backups older than ${days_to_keep} days..."
    find "$base_dir" -type f \( -name "*.dump" -o -name "*.dump.gz" -o -name "manifest_*.txt" \) \
        -mtime "+${days_to_keep}" -delete
fi

ok "═══════════════════════════════════"
ok " BACKUP COMPLETE"
ok "═══════════════════════════════════"
