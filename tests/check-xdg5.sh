#!/bin/bash
set -euo pipefail

echo "=== Testing: Can we trigger kbuildsycoca6 via D-Bus from the desktop session? ==="

# Try to call kbuildsycoca6 rebuild via D-Bus (KSycoca uses D-Bus to notify apps)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/1000

# First, import the correct XDG_DATA_DIRS
export XDG_DATA_DIRS="/home/deck/.local/share:/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share"
systemctl --user import-environment XDG_DATA_DIRS

echo "systemd env after import:"
systemctl --user show-environment | grep '^XDG_DATA_DIRS='

echo ""
echo "=== Rebuilding sycoca with correct XDG_DATA_DIRS ==="
XDG_DATA_DIRS="/home/deck/.local/share:/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share" kbuildsycoca6 --noincremental 2>&1 | tail -3

echo ""
echo "=== Notify plasmashell via D-Bus to reload ==="
# Try the KSycoca D-Bus signal
dbus-send --session --type=signal /KSycoca org.kde.KSycoca.databaseChanged 2>&1 || echo "D-Bus signal failed"

echo ""
echo "=== Alternative: Use qdbus to notify ==="
qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.refreshCurrentShell 2>&1 || echo "qdbus refresh failed (expected - this may crash plasmashell)"

echo ""
echo "=== Check: Which sycoca cache file does plasmashell use? ==="
PLASMA_PID=$(pgrep -x plasmashell)
if [[ -n "$PLASMA_PID" ]]; then
    PLASMA_XDG=$(cat /proc/"$PLASMA_PID"/environ 2>/dev/null | tr '\0' '\n' | grep '^XDG_DATA_DIRS=' | sed 's/XDG_DATA_DIRS=//')
    echo "plasmashell XDG_DATA_DIRS: $PLASMA_XDG"
    
    # Calculate the sycoca cache hash
    # KDE uses a hash of XDG_DATA_DIRS for the cache filename
    CACHE_DIR=$(cat /proc/"$PLASMA_PID"/environ 2>/dev/null | tr '\0' '\n' | grep '^XDG_CACHE_HOME=' | sed 's/XDG_CACHE_HOME=//' || echo "/home/deck/.cache")
    echo "plasmashell cache dir: $CACHE_DIR"
    
    # List all ksycoca cache files
    find /home/deck/.cache/ -name 'ksycoca*' 2>/dev/null | while read f; do
        echo "  $f (modified: $(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null))"
    done
fi
