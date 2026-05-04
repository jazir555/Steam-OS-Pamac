#!/bin/bash
set -euo pipefail

echo "=== Wait for plasmashell to come back ==="
for i in $(seq 1 15); do
    if pgrep -x plasmashell >/dev/null 2>&1; then
        echo "plasmashell is back after ${i}s"
        break
    fi
    echo "Waiting... ($i)"
    sleep 2
done

if ! pgrep -x plasmashell >/dev/null 2>&1; then
    echo "plasmashell did NOT come back"
    exit 1
fi

echo ""
echo "=== Check plasmashell environment after restart ==="
PLASMA_PID=$(pgrep -x plasmashell)
cat /proc/"$PLASMA_PID"/environ 2>/dev/null | tr '\0' '\n' | grep '^XDG_DATA_DIRS=' || echo "NOT SET"

echo ""
echo "=== systemd env ==="
systemctl --user show-environment | grep '^XDG_DATA_DIRS=' || echo "NOT SET"
