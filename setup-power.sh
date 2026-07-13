#!/usr/bin/env bash
# Configures macOS to run 24/7 (including with the lid closed).
# Requires sudo. Revert: ./setup-power.sh --restore
set -euo pipefail

if [ "${1:-}" = "--restore" ]; then
    echo "Restoring default power management settings..."
    sudo pmset -a restoredefaults
    sudo pmset repeat cancel
    sudo mdutil -a -i on || true
    exit 0
fi

echo "== Power management (pmset) =="
# sleep 0        — never sleep
# disablesleep 1 — forbid sleep entirely, including lid closed (clamshell)
# displaysleep 5 — turn the display off after 5 min (does not affect work)
# disksleep 0    — never spin down disks
# autorestart 1  — start automatically after a power failure
# lidwake 1      — wake when the lid is opened
# acwake 1       — wake when the power adapter is connected
# womp 1         — Wake on LAN (relevant with Ethernet)
# ttyskeepawake 1 — stay awake while ssh/tty sessions are active
# powernap 0     — Power Nap is pointless when there is no sleep
sudo pmset -a sleep 0 disablesleep 1 displaysleep 5 disksleep 0 \
    autorestart 1 lidwake 1 acwake 1 womp 1 ttyskeepawake 1 powernap 0

# safety-net wake-up every day at 8:00 (in case sleep happens anyway)
sudo pmset repeat wake MTWRFSU 8:00:00

if [ "${1:-}" = "--disable-spotlight" ]; then
    echo "== Disabling Spotlight indexing =="
    sudo mdutil -a -i off
fi

echo
echo "== Current settings =="
pmset -g custom

cat <<'EOF'

Done. Additionally (manual steps):
  1. Keep the laptop plugged in: with the lid closed on battery it will
     not sleep, but it will drain.
  2. The LaunchAgent starts after login. For self-recovery after a power
     failure enable auto-login: System Settings -> Users & Groups ->
     Automatically log in as... (incompatible with FileVault).
  3. To disable Spotlight indexing: ./setup-power.sh --disable-spotlight
EOF
