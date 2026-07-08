#!/usr/bin/env bash

set -euo pipefail

HOME_DIR="${HOME:-$(eval echo ~$(whoami))}"
ENV_FILE="${HOME_DIR}/config/.env"

# Fail early if the configuration file is missing or unreadable
if [ ! -r "$ENV_FILE" ]; then
    echo "Error: Cannot read configuration file: $ENV_FILE" >&2
    exit 1
fi

# Load configuration
set -a
source "$ENV_FILE"
set +a

# Defaults
COMMIT_DELAY="${COMMIT_DELAY:-30}"

# Validate configuration
if [ -z "${REPO_PATHS+x}" ] || [ ${#REPO_PATHS[@]} -eq 0 ]; then
    echo "Error: REPO_PATHS is not defined or is empty in $ENV_FILE" >&2
    exit 1
fi

# Ensure required commands exist
for cmd in git inotifywait flock; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required command '$cmd' is not installed." >&2
        exit 1
    fi
done

sync_repo() {
    local repo="$1"

    (
        flock -n 200 || {
            echo "Git operation already running for $repo, skipping."
            exit 0
        }

        cd "$repo" || exit 1

        # Remove stale git lock if no git process is active
        if [ -f .git/index.lock ] && ! pgrep -f "git .*${repo}" >/dev/null 2>&1; then
            rm -f .git/index.lock
        fi

        # Stage everything (handles creates, updates, deletes, renames)
        git add -A

        # Nothing changed
        git diff --cached --quiet && exit 0

        local branch timestamp
        branch="$(git branch --show-current)"
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

        echo "[$timestamp] Changes detected in $repo"

        if git commit -m "Auto backup $timestamp"; then
            if git push origin "$branch"; then
                echo "[$timestamp] Pushed $repo ($branch)"
            else
                echo "[$timestamp] Push failed for $repo ($branch)" >&2
            fi
        fi

    ) 200>"${repo}/.git/autocommit.lock"
}

watch_repo() {
    local repo="$1"

    if [ ! -d "$repo" ]; then
        echo "Skipping $repo (directory does not exist)"
        return
    fi

    if [ ! -d "$repo/.git" ]; then
        echo "Skipping $repo (not a Git repository)"
        return
    fi

    echo "Watching $repo"

    (
        cd "$repo" || exit 1

        # Trust repository if needed
        git config --global --add safe.directory "$repo" >/dev/null 2>&1 || true

        # Remove stale lock files
        rm -f .git/index.lock .git/autocommit.lock

        # Initial scan and sync on startup
        sync_repo "$repo"

        while true; do
            if ! inotifywait -qq -r \
                -e modify,create,delete,move \
                --exclude '(^|/)\.git(/|$)' \
                .; then
                echo "inotifywait failed for $repo. Retrying in 10 seconds..."
                sleep 10
                continue
            fi

            # Allow bursts of file activity to settle
            sleep "$COMMIT_DELAY"

            sync_repo "$repo"
        done
    ) &
}

# Start one watcher per repository
for repo in "${REPO_PATHS[@]}"; do
    watch_repo "$repo"
done

wait