#!/bin/bash
export HOME=/home/deck

DESKTOP_FILE="/home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop"

echo "=== Current desktop file ==="
cat "$DESKTOP_FILE"

echo ""
echo "=== Fixing: set StartupNotify=false and revert WMClass ==="
# Revert WMClass to pamac-manager (original)
sed -i 's|StartupWMClass=org.manjaro.pamac.manager|StartupWMClass=pamac-manager|' "$DESKTOP_FILE"
# Change StartupNotify to false
sed -i 's|StartupNotify=true|StartupNotify=false|' "$DESKTOP_FILE"

echo ""
echo "=== Updated desktop file ==="
cat "$DESKTOP_FILE"

echo ""
echo "=== Rebuilding sycoca ==="
kbuildsycoca6 --noincremental 2>&1 | tail -2
dbus-send --session --type=signal /KSycoca org.kde.KSycoca.databaseChanged 2>&1
echo "SYCOCA_DONE"

echo ""
echo "=== Verification ==="
grep -E 'StartupNotify|StartupWMClass' "$DESKTOP_FILE"