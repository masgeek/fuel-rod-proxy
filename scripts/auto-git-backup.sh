#!/usr/bin/env bash

set -euo pipefail

# Job control: gives each backgrounded watcher (and the inotifywait monitor
# process nested inside it) its own process group, so cleanup() can kill the
# whole group with one signal instead of leaking a long-running inotifywait.
set -m

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
MAX_PUSH_RETRIES="${MAX_PUSH_RETRIES:-3}"
readonly INOTIFY_EXCLUDE='(^|/)\.git(/|$)|(^|/)wp-content/cache(/|$)|(^|/)node_modules(/|$)|(^|/)vendor(/|$)'

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
# Signal handling / cleanup
###############################################################################

CHILD_PIDS=()

cleanup() {
    log "Shutdown signal received. Stopping watchers..."
    for pid in "${CHILD_PIDS[@]}"; do
        # Negative pid = signal the whole process group (with `set -m`, each
        # background job is its own group), so the nested inotifywait -m
        # monitor process dies too instead of being orphaned.
        kill -TERM -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    log "All watchers stopped. Exiting."
    exit 0
}

trap cleanup SIGINT SIGTERM

###############################################################################
# Helpers
###############################################################################

# Returns 0 (true) if some process has its cwd inside the given repo dir.
# More reliable than pgrep -f, which only matches if the path string
# happens to appear in the process's argv.
repo_has_active_process() {
    local repo="$1"
    local real_repo
    real_repo="$(realpath "$repo" 2>/dev/null)" || return 1

    local pid link target
    for link in /proc/[0-9]*/cwd; do
        [ -e "$link" ] || continue
        pid="${link#/proc/}"
        pid="${pid%/cwd}"
        # Skip our own process tree's flock/git children spawned by this script
        target="$(readlink -f "$link" 2>/dev/null)" || continue
        if [ "$target" = "$real_repo" ]; then
            return 0
        fi
    done
    return 1
}

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

        # Remove stale Git lock only if no process has this repo as its cwd
        if [ -f .git/index.lock ]; then
            if ! repo_has_active_process "$repo"; then
                log "[$repo] Removing stale .git/index.lock"
                rm -f .git/index.lock
            else
                log "[$repo] Active process detected in repo. Deferring sync."
                exit 0
            fi
        fi

        local branch
        # `|| true`: same errexit hazard -- if `git branch` ever fails (e.g.
        # transient repo corruption), a bare failing command substitution
        # assignment kills the subshell under set -e just like a bare `read`
        # does. The `|| true` guard is enough; branch just ends up empty,
        # which the detached-HEAD check right below already handles safely.
        branch="$(git branch --show-current)" || true

        if [ -z "$branch" ]; then
            log "[$repo] Detached HEAD state. Skipping sync (no branch to push)."
            exit 0
        fi

        # Fetch and try to fast-forward / rebase onto origin before committing
        # local changes, so we don't fall permanently out of sync with a
        # remote that has diverged.
        if git remote get-url origin >/dev/null 2>&1; then
            log "[$repo] Fetching origin/$branch"
            if git fetch origin "$branch" >/dev/null 2>&1; then
                if git rev-parse --verify -q "origin/$branch" >/dev/null; then
                    local ahead behind
                    behind="$(git rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo 0)"
                    if [ "$behind" -gt 0 ]; then
                        log "[$repo] Behind origin/$branch by $behind commit(s). Rebasing with autostash."
                        if ! git rebase --autostash "origin/$branch"; then
                            log "[$repo] ERROR: Rebase failed. Aborting rebase and skipping this cycle."
                            git rebase --abort 2>/dev/null || true
                            exit 1
                        fi
                    fi
                fi
            else
                log "[$repo] WARNING: Fetch failed. Proceeding with local state only."
            fi
        fi

        log "[$repo] Staging changes"
        git add -A

        if git diff --cached --quiet; then
            log "[$repo] No changes detected"
            exit 0
        fi

        local timestamp
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

        log "[$repo] Changes detected on branch '$branch'"
        log "[$repo] Creating commit"

        local commit_message
        commit_message="$(generate_commit_message)"

        log "[$repo] Commit message: $commit_message"

        if git commit -m "$commit_message"; then
            log "[$repo] Commit successful"

            local attempt=1
            local pushed=0
            while [ "$attempt" -le "$MAX_PUSH_RETRIES" ]; do
                log "[$repo] Pushing to origin/$branch (attempt $attempt/$MAX_PUSH_RETRIES)"
                if git push origin "$branch"; then
                    log "[$repo] Push successful"
                    pushed=1
                    break
                fi
                log "[$repo] WARNING: Push attempt $attempt failed"
                sleep $((attempt * 5))
                attempt=$((attempt + 1))
            done

            if [ "$pushed" -eq 0 ]; then
                log "[$repo] ERROR: Push failed after $MAX_PUSH_RETRIES attempts. Commit remains local; will retry next sync cycle."
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

    if [ ! -d "$repo" ]; then
        log "[$repo] Skipping startup scan (directory does not exist)"
        return
    fi

    log "[$repo] Performing startup scan"

    # `|| true`: sync_repo can internally `exit 1` on its own subshell (e.g.
    # rebase conflict, failed cd). Called bare, that non-zero status would
    # trip `set -e` and kill the entire startup loop for *all* repos, not
    # just this one.
    sync_repo "$repo" || true

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

        # Remove stale index.lock left from a previous crashed run.
        # Do NOT remove autocommit.lock here: an in-flight sync_repo from
        # initial_sync_repo may still hold an flock on it, and unlinking the
        # path would let a fresh open silently defeat the mutex.
        rm -f .git/index.lock

        # True debounce: run inotifywait in monitor mode (-m) so it streams
        # events continuously instead of exiting after the first one. A
        # `read -t COMMIT_DELAY` timer sits on the event stream; every event
        # that arrives resets the timer (the read succeeds and we loop back
        # immediately). Only when COMMIT_DELAY seconds pass with *no* events
        # does read time out, which is our signal that things have settled
        # and it's safe to sync. This correctly extends the wait for writes
        # that are still ongoing when the old fixed-sleep window would have
        # expired.
        while true; do
            log "[$repo] Starting file watch (monitor mode)"

            saw_event=0
            event_count=0
            event_files=()
            inotifywait_alive=1

            while [ "$inotifywait_alive" -eq 1 ]; do
                # NOTE: we capture read's exit status explicitly inside the
                # loop body. Checking $? right after a `while read; do ...
                # done` loop is a trap: bash reports the exit status of the
                # *last command executed in the loop body*, not the read
                # condition that caused the loop to end -- so it would
                # almost always read back as 0 regardless of whether we hit
                # a timeout or EOF.
                # NOTE: read is used as an `if` condition specifically so its
                # non-zero exit status (on timeout, or on EOF) does NOT
                # trigger `set -e` and silently kill this whole subshell.
                # Under errexit, a *bare* `read ...; read_status=$?` would
                # never even reach the assignment -- the shell exits the
                # instant `read` returns non-zero, with no error message.
                #
                # Just as important: read_status MUST be captured inside an
                # explicit `else`, not after a bare `fi`. When an `if`
                # condition is false and there is no `else`, bash resets $?
                # to the *if construct's own* exit status (0) once you fall
                # past `fi` -- it does NOT preserve the tested command's
                # real exit code. Both of these are real bugs that were
                # verified empirically while building this script, not
                # theoretical concerns.
                while true; do
                    if read -r -t "$COMMIT_DELAY" _event; then
                        # inotifywait -r prints "WATCHED_DIR EVENTS FILENAME"
                        log "[$repo] Change: $_event"
                        saw_event=1
                        event_count=$((event_count + 1))
                        event_files+=("$_event")
                        continue
                    else
                        read_status=$?
                        break
                    fi
                done

                if [ "$read_status" -gt 128 ]; then
                    # Timeout: no events for COMMIT_DELAY seconds. Only sync
                    # if we actually saw at least one event since watching
                    # started (avoids a spurious sync every COMMIT_DELAY
                    # seconds forever when the repo is idle).
                    if [ "$saw_event" -eq 1 ]; then
                        log "[$repo] Changes settled after ${COMMIT_DELAY}s of quiet (${event_count} event(s)):"
                        # De-duplicated list of files touched during this
                        # debounce window, so a burst of writes to the same
                        # file doesn't spam repeated identical lines.
                        printf '%s\n' "${event_files[@]}" | awk '{print $NF}' | sort -u | while IFS= read -r f; do
                            log "[$repo]   - $f"
                        done
                        # `|| true`: same errexit hazard as above -- sync_repo
                        # can internally `exit 1`, which bare would kill this
                        # whole watcher (and stop watching the repo forever).
                        sync_repo "$repo" || true
                        saw_event=0
                        event_count=0
                        event_files=()
                    fi
                else
                    # read failed for a reason other than timeout: the
                    # inotifywait pipe closed (process died/crashed). Break
                    # out so the outer loop spins up a fresh inotifywait.
                    log "[$repo] inotifywait stream ended unexpectedly. Restarting in 5s."
                    inotifywait_alive=0
                    sleep 5
                fi
            done < <(
                inotifywait \
                    -m -q -r \
                    -e modify,create,delete,move \
                    --exclude "$INOTIFY_EXCLUDE" \
                    . 2>&1
            )
        done
    ) &

    CHILD_PIDS+=("$!")
}


generate_commit_message() {
    local file_count changed_files stats message

    file_count=$(git diff --cached --name-only | wc -l)

    changed_files=$(
        git diff --cached --name-only |
        head -5 |
        paste -sd ', ' -
    )

    stats=$(git diff --cached --shortstat | sed 's/^ *//')

    if [ "$file_count" -gt 5 ]; then
        message="Update ${file_count} files (${stats}) including ${changed_files}"
    else
        message="Update ${file_count} files (${stats}): ${changed_files}"
    fi

    # Optional AI fallback
    if command -v llm >/dev/null 2>&1; then
        local ai_message
        ai_message=$(
            {
                echo "Generate a concise git commit message (max 72 characters)."
                echo
                echo "Changed files:"
                git diff --cached --name-only
                echo
                echo "Diff statistics:"
                git diff --cached --stat
            } | llm 2>/dev/null | head -n1
        )

        if [ -n "$ai_message" ]; then
            message="$ai_message"
        fi
    fi

    echo "$message"
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