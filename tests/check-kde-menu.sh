#!/bin/bash
set +e

export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export XDG_CURRENT_DESKTOP=KDE
export XDG_DATA_DIRS=/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share
export XDG_DATA_HOME=/home/deck/.local/share

echo "=== Checking if LibreWolf is in mimeinfo.cache ==="
grep -i libre /home/deck/.local/share/applications/mimeinfo.cache 2>/dev/null | head -5 || echo "Not in mimeinfo.cache"

echo "=== Checking desktop file key fields ==="
if [[ -f /home/deck/.local/share/applications/arch-pamac-librewolf.desktop ]]; then
    echo "Desktop file exists"
    grep -E '^(Name=|Type=|Exec=|NoDisplay=|Hidden=|Categories=|Actions=)' /home/deck/.local/share/applications/arch-pamac-librewolf.desktop | head -10
else
    echo "FAIL: Desktop file missing"
fi

echo "=== Validate ==="
desktop-file-validate /home/deck/.local/share/applications/arch-pamac-librewolf.desktop 2>&1
echo "EXIT: $?"

echo "=== Checking kickeraction ==="
cat /home/deck/.local/share/plasma/kickeractions/steamos-pamac-uninstall.desktop 2>&1

echo "=== Check ksycoca cache timestamp ==="
ls -la /home/deck/.cache/ksycoca6_* 2>/dev/null || echo "No ksycoca6 cache found"

echo "=== Checking menu structure ==="
ls /home/deck/.config/menus/ 2>&1 || echo "No menus dir"

echo "=== Done ==="
