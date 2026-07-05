#!/bin/bash
export HOME=/home/deck

echo "=== Check for SteamOS reset scripts ==="
which steamos-desktop-reset 2>/dev/null || echo "no steamos-desktop-reset"
which steamos-dbus 2>/dev/null || echo "no steamos-dbus"
which steam 2>/dev/null || echo "no steam"

echo ""
echo "=== Check for SteamOS desktop config ==="
ls -la /usr/share/plasma/layout-templates/ 2>/dev/null | grep -i steam | head -5
ls -la /usr/share/plasma/shells/org.kde.plasma.desktop/contents/layouts/ 2>/dev/null | grep -i steam | head -5

echo ""
echo "=== KDE config check ==="
ls -la ~/.config/plasma-org.kde.plasma.desktop-appletsrc* 2>/dev/null | head -3