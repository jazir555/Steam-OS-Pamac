#!/bin/bash
set -euo pipefail

echo "=== Verify plasmashell is using the correct sycoca cache ==="
PLASMA_PID=$(pgrep -x plasmashell 2>/dev/null || echo "")
if [[ -n "$PLASMA_PID" ]]; then
    echo "plasmashell PID: $PLASMA_PID"
    PLASMA_XDG=$(cat /proc/"$PLASMA_PID"/environ 2>/dev/null | tr '\0' '\n' | grep '^XDG_DATA_DIRS=' | sed 's/XDG_DATA_DIRS=//')
    echo "plasmashell XDG_DATA_DIRS: $PLASMA_XDG"
fi

echo ""
echo "=== Send D-Bus databaseChanged signal (safe, unlike refreshCurrentShell) ==="
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
dbus-send --session --type=signal /KSycoca org.kde.KSycoca.databaseChanged 2>&1 || echo "signal send failed"

echo ""
echo "=== Wait a moment, then check if plasmashell is still alive ==="
sleep 3
if pgrep -x plasmashell >/dev/null 2>&1; then
    echo "plasmashell still alive - good!"
else
    echo "plasmashell died!"
fi

echo ""
echo "=== Try to look up pamac service via D-Bus (KSycoca) ==="
# Use gdbus to introspect the sycoca service
gdbus call --session --dest org.kde.KSycoca --object-path /KSycoca --method org.kde.KSycoca.lookup "arch-pamac-org.manjaro.pamac.manager.desktop" 2>&1 || echo "gdbus lookup failed (expected - API may differ)"

echo ""
echo "=== Use qdbus6 to check KDE service ==="
qdbus6 org.kde.sycoca /org/kde/sycoca 2>&1 | head -5 || echo "no sycoca on bus"

echo ""
echo "=== Final check: can we find pamac in the menu structure via KDE? ==="
# Use plasma scripting via qdbus to check if the app appears in the menu
qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript '
var panel = panelById(0);
print("Panel found: " + (panel !== null));
' 2>&1 | head -5 || echo "script eval failed"
