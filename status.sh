#!/usr/bin/env bash
# Shows the state of the supervisor and all remote-control servers.
set -u

LABEL="com.claude-rc-supervisor"
CONFIG_FILE="${CLAUDE_RC_CONFIG:-$HOME/.claude-rc-supervisor.env}"
STATE_DIR="$HOME/.local/state/claude-rc-supervisor"
LOG_DIR="$HOME/Library/Logs/claude-rc-supervisor"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

echo "== LaunchAgent =="
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    launchctl print "gui/$(id -u)/$LABEL" | grep -E "state|pid" | head -3
else
    echo "not loaded (run ./install.sh)"
fi

echo
echo "== remote-control servers =="
found=0
for pidfile in "$STATE_DIR"/*.pid; do
    [ -f "$pidfile" ] || continue
    found=1
    key=$(basename "$pidfile" .pid)
    pid=$(cat "$pidfile" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
        && ps -p "$pid" -o command= | grep -q remote-control; then
        printf "  %-30s RUNNING (pid %s)\n" "$key" "$pid"
    else
        printf "  %-30s DEAD (the supervisor will restart it)\n" "$key"
    fi
done
[ "$found" = 0 ] && echo "  no servers running"

echo
echo "Logs: $LOG_DIR/"
