#!/bin/bash
set -euo pipefail

DESKTOP_FILE="/home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop"

if [[ ! -f "$DESKTOP_FILE" ]]; then
    echo "ERROR: Desktop file not found"
    exit 1
fi

echo "=== Current Name line ==="
grep '^Name=' "$DESKTOP_FILE"

echo "=== Renaming to 'Pamac' ==="
sed -i 's/^Name=Add\/Remove Software (on arch-pamac)$/Name=Pamac/' "$DESKTOP_FILE"
sed -i 's/^Comment=Manage packages inside the arch-pamac distrobox$/Comment=Add\/Remove Software/' "$DESKTOP_FILE"

echo "=== Updated Name line ==="
grep '^Name=' "$DESKTOP_FILE"
grep '^Comment=' "$DESKTOP_FILE"

echo "=== Rebuild sycoca cache ==="
export XDG_DATA_DIRS="/home/deck/.local/share:/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share"
kbuildsycoca6 --noincremental 2>/dev/null || true

echo "=== Send D-Bus databaseChanged signal ==="
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
dbus-send --session --type=signal /KSycoca org.kde.KSycoca.databaseChanged 2>/dev/null || true

echo "=== Done. Pamac should now appear as 'Pamac' in the KDE menu. ==="
