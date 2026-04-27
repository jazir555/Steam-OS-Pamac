#!/bin/bash
set +e

CONTAINER="arch-pamac"

echo "=== Installing librewolf-bin via pamac ==="

podman exec -i -u 0 "$CONTAINER" bash -c '
    rm -f /run/dbus/pid 2>/dev/null
    pkill pamac-daemon 2>/dev/null; pkill polkitd 2>/dev/null; pkill dbus-daemon 2>/dev/null
    sleep 1
    mkdir -p /run/dbus
    dbus-daemon --system --fork 2>/dev/null
    sleep 1
    /usr/lib/polkit-1/polkitd --no-debug &>/dev/null &
    sleep 1
    /usr/bin/pamac-daemon &>/dev/null &
    sleep 2
    pamac install --no-confirm librewolf-bin 2>&1
'

echo ""
echo "=== Verifying ==="
podman exec -i -u 0 "$CONTAINER" pacman -Q librewolf-bin 2>/dev/null && echo "INSTALLED" || echo "MISSING"

echo ""
echo "=== Running export hook ==="
distrobox-enter "$CONTAINER" -- bash -c 'env XDG_DATA_DIRS=/usr/local/share:/usr/share XDG_DATA_HOME=/home/deck/.local/share /usr/local/bin/distrobox-export-hook.sh 2>&1'

echo ""
echo "=== Desktop files ==="
ls -la /home/deck/.local/share/applications/arch-pamac-*.desktop 2>/dev/null

echo ""
echo "=== Kickeraction ==="
cat /home/deck/.local/share/plasma/kickeractions/steamos-pamac-uninstall.desktop 2>/dev/null

echo ""
echo "=== Clearing old logs ==="
rm -f /home/deck/.local/share/steamos-pamac/arch-pamac/kickeraction-handler.log 2>/dev/null
rm -f /home/deck/.local/share/steamos-pamac/arch-pamac/uninstall-helper.log 2>/dev/null
echo "Logs cleared"
