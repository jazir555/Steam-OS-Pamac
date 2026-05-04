#!/bin/bash
set -euo pipefail

echo "=== Trying to start plasmashell ==="
export DISPLAY=:0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export XDG_RUNTIME_DIR=/run/user/1000

# Check if it's already running
if pgrep -x plasmashell >/dev/null 2>&1; then
    echo "Already running"
    exit 0
fi

# Start plasmashell in the background with nohup
nohup plasmashell --no-respawn &>/dev/null &
echo "Started plasmashell, PID=$!"

sleep 5

if pgrep -x plasmashell >/dev/null 2>&1; then
    NEW_PID=$(pgrep -x plasmashell)
    echo "plasmashell running, PID=$NEW_PID"
    echo "XDG_DATA_DIRS:"
    cat /proc/"$NEW_PID"/environ 2>/dev/null | tr '\0' '\n' | grep '^XDG_DATA_DIRS=' || echo "NOT SET"
else
    echo "plasmashell failed to start"
fi
