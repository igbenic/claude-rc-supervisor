#!/usr/bin/env bash
# claude-rc-supervisor: keeps one `claude remote-control` process running for
# every git repository in WORK_DIR (up to 2 levels deep), restarts crashed
# ones, automatically picks up new repositories and drops removed ones.
# Sessions orphaned by a server exit are reattached, and the Mac is kept
# from idle-sleeping while any session is active.
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
REATTACH=1              # reattach sessions orphaned when their server exits (sleep, network loss, restart)
REATTACH_WINDOW=14400   # seconds; the CLI only lets a session be reattached for ~4 hours
REATTACH_MAX_ATTEMPTS=5 # failed reattach attempts per session before giving up on it
KEEP_AWAKE=1            # hold `caffeinate -i` while any remote session is active
MAX_LOG_BYTES=$((10 * 1024 * 1024))

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
# ---------------------------------------------------------------------------

REATTACH_DIR="$STATE_DIR/reattach"
KEEP_AWAKE_FILE="$STATE_DIR/keep-awake.state"
# written to a server log right before the process starts, so log parsing
# never mistakes the previous process's output for the current one
START_MARK="--- claude-rc-supervisor: process start ---"

mkdir -p "$LOG_DIR" "$STATE_DIR" "$REATTACH_DIR"

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
        echo "$START_MARK $(date '+%F %T')"
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

# --- session self-healing ---------------------------------------------------
# When a server exits (the Mac slept and the network was gone for ~10 minutes,
# the supervisor restarted, ...) its sessions are left orphaned: the restarted
# server registers a new environment and never picks them up again. While a
# server runs we remember its active sessions from its log; once it is gone,
# each of them is reattached with `claude remote-control --session-id`.

file_age() {
    local m
    m=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null) || return 1
    echo $(( $(date +%s) - m ))
}

# Prints the session IDs listed in the newest status block of a server log
# (the "Capacity: N/32" line is followed by one link per active session).
active_sessions() {
    [ -f "$1" ] || return 0
    tail -c 65536 "$1" | tr -d '\033\007' | awk -v mark="$START_MARK" '
        index($0, mark) { n = 0; inblock = 0; next }
        /Capacity: [0-9]+\// { n = 0; inblock = 1; next }
        inblock && match($0, /claude\.ai\/code\/session_[A-Za-z0-9]+/) {
            ids[++n] = substr($0, RSTART + 15, RLENGTH - 15); next
        }
        { inblock = 0 }
        END { for (i = 1; i <= n; i++) print ids[i] }'
}

# True when the current process in this log is shutting down or gave up.
failed_since_start() {
    [ -f "$1" ] || return 1
    tail -c 65536 "$1" | awk -v mark="$START_MARK" '
        index($0, mark) { f = 0 }
        /Shutting down|giving up|Persistent errors/ { f = 1 }
        END { exit !f }'
}

# Directory a session runs in: its worktree, or the served folder itself.
session_cwd() {
    local mode="$1" repo="$2" sid="$3" wt
    wt="$repo/.claude/worktrees/bridge-cse_${sid#session_}"
    if [ "$mode" = "worktree" ] && [ -d "$wt" ]; then
        echo "$wt"
    else
        echo "$repo"
    fi
}

# Records the active sessions of a running server in <key>.sessions
# ("session_id|cwd" lines); the file is absent when there are none.
snapshot_sessions() {
    local mode="$1" repo="$2" key="$3" logf sid tmp
    logf="$LOG_DIR/$key.log"
    # a server on its way out already reports 0 sessions; keep the last
    # good snapshot so those sessions get reattached
    failed_since_start "$logf" && return 0
    tmp="$STATE_DIR/$key.sessions.tmp"
    : > "$tmp"
    for sid in $(active_sessions "$logf"); do
        echo "$sid|$(session_cwd "$mode" "$repo" "$sid")" >> "$tmp"
    done
    if [ -s "$tmp" ]; then
        mv "$tmp" "$STATE_DIR/$key.sessions"
    else
        rm -f "$tmp" "$STATE_DIR/$key.sessions"
    fi
}

# The server of <key> is gone: queue its last known sessions for reattaching.
queue_orphans() {
    local key="$1" snap age sid cwd
    snap="$STATE_DIR/$key.sessions"
    [ -f "$snap" ] || return 0
    if [ "$REATTACH" = "1" ]; then
        age=$(file_age "$snap" || echo 0)
        while IFS='|' read -r sid cwd; do
            [ -n "$sid" ] || continue
            if [ "$age" -gt "$REATTACH_WINDOW" ]; then
                log "reattach: $sid of $key last seen ${age}s ago, too old, skipped"
            elif [ ! -f "$REATTACH_DIR/$sid.cwd" ]; then
                log "reattach: $sid orphaned by $key, queued"
                echo "$cwd" > "$REATTACH_DIR/$sid.cwd"
            fi
        done < "$snap"
    fi
    rm -f "$snap"
}

reattach_running() {
    local pidfile="$REATTACH_DIR/$1.pid" pid
    [ -f "$pidfile" ] || return 1
    pid=$(cat "$pidfile" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    ps -p "$pid" -o command= 2>/dev/null | grep -q -- "--session-id $1"
}

drop_reattach() {
    rm -f "$REATTACH_DIR/$1".*
}

start_reattach() {
    local sid="$1" cwd attempts logf
    cwd=$(cat "$REATTACH_DIR/$sid.cwd")
    [ -d "$cwd" ] || { log "reattach: $sid folder $cwd is gone, dropped"; drop_reattach "$sid"; return 0; }
    attempts=$(cat "$REATTACH_DIR/$sid.attempts" 2>/dev/null || echo 0)
    echo $((attempts + 1)) > "$REATTACH_DIR/$sid.attempts"
    logf="$LOG_DIR/reattach-$sid.log"
    rotate_log "$logf"
    log "reattach: $sid in $cwd (attempt $((attempts + 1)))"
    (
        cd "$cwd" || exit 1
        echo "$START_MARK $(date '+%F %T')"
        exec "$CLAUDE_BIN" remote-control \
            --session-id "$sid" \
            ${PERMISSION_MODE:+--permission-mode "$PERMISSION_MODE"}
    ) < /dev/null >> "$logf" 2>&1 &
    echo $! > "$REATTACH_DIR/$sid.pid"
    touch "$REATTACH_DIR/$sid.seen"
}

# Starts queued reattaches and restarts reattached sessions whose process
# failed again; drops the ones whose session simply ended.
maintain_reattached() {
    local cwdfile sid attempts age
    for cwdfile in "$REATTACH_DIR"/*.cwd; do
        [ -f "$cwdfile" ] || continue
        sid=$(basename "$cwdfile" .cwd)
        if reattach_running "$sid"; then
            touch "$REATTACH_DIR/$sid.seen"
            # stable for 10 minutes: a later failure gets a fresh set of attempts
            age=$(file_age "$REATTACH_DIR/$sid.pid" || echo 0)
            [ "$age" -gt 600 ] && rm -f "$REATTACH_DIR/$sid.attempts"
            continue
        fi
        if [ -f "$REATTACH_DIR/$sid.pid" ] \
            && ! failed_since_start "$LOG_DIR/reattach-$sid.log"; then
            log "reattach: $sid process exited, session ended"
            drop_reattach "$sid"
            continue
        fi
        attempts=$(cat "$REATTACH_DIR/$sid.attempts" 2>/dev/null || echo 0)
        age=$(file_age "$REATTACH_DIR/$sid.seen" 2>/dev/null || file_age "$cwdfile" || echo 0)
        if [ "$attempts" -ge "$REATTACH_MAX_ATTEMPTS" ]; then
            log "reattach: $sid failed $attempts times, giving up (see $LOG_DIR/reattach-$sid.log)"
            drop_reattach "$sid"
        elif [ "$age" -gt "$REATTACH_WINDOW" ]; then
            log "reattach: $sid last seen ${age}s ago, too old, dropped"
            drop_reattach "$sid"
        else
            start_reattach "$sid"
        fi
    done
}

# Keeps the Mac from idle-sleeping while any remote session is active.
# Closing the lid on battery still sleeps; reattaching covers that case.
update_keep_awake() {
    local active=0 f pid
    for f in "$STATE_DIR"/*.sessions "$REATTACH_DIR"/*.cwd; do
        [ -f "$f" ] && { active=1; break; }
    done
    pid=$(cat "$KEEP_AWAKE_FILE" 2>/dev/null)
    if [ -n "$pid" ] && ! { kill -0 "$pid" 2>/dev/null \
        && ps -p "$pid" -o command= 2>/dev/null | grep -q caffeinate; }; then
        pid=""
        rm -f "$KEEP_AWAKE_FILE"
    fi
    if [ "$KEEP_AWAKE" = "1" ] && [ "$active" = 1 ]; then
        [ -n "$pid" ] && return 0
        caffeinate -i -w $$ &
        echo $! > "$KEEP_AWAKE_FILE"
        log "keep-awake: on (remote sessions active)"
    elif [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        rm -f "$KEEP_AWAKE_FILE"
        log "keep-awake: off"
    fi
}
# ---------------------------------------------------------------------------

cleanup() {
    log "supervisor: shutting down, stopping servers"
    local pidfile
    # session snapshots and reattach entries stay on disk: the next
    # supervisor start reattaches whatever was running
    for pidfile in "$STATE_DIR"/*.pid "$REATTACH_DIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        stop_server "$pidfile"
    done
    if [ -f "$KEEP_AWAKE_FILE" ]; then
        kill "$(cat "$KEEP_AWAKE_FILE")" 2>/dev/null || true
        rm -f "$KEEP_AWAKE_FILE"
    fi
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
        if server_running "$STATE_DIR/$key.pid"; then
            snapshot_sessions "$mode" "$repo" "$key"
            continue
        fi
        queue_orphans "$key"
        start_server "$mode" "$repo"
    done < <(discover_repos)

    # a repository was removed or matched IGNORE_PATTERNS — stop its server
    for pidfile in "$STATE_DIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        key=$(basename "$pidfile" .pid)
        if ! grep -qxF "$key" "$want_file"; then
            log "stop $key (repository no longer in the list)"
            stop_server "$pidfile"
            rm -f "$STATE_DIR/$key.sessions"
        fi
    done
    rm -f "$want_file"

    maintain_reattached
    update_keep_awake

    sleep "$SCAN_INTERVAL" & wait $!
done
