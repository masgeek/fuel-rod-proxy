#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Logging
###############################################################################

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $*" >&2
}

###############################################################################
# Configuration
###############################################################################

HOME_DIR="${HOME:-$(eval echo ~$(whoami))}"
ENV_FILE="${HOME_DIR}/config/.env"

if [ ! -r "$ENV_FILE" ]; then
    log "ERROR: Cannot read configuration file: $ENV_FILE"
    exit 1
fi

log "Loading configuration from $ENV_FILE"

set -a
source "$ENV_FILE"
set +a

COMMIT_DELAY="${COMMIT_DELAY:-30}"

if [ -z "${REPO_PATHS+x}" ] || [ ${#REPO_PATHS[@]} -eq 0 ]; then
    log "ERROR: REPO_PATHS is not defined or is empty."
    exit 1
fi

###############################################################################
# Dependency checks
###############################################################################

for cmd in git inotifywait flock; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR: Required command '$cmd' is not installed."
        exit 1
    fi
done

###############################################################################
# Repository Synchronization
###############################################################################

sync_repo() {
    local repo="$1"

    if [ ! -d "$repo/.git" ]; then
        log "[$repo] Not a Git repository. Skipping sync."
        return
    fi

    (
        flock -n 200 || {
            log "[$repo] Sync already in progress. Skipping."
            exit 0
        }

        cd "$repo" || {
            log "[$repo] Failed to change directory."
            exit 1
        }

        log "[$repo] Starting repository sync"

        # Trust repository if needed
        git config --global --add safe.directory "$repo" >/dev/null 2>&1 || true

        # Remove stale Git lock if no git process is active
        if [ -f .git/index.lock ]; then
            if ! pgrep -f "git .*${repo}" >/dev/null 2>&1; then
                log "[$repo] Removing stale .git/index.lock"
                rm -f .git/index.lock
            else
                log "[$repo] Active Git process detected. Deferring sync."
                exit 0
            fi
        fi

        log "[$repo] Staging changes"
        git add -A

        if git diff --cached --quiet; then
            log "[$repo] No changes detected"
            exit 0
        fi

        local branch timestamp
        branch="$(git branch --show-current)"
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

        log "[$repo] Changes detected on branch '$branch'"
        log "[$repo] Creating commit"

        if git commit -m "Auto backup $timestamp"; then
            log "[$repo] Commit successful"

            log "[$repo] Pushing to origin/$branch"

            if git push origin "$branch"; then
                log "[$repo] Push successful"
            else
                log "[$repo] ERROR: Push failed"
            fi
        else
            log "[$repo] ERROR: Commit failed"
        fi

        log "[$repo] Repository sync completed"

    ) 200>"${repo}/.git/autocommit.lock"
}

###############################################################################
# Initial Repository Scan
###############################################################################

initial_sync_repo() {
    local repo="$1"

    log "[$repo] Performing startup scan"

    sync_repo "$repo"

    log "[$repo] Startup scan complete"
}

###############################################################################
# Repository Watcher
###############################################################################

watch_repo() {
    local repo="$1"

    if [ ! -d "$repo" ]; then
        log "Skipping '$repo' (directory does not exist)"
        return
    fi

    if [ ! -d "$repo/.git" ]; then
        log "Skipping '$repo' (not a Git repository)"
        return
    fi

    (
        cd "$repo" || exit 1

        log "Watching repository: $repo"

        # Trust repository if needed
        git config --global --add safe.directory "$repo" >/dev/null 2>&1 || true

        # Remove stale locks from previous runs
        rm -f .git/index.lock .git/autocommit.lock

        while true; do
            log "[$repo] Waiting for filesystem events"

            if ! inotifywait \
                -qq \
                -r \
                -e modify,create,delete,move \
                --exclude '(^|/)\.git(/|$)' \
                .; then

                log "[$repo] ERROR: inotifywait failed. Retrying in 10 seconds."
                sleep 10
                continue
            fi

            log "[$repo] Filesystem event detected"
            log "[$repo] Waiting ${COMMIT_DELAY}s for changes to settle"

            sleep "$COMMIT_DELAY"

            sync_repo "$repo"
        done
    ) &
}

###############################################################################
# Main
###############################################################################

log "Starting auto-git-backup service"

for repo in "${REPO_PATHS[@]}"; do
    log "Initializing repository: $repo"

    initial_sync_repo "$repo"

    log "Starting watcher for $repo"
    watch_repo "$repo"
done

log "All repository watchers started"

wait