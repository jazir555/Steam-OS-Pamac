#!/bin/bash
set -euo pipefail
PLASMA_PID=$(pgrep -x plasmashell 2>/dev/null || echo "")
if [[ -n "$PLASMA_PID" ]]; then
    echo "plasmashell PID: $PLASMA_PID"
    cat /proc/"$PLASMA_PID"/environ 2>/dev/null | tr '\0' '\n' | grep '^XDG_DATA_DIRS=' || echo "XDG_DATA_DIRS not set"
else
    echo "plasmashell not running"
fi
echo "---"
echo "Drop-in:"
cat ~/.config/systemd/user/plasma-plasmashell.service.d/override-xdg-data-dirs.conf 2>/dev/null || echo "NO DROPIN"
