#!/bin/bash
set -euo pipefail

echo "=== Is plasmashell still alive? ==="
pgrep -x plasmashell && echo "YES - plasmashell running" || echo "NO - plasmashell crashed"

echo ""
echo "=== Check sycoca cache files ==="
find /home/deck/.cache/ -name 'ksycoca*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -5

echo ""
echo "=== Test: can we find pamac in the sycoca database? ==="
# Use kservicecmd6 or just try to launch
KSVC=$(which kservicecmd6 2>/dev/null || echo "")
if [[ -n "$KSVC" ]]; then
    kservicecmd6 list 2>/dev/null | grep -i pamac || echo "pamac not found in kservicecmd"
else
    echo "kservicecmd6 not available"
fi

echo ""
echo "=== Use kioclient to check if desktop file is visible ==="
# Check via D-BUS if the app appears in KDE's menu
dbus-send --session --print-reply --dest=org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript 2>&1 | head -5 || true

echo ""
echo "=== Check: is pamac-manager accessible via KDE service type system ==="
# Try to use KDE's application query
export XDG_DATA_DIRS="/home/deck/.local/share:/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share"
kioclient6 stat /home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop 2>&1 | head -5 || echo "kioclient failed"

echo ""
echo "=== List pamac desktop file contents ==="
head -5 /home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop 2>/dev/null || echo "NOT FOUND"
