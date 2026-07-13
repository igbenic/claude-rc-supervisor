#!/usr/bin/env bash
# Optional: fully disable Claude Code attribution — the "Co-Authored-By:
# Claude" trailer in git commits and the "Generated with Claude Code" note
# in pull request bodies — for ALL projects and sessions of the current
# user, including remote sessions spawned by the supervisor.
#
# Merges {"attribution": {"commit": false, "pr": false}} into
# ~/.claude/settings.json, preserving the rest of the file.
# Picked up by Claude Code on the fly, no restart needed.
set -euo pipefail

CFG="$HOME/.claude/settings.json"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required"; exit 1; }

mkdir -p "$HOME/.claude"
[ -f "$CFG" ] || echo '{}' > "$CFG"

tmp=$(mktemp "${TMPDIR:-/tmp}/claude-settings.XXXXXX")
jq '.attribution = ((.attribution // {}) + {commit: false, pr: false})' "$CFG" > "$tmp"
mv "$tmp" "$CFG"

echo "Attribution disabled in $CFG:"
jq '.attribution' "$CFG"
