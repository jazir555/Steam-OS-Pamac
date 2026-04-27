#!/bin/bash
set -uo pipefail

export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

echo "=== Rebuilding KDE service cache ==="
kbuildsycoca6 --noincremental 2>&1

echo "=== Reloading plasmashell ==="
dbus-send --session --type=method_call --dest=org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.refreshKeystate 2>/dev/null || true

echo "=== Checking if LibreWolf appears in kmenu ==="
kmenusearch=$(kbuildsycoca6 --noincremental 2>&1)
echo "$kmenusearch" | tail -5

echo "=== Using kioclient to verify desktop file is visible ==="
kioclient6 ls applications:/// 2>/dev/null | grep -i libre || echo "LibreWolf not found in applications:///"

echo "=== Checking desktop file validity ==="
desktop-file-validate /home/deck/.local/share/applications/arch-pamac-librewolf.desktop 2>&1 || echo "Validation errors found"

echo "=== Forcing KDE to re-read desktop files ==="
qdbus6 org.kde.kbuildsycoca / org.kde.kbuildsycoca.rebuild 2>&1 || echo "qdbus6 rebuild not available"

echo "=== Checking if KDE can find LibreWolf via kservice ==="
ksvcquery6 --entry arch-pamac-librewolf 2>&1 || echo "ksvcquery6 not available or entry not found"

echo "=== Done ==="
