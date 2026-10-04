#!/usr/bin/env bash
# setup-mac.sh — one-shot install of claude-rc-supervisor on this Mac.
# Every repo under ~/Projects becomes reachable from the Claude app (Code tab).
#
#   RC_PREFIX=mbp  ./setup-mac.sh              # MacBook: no power changes, sleeps normally
#   RC_PREFIX=mini ./setup-mac.sh --always-on  # Mac mini: never sleeps, restarts after power loss
#
# RC_PREFIX   short machine label shown in the app (default: lowercase hostname)
# RC_IGNORE   IGNORE_PATTERNS to write (default: keep the existing value)
# RC_PERMISSION_MODE  permission mode for remote sessions (default: acceptEdits)
#
# Safe to re-run: the old config is backed up and the LaunchAgent is reloaded.
set -euo pipefail

ALWAYS_ON=0
for arg in "$@"; do
    case "$arg" in
        --always-on) ALWAYS_ON=1 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg (see --help)" >&2; exit 2 ;;
    esac
done

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$HOME/Projects"
CFG="$HOME/.claude-rc-supervisor.env"
LABEL="com.claude-rc-supervisor"
PREFIX="${RC_PREFIX:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
PERM="${RC_PERMISSION_MODE:-acceptEdits}"
STAMP="$(date +%Y%m%d-%H%M%S)"

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
step "Preflight"
[ "$(uname -s)" = "Darwin" ] || die "macOS only"
[ -d "$WORK_DIR" ] || die "$WORK_DIR does not exist"
case "$DIR/" in
    "$WORK_DIR"/*) die "this checkout is inside $WORK_DIR, so it would serve itself. Clone it to ~/.local/share/claude-rc-supervisor instead." ;;
esac
grep -q 'SESSION_PREFIX' "$DIR/supervisor.sh" \
    || die "supervisor.sh has no SESSION_PREFIX. Run patch-fork.sh first, then git pull."
command -v claude >/dev/null 2>&1 || die "claude CLI not found on PATH"
command -v git    >/dev/null 2>&1 || die "git not found"
if ! command -v jq >/dev/null 2>&1; then
    command -v brew >/dev/null 2>&1 || die "jq is missing and Homebrew isn't installed"
    brew install jq
fi
echo "fork commit:   $(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "machine label: $PREFIX"

# ---------------------------------------------------------------------------
step "Claude Code"
claude update >/dev/null 2>&1 || warn "'claude update' failed; if you installed via Homebrew, upgrade it there"
ver="$(claude --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
[ -n "$ver" ] || die "could not read the claude version"
IFS=. read -r v1 v2 v3 <<< "$ver"
[ $((v1 * 100000000 + v2 * 10000 + v3)) -ge $((2 * 100000000 + 1 * 10000 + 200)) ] \
    || die "claude $ver is too old, need >= 2.1.200"
echo "claude $ver OK"
claude auth status || warn "couldn't confirm the login; if Remote Control fails, run: claude auth login"

# ---------------------------------------------------------------------------
step "Backups"
if [ -f "$HOME/.claude.json" ]; then
    cp "$HOME/.claude.json" "$HOME/.claude.json.bak-$STAMP"
    echo "$HOME/.claude.json -> $HOME/.claude.json.bak-$STAMP (auto-trust edits this file)"
fi
OLD_IGNORE=""
if [ -f "$CFG" ]; then
    cp "$CFG" "$CFG.bak-$STAMP"
    echo "$CFG -> $CFG.bak-$STAMP"
    # shellcheck disable=SC1090
    OLD_IGNORE="$( . "$CFG" >/dev/null 2>&1 || true; printf '%s' "${IGNORE_PATTERNS:-}" )"
fi
IGNORE="${RC_IGNORE-$OLD_IGNORE}"

# ---------------------------------------------------------------------------
step "Config: $CFG"
{
    echo "# written by setup-mac.sh on $STAMP (re-run it to regenerate)"
    echo 'WORK_DIR="$HOME/Projects"'
    echo 'SCAN_INTERVAL=60'
    printf 'PERMISSION_MODE=%q\n' "$PERM"
    echo 'SERVE_NON_GIT=1'
    printf 'IGNORE_PATTERNS=%q\n' "$IGNORE"
    printf 'SESSION_PREFIX=%q\n' "$PREFIX"
    echo '# your interactive shell PATH (dotnet, flutter, kubectl, node, ...); launchd only gives a minimal one'
    printf 'export PATH=%q\n' "$PATH"
} > "$CFG"
chmod 600 "$CFG"
sed 's/^export PATH=.*/export PATH=<your shell PATH>/' "$CFG"

# ---------------------------------------------------------------------------
step "What will be served"
n_repos="$(find "$WORK_DIR" -mindepth 2 -maxdepth 3 -name .git 2>/dev/null | wc -l | tr -d ' ')"
echo "about $n_repos git repos under $WORK_DIR, one node process each (~100-300 MB RAM idle)"
[ "$n_repos" -gt 20 ] && warn "that's a lot of RAM; consider RC_IGNORE=\"old-thing other/*\" and re-run"

# ---------------------------------------------------------------------------
# The supervisor runs headless (stdin = /dev/null), so the one-time
# "Enable Remote Control?" confirmation has to be accepted interactively once.
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    step "Supervisor already installed: skipping the one-time prompt check"
elif [ "${RC_SKIP_PRIME:-0}" = "1" ]; then
    step "Skipping the one-time prompt check (RC_SKIP_PRIME=1)"
else
    first_repo="$(find "$WORK_DIR" -mindepth 2 -maxdepth 3 -name .git -print 2>/dev/null | head -n1 || true)"
    first_repo="${first_repo%/.git}"
    if [ -n "$first_repo" ]; then
        step "One-time Remote Control prompts + smoke test"
        cat <<EOF
Starting Remote Control once in: $first_repo
  - answer y to "Enable Remote Control?" and "Trust ...?" if they appear
  - when it sits there waiting for connections, press Ctrl+C
  - if it errors out instead (login / eligibility), fix that before going on
EOF
        trap ':' INT
        rc=0
        ( cd "$first_repo" && claude remote-control --no-create-session-in-dir ) || rc=$?
        trap - INT
        case "$rc" in
            0|130) echo "smoke test done" ;;
            *) warn "remote-control exited with code $rc; check the output above before trusting the daemon" ;;
        esac
    else
        warn "no git repo found under $WORK_DIR, skipping the smoke test"
    fi
fi

# ---------------------------------------------------------------------------
step "Install LaunchAgent"
"$DIR/install.sh"

# ---------------------------------------------------------------------------
if [ "$ALWAYS_ON" = "1" ]; then
    step "Always-on power settings (asks for sudo)"
    "$DIR/setup-power.sh"
    if fdesetup status 2>/dev/null | grep -q "FileVault is On"; then
        warn "FileVault is ON, so auto-login is impossible: after a reboot or power cut, log in once by hand (or turn FileVault off)"
    else
        echo "Last manual step: System Settings -> Users & Groups -> Automatically log in as -> you"
    fi
fi

# ---------------------------------------------------------------------------
step "Status (giving the servers 20 s to come up)"
sleep 20
"$DIR/status.sh"

cat <<EOF

Done. Claude app -> Code: sessions show up as "$PREFIX-<repo>-...".
Logs:      ~/Library/Logs/claude-rc-supervisor/
Restart:   launchctl kickstart -k gui/\$(id -u)/$LABEL
Uninstall: $DIR/uninstall.sh$( [ "$ALWAYS_ON" = "1" ] && printf ' && %s/setup-power.sh --restore' "$DIR" )
EOF
