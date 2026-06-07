#!/bin/bash
export HOME=/home/deck

DESKTOP_FILE="/home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop"

echo "=== Backup desktop file ==="
cp "$DESKTOP_FILE" "$DESKTOP_FILE.bak"

echo "=== Change Exec to use kstart5 ==="
sed -i 's|^Exec=distrobox enter.*|Exec=kstart5 distrobox enter arch-pamac -- pamac-manager-wrapper %U|' "$DESKTOP_FILE"

echo "=== Set StartupNotify back to true (kstart5 handles it) ==="
sed -i 's|StartupNotify=false|StartupNotify=true|' "$DESKTOP_FILE"

echo "=== Updated desktop file ==="
cat "$DESKTOP_FILE"

echo ""
echo "=== Rebuilding sycoca ==="
kbuildsycoca6 --noincremental 2>&1 | tail -2
dbus-send --session --type=signal /KSycoca org.kde.KSycoca.databaseChanged 2>&1
echo "SYCOCA_DONE"