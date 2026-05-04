#!/bin/bash
set -euo pipefail

echo "=== Checking plasma-plasmashell.service status ==="
systemctl --user status plasma-plasmashell.service 2>&1 | head -15

echo ""
echo "=== Attempt: restart plasma-plasmashell.service ==="
systemctl --user restart plasma-plasmashell.service 2>&1 || echo "restart failed"

sleep 5

echo ""
echo "=== Check if plasmashell is running ==="
if pgrep -x plasmashell >/dev/null 2>&1; then
    PLASMA_PID=$(pgrep -x plasmashell)
    echo "plasmashell PID: $PLASMA_PID"
    echo "XDG_DATA_DIRS:"
    cat /proc/"$PLASMA_PID"/environ 2>/dev/null | tr '\0' '\n' | grep '^XDG_DATA_DIRS=' || echo "NOT SET"
else
    echo "plasmashell not running"
fi
