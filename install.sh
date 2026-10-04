#!/usr/bin/env bash
# Installs the supervisor as a launchd LaunchAgent: starts at login,
# auto-restarts on crash (KeepAlive).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.claude-rc-supervisor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/claude-rc-supervisor"
CONFIG_FILE="$HOME/.claude-rc-supervisor.env"

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

# the personal config lives in the home folder, outside the repository
if [ ! -f "$CONFIG_FILE" ]; then
    cp "$SCRIPT_DIR/claude-rc-supervisor.env.example" "$CONFIG_FILE"
    echo "Created config: $CONFIG_FILE"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/supervisor.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/supervisor.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/supervisor.log</string>
</dict>
</plist>
EOF

UID_NUM="$(id -u)"
DOMAIN="gui/$UID_NUM"

# reload if it was already installed
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

# Some setups (e.g. a headless Mac mini reached over SSH/Screen Sharing) refuse
# "launchctl bootstrap gui/<uid>" with "125: Domain does not support specified
# action". Running the same command inside the user's GUI context via
# "sudo launchctl asuser" works there, so fall back to it on 125.
set +e
BOOTSTRAP_OUT="$(launchctl bootstrap "$DOMAIN" "$PLIST" 2>&1)"
BOOTSTRAP_RC=$?
set -e
if [ "$BOOTSTRAP_RC" -eq 125 ]; then
    echo "launchctl bootstrap $DOMAIN failed with error 125 (Domain does not support specified action)."
    echo "Falling back to: sudo launchctl asuser $UID_NUM launchctl bootstrap $DOMAIN $PLIST"
    echo "(sudo may ask for your password)"
    sudo launchctl asuser "$UID_NUM" launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    sudo launchctl asuser "$UID_NUM" launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "Loaded via sudo launchctl asuser. On this Mac, use the same wrapper to manage the agent:"
    echo "  sudo launchctl asuser $UID_NUM launchctl kickstart -k $DOMAIN/$LABEL"
    echo "  sudo launchctl asuser $UID_NUM launchctl bootout $DOMAIN/$LABEL"
elif [ "$BOOTSTRAP_RC" -ne 0 ]; then
    echo "$BOOTSTRAP_OUT" >&2
    exit "$BOOTSTRAP_RC"
fi

echo "Installed:      $PLIST"
echo "Config:         $CONFIG_FILE"
echo "Supervisor log: $LOG_DIR/supervisor.log"
echo "Status:         $SCRIPT_DIR/status.sh"
