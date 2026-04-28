#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

APP_DIR="$HOME/.local/share/applications"
STATE_DIR="$HOME/.local/share/steamos-pamac/arch-pamac"

echo "=== Step 1: Verify Celluloid desktop file exists ==="
ls -la "$APP_DIR/arch-pamac-io.github.celluloid_player.Celluloid.desktop" 2>&1

echo ""
echo "=== Step 2: Uninstall Celluloid via helper (no kdialog, direct) ==="
$HOME/.local/bin/steamos-pamac-uninstall --desktop-file arch-pamac-io.github.celluloid_player.Celluloid.desktop
RC=$?
echo "Uninstall exit code: $RC"

echo ""
echo "=== Step 3: Check if desktop file was removed ==="
ls -la "$APP_DIR/arch-pamac-io.github.celluloid_player.Celluloid.desktop" 2>&1

echo ""
echo "=== Step 4: Check exported-apps.list ==="
cat "$STATE_DIR/exported-apps.list" 2>&1

echo ""
echo "=== Step 5: Refresh desktop database and sycoca ==="
update-desktop-database "$APP_DIR" 2>/dev/null
rm -f ~/.cache/ksycoca6* 2>/dev/null
kbuildsycoca6 2>&1 | tail -1

echo ""
echo "=== Step 6: Signal plasmashell to refresh ==="
qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.refreshCurrentShell 2>&1 || echo "refreshCurrentShell failed (may need GUI session)"

echo ""
echo "=== Step 7: Uninstall helper log ==="
cat "$STATE_DIR/uninstall-helper.log" 2>&1 | tail -20

echo ""
echo "=== DONE ==="
