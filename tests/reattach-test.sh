#!/usr/bin/env bash
# End-to-end test of session self-healing against a fake `claude` binary:
#   1. a server dies with an active session -> the session is reattached
#      in its worktree and keep-awake turns on
#   2. the reattach process gives up too -> it is restarted
#   3. the session ends normally -> the entry is dropped, keep-awake off
#   4. the supervisor is stopped with a session active -> the next
#      supervisor start reattaches it
# Usage: tests/reattach-test.sh   (no real Claude processes are touched)
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rc-reattach-test.XXXXXX")" && pwd -P)"
FAKE="$T/fake"
mkdir -p "$T/work/repo" "$FAKE"
git -C "$T/work/repo" init -q

S1=session_01TestOne
S2=session_01TestTwo
mkdir -p "$T/work/repo/.claude/worktrees/bridge-cse_${S1#session_}"

# --- fake claude --------------------------------------------------------------
cat > "$FAKE/claude" <<'EOF'
#!/usr/bin/env bash
F="$FAKE_DIR"
sid=""
prev=""
for a in "$@"; do
    [ "$prev" = "--session-id" ] && sid="$a"
    prev="$a"
done
name="${sid:-server}"
block() {
    local n=0 s
    for s in $1; do n=$((n + 1)); done
    printf '\033[7A\033[J· Ready · repo\n    Capacity: %s/32 · New sessions will be created in an isolated worktree\n' "$n"
    for s in $1; do
        printf '    \033]8;;https://claude.ai/code/%s?from=cli\007Some title\033]8;;\007\n' "$s"
    done
    printf '\nCode anywhere with the Claude mobile app\n'
}
current() { if [ -n "$sid" ]; then echo "$sid"; else cat "$F/sessions" 2>/dev/null; fi; }
trap 'echo "Shutting down $(current | wc -l | tr -d " ") active session(s)…"; exit 0' TERM
[ -n "$sid" ] && echo "$sid|$(pwd -P)" >> "$F/reattached"
while :; do
    if [ -f "$F/die-$name" ]; then
        rm -f "$F/die-$name"
        echo "Error: Persistent errors for 10 minutes, giving up."
        echo "Shutting down 1 active session(s)…"
        block ""
        exit 1
    fi
    if [ -n "$sid" ] && [ -f "$F/end-$sid" ]; then
        echo "Session ended."
        exit 0
    fi
    block "$(current)"
    sleep 0.3
done
EOF
chmod +x "$FAKE/claude"

cat > "$T/config.env" <<EOF
WORK_DIR="$T/work"
SCAN_INTERVAL=1
LOG_DIR="$T/logs"
STATE_DIR="$T/state"
CLAUDE_BIN="$FAKE/claude"
AUTO_TRUST=0
SERVE_NON_GIT=0
SESSION_PREFIX=test
PERMISSION_MODE=acceptEdits
KEEP_AWAKE=1
EOF

export FAKE_DIR="$FAKE" CLAUDE_RC_CONFIG="$T/config.env"
SUP_PID=""
start_sup() { bash "$ROOT/supervisor.sh" >> "$T/supervisor.log" 2>&1 & SUP_PID=$!; }
stop_sup() { kill "$SUP_PID" 2>/dev/null; wait "$SUP_PID" 2>/dev/null; }

FAILS=0
check() {   # check <description> <command...>; waits up to 10 s
    local desc="$1" i
    shift
    for i in $(seq 1 40); do
        if "$@"; then echo "ok   - $desc"; return 0; fi
        sleep 0.25
    done
    echo "FAIL - $desc"
    FAILS=$((FAILS + 1))
}
reattached_in() { grep -qxF "$1|$2" "$FAKE/reattached" 2>/dev/null; }
reattach_count() { [ "$(grep -c "^$1|" "$FAKE/reattached" 2>/dev/null)" = "$2" ]; }
keep_awake_on() { [ -f "$T/state/keep-awake.state" ] && kill -0 "$(cat "$T/state/keep-awake.state")" 2>/dev/null; }
keep_awake_off() { ! keep_awake_on; }
entry_gone() { [ ! -f "$T/state/reattach/$1.cwd" ]; }
snapshot_has() { grep -q "^$1|" "$T/state/repo.sessions" 2>/dev/null; }
sup_log_has() { grep -q "$1" "$T/supervisor.log"; }

trap 'stop_sup; pkill -f "$FAKE/claude" 2>/dev/null; rm -rf "$T"' EXIT

start_sup

echo "# 1. server dies with an active session"
echo "$S1" > "$FAKE/sessions"
check "snapshot records $S1" snapshot_has "$S1"
check "keep-awake on while a session is active" keep_awake_on
: > "$FAKE/sessions"            # the dying server no longer lists it
touch "$FAKE/die-server"
check "$S1 reattached in its worktree" \
    reattached_in "$S1" "$T/work/repo/.claude/worktrees/bridge-cse_${S1#session_}"
check "server restarted" sup_log_has "start \[worktree\] $T/work/repo"

echo "# 2. the reattach process gives up as well"
touch "$FAKE/die-$S1"
check "$S1 reattached again" reattach_count "$S1" 2

echo "# 3. the session ends normally"
touch "$FAKE/end-$S1"
check "$S1 entry dropped" entry_gone "$S1"
check "keep-awake off with no sessions" keep_awake_off
check "no further reattach of $S1" reattach_count "$S1" 2

echo "# 4. supervisor stopped while a session is active"
echo "$S2" > "$FAKE/sessions"
check "snapshot records $S2" snapshot_has "$S2"
stop_sup
: > "$FAKE/sessions"
start_sup
check "$S2 reattached after supervisor restart (no worktree -> repo)" \
    reattached_in "$S2" "$T/work/repo"

echo
if [ "$FAILS" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$FAILS check(s) failed; supervisor log:"
    cat "$T/supervisor.log"
    exit 1
fi
