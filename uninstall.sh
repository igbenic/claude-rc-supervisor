#!/usr/bin/env bash
# Stops the supervisor and all remote-control servers, removes the LaunchAgent.
# Does not touch the personal config ~/.claude-rc-supervisor.env.
set -uo pipefail

LABEL="com.claude-rc-supervisor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_FILE="${CLAUDE_RC_CONFIG:-$HOME/.claude-rc-supervisor.env}"
STATE_DIR="$HOME/.local/state/claude-rc-supervisor"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

# the supervisor stops its servers on shutdown (trap in supervisor.sh);
# give it time and then finish off possible orphans
sleep 3
for pidfile in "$STATE_DIR"/*.pid; do
    [ -f "$pidfile" ] || continue
    pid=$(cat "$pidfile" 2>/dev/null)
    if [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -q "remote-control"; then
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
done

leftover=$(pgrep -f "claude remote-control" || true)
if [ -n "$leftover" ]; then
    echo "WARNING: remote-control processes are still running (possibly started manually):"
    pgrep -fl "claude remote-control"
fi

echo "Uninstalled."
