#!/bin/bash
set -euo pipefail

echo "=== Current plasmashell XDG_DATA_DIRS ==="
PLASMA_PID=$(pgrep -x plasmashell 2>/dev/null || echo "")
if [[ -n "$PLASMA_PID" ]]; then
    cat /proc/"$PLASMA_PID"/environ 2>/dev/null | tr '\0' '\n' | grep '^XDG_DATA_DIRS=' || echo "NOT SET in plasmashell"
else
    echo "plasmashell not running"
fi

echo ""
echo "=== systemd user environment ==="
systemctl --user show-environment 2>/dev/null | grep '^XDG_DATA_DIRS=' || echo "NOT SET"

echo ""
echo "=== Attempt: set XDG in systemd, rebuild sycoca from dbus ==="
export XDG_DATA_DIRS="/home/deck/.local/share:/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share"
systemctl --user import-environment XDG_DATA_DIRS

echo "After import:"
systemctl --user show-environment 2>/dev/null | grep '^XDG_DATA_DIRS='

echo ""
echo "=== Try kbuildsycoca6 with correct XDG_DATA_DIRS ==="
XDG_DATA_DIRS="/home/deck/.local/share:/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share" kbuildsycoca6 --noincremental 2>&1 | tail -5

echo ""
echo "=== Check if pamac appears in sycoca cache ==="
XDG_DATA_DIRS="/home/deck/.local/share:/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share" kmenuedit 2>/dev/null &
KMENU_PID=$!
sleep 2
kill $KMENU_PID 2>/dev/null || true

echo ""
echo "=== Check KSycoca DB for pamac ==="
find /tmp/ -name 'ksycoca*' -newer /tmp/.X11-unix 2>/dev/null | head -5
