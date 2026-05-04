#!/bin/bash
set -euo pipefail

echo "=== Attempting to restart plasmashell via loginctl ==="

# Try to restart the user session which should bring back plasmashell
loginctl list-sessions 2>&1 | head -10

echo ""
echo "=== Try: loginctl unlock-session ==="
SESSION_ID=$(loginctl list-sessions --no-legend 2>/dev/null | grep deck | head -1 | awk '{print $1}')
echo "Session ID: $SESSION_ID"

# Check the session type
loginctl show-session "$SESSION_ID" 2>/dev/null | grep -E '(Type|State|Desktop|Display)' | head -5

echo ""
echo "=== Attempt to start plasmashell via systemd ==="
# Try starting via systemd with proper environment
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/1000

# The service is "disabled" but can be started manually
systemctl --user start plasma-plasmashell.service 2>&1 || echo "systemctl start failed"

sleep 5

if pgrep -x plasmashell >/dev/null 2>&1; then
    echo "SUCCESS - plasmashell is running!"
    PLASMA_PID=$(pgrep -x plasmashell)
    echo "PID: $PLASMA_PID"
    cat /proc/"$PLASMA_PID"/environ 2>/dev/null | tr '\0' '\n' | grep '^XDG_DATA_DIRS='
else
    echo "FAILED - plasmashell still not running"
    echo "Will need user to log out and back in on the Deck"
fi
