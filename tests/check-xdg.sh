#!/bin/bash
set -euo pipefail
PLASMA_PID=$(pgrep -x plasmashell 2>/dev/null || echo "")
if [[ -n "$PLASMA_PID" ]]; then
    echo "plasmashell PID: $PLASMA_PID"
    XDG=$(cat /proc/"$PLASMA_PID"/environ 2>/dev/null | tr '\0' '\n' | grep '^XDG_DATA_DIRS=' || echo "NOT SET")
    echo "XDG_DATA_DIRS in plasmashell: $XDG"
else
    echo "plasmashell not running"
fi
echo "---"
echo "environment.d config:"
cat ~/.config/environment.d/30-xdg-data-dirs.conf 2>/dev/null || echo "NOT FOUND"
echo "---"
echo "systemd --user show-environment XDG_DATA_DIRS:"
XDG_SYSTEMD=$(systemctl --user show-environment 2>/dev/null | grep '^XDG_DATA_DIRS=' || echo "NOT SET")
echo "$XDG_SYSTEMD"
