#!/bin/bash
set +e

echo "=== Deploying fixed export hook to container ==="
podman cp /tmp/distrobox-export-hook.sh arch-pamac:/usr/local/bin/distrobox-export-hook.sh 2>&1
podman exec -i arch-pamac chmod +x /usr/local/bin/distrobox-export-hook.sh 2>&1

echo "=== Verifying hook fix ==="
podman exec -i arch-pamac grep -n 'stripped=' /usr/local/bin/distrobox-export-hook.sh 2>&1

echo "=== Removing old broken LibreWolf desktop file ==="
rm -f /home/deck/.local/share/applications/arch-pamac-librewolf.desktop 2>&1

echo "=== Re-running export hook ==="
podman exec -i -u 0 arch-pamac /usr/local/bin/distrobox-export-hook.sh 2>&1

echo "=== Checking LibreWolf Actions line ==="
grep '^Actions=' /home/deck/.local/share/applications/arch-pamac-librewolf.desktop 2>&1

echo "=== Running desktop-file-validate ==="
desktop-file-validate /home/deck/.local/share/applications/arch-pamac-librewolf.desktop 2>&1
RC=$?
if [[ $RC -eq 0 ]]; then
    echo "PASS: desktop-file-validate reports no errors"
else
    echo "FAIL: desktop-file-validate exit code $RC"
fi

echo "=== Checking kickeraction ==="
cat /home/deck/.local/share/plasma/kickeractions/steamos-pamac-uninstall.desktop 2>&1

echo "=== Rebuilding KDE cache ==="
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export XDG_DATA_DIRS=/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share
export XDG_CURRENT_DESKTOP=KDE
kbuildsycoca6 --noincremental 2>&1
echo "kbuildsycoca6 done"

echo "=== Done ==="
