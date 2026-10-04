#!/usr/bin/env bash
# claude-rc-supervisor: keeps one `claude remote-control` process running for
# every git repository in WORK_DIR (up to 2 levels deep), restarts crashed
# ones, automatically picks up new repositories and drops removed ones.
#
# Compatible with the system bash 3.2 on macOS (no associative arrays etc.).
#
# Runs via launchd (see install.sh) or manually: ./supervisor.sh
set -u

# --- default configuration (override in CONFIG_FILE) ------------------------
CONFIG_FILE="${CLAUDE_RC_CONFIG:-$HOME/.claude-rc-supervisor.env}"

WORK_DIR="$HOME/work"
SCAN_INTERVAL=60
LOG_DIR="$HOME/Library/Logs/claude-rc-supervisor"
STATE_DIR="$HOME/.local/state/claude-rc-supervisor"
CLAUDE_BIN="$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")"
AUTO_TRUST=1            # auto-mark new repositories as trusted in ~/.claude.json
PERMISSION_MODE=""      # e.g. acceptEdits; empty = default
SERVE_NON_GIT=1         # serve non-git folders without nested repos (same-dir mode)
IGNORE_PATTERNS=""      # space-separated globs relative to WORK_DIR: "sandbox/* tmp-*"
SESSION_PREFIX="$(hostname -s 2>/dev/null)"  # machine label prepended to session names; empty = repo name only
MAX_LOG_BYTES=$((10 * 1024 * 1024))

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
# ---------------------------------------------------------------------------

mkdir -p "$LOG_DIR" "$STATE_DIR"

log() { echo "[$(date '+%F %T')] $*"; }

path_key() {
    local rel="${1#"$WORK_DIR"/}"
    echo "${rel%/}" | tr '/' '_'
}

is_ignored() {
    local rel="${1#"$WORK_DIR"/}" pat
    # set -f: keep unquoted $IGNORE_PATTERNS from expanding against the
    # supervisor's cwd — the patterns must reach `case` verbatim
    set -f
    for pat in $IGNORE_PATTERNS; do
        # shellcheck disable=SC2254
        case "$rel" in $pat) set +f; return 0 ;; esac
    done
    set +f
    return 1
}

# Prints "mode|/abs/path" lines. A git repository -> worktree mode.
# A folder without .git: if it contains repositories, serve those;
# otherwise (optionally) serve the folder itself in same-dir mode.
discover_repos() {
    local d s found
    for d in "$WORK_DIR"/*/; do
        d="${d%/}"
        [ -d "$d" ] || continue
        case "$(basename "$d")" in .*) continue ;; esac
        is_ignored "$d" && continue
        if [ -e "$d/.git" ]; then
            echo "worktree|$d"
        else
            found=0
            for s in "$d"/*/; do
                s="${s%/}"
                [ -e "$s/.git" ] || continue
                case "$(basename "$s")" in .*) continue ;; esac
                is_ignored "$s" && continue
                found=1
                echo "worktree|$s"
            done
            if [ "$found" -eq 0 ] && [ "$SERVE_NON_GIT" = "1" ]; then
                echo "same-dir|$d"
            fi
        fi
    done
}

# Remote Control requires an accepted trust dialog; for new repositories
# we set hasTrustDialogAccepted in ~/.claude.json ourselves.
ensure_trust() {
    local repo="$1" cfg="$HOME/.claude.json" tmp trusted
    [ "$AUTO_TRUST" = "1" ] || return 0
    [ -f "$cfg" ] || return 0
    command -v jq >/dev/null 2>&1 || { log "WARN: jq not found, auto-trust skipped for $repo"; return 0; }
    trusted=$(jq -r --arg p "$repo" '.projects[$p].hasTrustDialogAccepted // false' "$cfg")
    if [ "$trusted" != "true" ]; then
        log "auto-trust: $repo"
        tmp=$(mktemp "${TMPDIR:-/tmp}/claude-json.XXXXXX")
        if jq --arg p "$repo" \
            '.projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})' \
            "$cfg" > "$tmp"; then
            mv "$tmp" "$cfg"
        else
            rm -f "$tmp"
            log "WARN: failed to update $cfg"
        fi
    fi
}

rotate_log() {
    local f="$1" size
    [ -f "$f" ] || return 0
    size=$(stat -f %z "$f" 2>/dev/null || stat -c %s "$f" 2>/dev/null || echo 0)
    if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
        mv "$f" "$f.old"
    fi
}

server_running() {
    local pidfile="$1" pid
    [ -f "$pidfile" ] || return 1
    pid=$(cat "$pidfile" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    # guard against a reused PID after reboot
    ps -p "$pid" -o command= 2>/dev/null | grep -q "remote-control"
}

start_server() {
    local mode="$1" repo="$2" key name
    key=$(path_key "$repo")
    name=$(basename "$repo")
    ensure_trust "$repo"
    rotate_log "$LOG_DIR/$key.log"
    log "start [$mode] $repo"
    (
        cd "$repo" || exit 1
        exec "$CLAUDE_BIN" remote-control \
            --spawn "$mode" \
            --no-create-session-in-dir \
            --remote-control-session-name-prefix "${SESSION_PREFIX:+$SESSION_PREFIX-}$name" \
            ${PERMISSION_MODE:+--permission-mode "$PERMISSION_MODE"}
    ) < /dev/null >> "$LOG_DIR/$key.log" 2>&1 &
    echo $! > "$STATE_DIR/$key.pid"
}

# Stops a server and waits for it to exit; SIGKILL as a last resort
# (a freshly started process has been observed to survive a single SIGTERM).
stop_server() {
    local pidfile="$1" pid i
    pid=$(cat "$pidfile" 2>/dev/null)
    rm -f "$pidfile"
    [ -n "$pid" ] || return 0
    # never kill a PID that a stale pid file points at after it has been
    # reused by an unrelated process
    ps -p "$pid" -o command= 2>/dev/null | grep -q "remote-control" || return 0
    kill "$pid" 2>/dev/null || return 0
    for i in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
    done
    log "WARN: pid $pid did not exit on SIGTERM, sending SIGKILL"
    kill -9 "$pid" 2>/dev/null || true
}

cleanup() {
    log "supervisor: shutting down, stopping servers"
    local pidfile
    for pidfile in "$STATE_DIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        stop_server "$pidfile"
    done
    exit 0
}
trap cleanup TERM INT

log "supervisor: started (WORK_DIR=$WORK_DIR, interval=${SCAN_INTERVAL}s, config=$CONFIG_FILE)"

while :; do
    if [ ! -x "$CLAUDE_BIN" ]; then
        log "ERROR: claude not found at '$CLAUDE_BIN', retrying in 300s"
        sleep 300 & wait $!
        continue
    fi

    # the system bash on macOS is 3.2 with no associative arrays,
    # so the list of wanted servers is kept in a temporary file
    want_file=$(mktemp "${TMPDIR:-/tmp}/claude-rc-want.XXXXXX")
    while IFS='|' read -r mode repo; do
        [ -n "$repo" ] || continue
        key=$(path_key "$repo")
        echo "$key" >> "$want_file"
        server_running "$STATE_DIR/$key.pid" && continue
        start_server "$mode" "$repo"
    done < <(discover_repos)

    # a repository was removed or matched IGNORE_PATTERNS — stop its server
    for pidfile in "$STATE_DIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        key=$(basename "$pidfile" .pid)
        if ! grep -qxF "$key" "$want_file"; then
            log "stop $key (repository no longer in the list)"
            stop_server "$pidfile"
        fi
    done
    rm -f "$want_file"

    sleep "$SCAN_INTERVAL" & wait $!
done
