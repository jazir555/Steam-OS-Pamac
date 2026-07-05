#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Check wrapper process env ==="
PAMAC_PID=$(pgrep -f pamac-manager 2>/dev/null | head -1)
echo "Pamac PID: $PAMAC_PID"

# Check the podman exec that launched the wrapper
ps aux | grep "podman.*exec.*arch-pamac" | grep -v grep | head -3

echo ""
echo "=== Check container wrapper environment ==="
WRAPPER_PID=$(pgrep -f "pamac-manager-wrapper" 2>/dev/null | head -1)
echo "Wrapper PID: $WRAPPER_PID"
if [[ -n "$WRAPPER_PID" ]]; then
  tr '\0' '\n' < "/proc/$WRAPPER_PID/environ" 2>/dev/null | grep -iE 'DISPLAY|XAUTH|XDG' | head -10
fi

echo ""
echo "DONE"