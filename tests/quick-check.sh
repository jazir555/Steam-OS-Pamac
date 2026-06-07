#!/bin/bash
set -euo pipefail
if pgrep -x plasmashell >/dev/null 2>&1; then
    PID=$(pgrep -x plasmashell)
    echo "plasmashell alive, PID=$PID"
    cat /proc/"$PID"/environ 2>/dev/null | tr '\0' '\n' | grep '^XDG_DATA_DIRS=' || echo "NO XDG"
else
    echo "plasmashell NOT running"
fi
