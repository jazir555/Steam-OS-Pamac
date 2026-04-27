#!/bin/bash
set +e

CONTAINER="arch-pamac"
PACKAGES="librewolf-bin heroic-games-launcher-bin neofetch celluloid"

bootstrap_daemon() {
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
    '
}

echo "=== Reinstalling AUR apps via pamac ==="
echo "Packages: $PACKAGES"
echo ""

bootstrap_daemon

for pkg in $PACKAGES; do
    echo "--- Installing $pkg ---"
    podman exec -i -u 0 "$CONTAINER" bash -c "
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
        pamac install --no-confirm $pkg 2>&1
    "
    rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "SUCCESS: $pkg installed"
    else
        echo "FAILED: $pkg install (exit $rc)"
    fi
    echo ""
done

echo "=== Running export hook ==="
distrobox-enter "$CONTAINER" -- bash -c 'env XDG_DATA_DIRS=/usr/local/share:/usr/share XDG_DATA_HOME=/home/deck/.local/share /usr/local/bin/distrobox-export-hook.sh 2>&1'

echo ""
echo "=== Verifying installed packages ==="
for pkg in $PACKAGES; do
    if podman exec -i -u 0 "$CONTAINER" pacman -Q "$pkg" >/dev/null 2>&1; then
        echo "  INSTALLED: $pkg"
    else
        echo "  MISSING:   $pkg"
    fi
done

echo ""
echo "=== Checking exported desktop files ==="
ls -la /home/deck/.local/share/applications/arch-pamac-*.desktop 2>/dev/null || echo "  No exported desktop files found"

echo ""
echo "=== Checking kickeraction ==="
cat /home/deck/.local/share/plasma/kickeractions/steamos-pamac-uninstall.desktop 2>/dev/null || echo "  No kickeraction file found"

echo ""
echo "Done!"
