#!/bin/bash
set +e

PKG="$1"

echo "Installing $PKG via pamac..."

podman exec -i -u 0 arch-pamac bash -c '
rm -f /run/dbus/pid 2>/dev/null
pkill pamac-daemon 2>/dev/null
pkill polkitd 2>/dev/null
pkill dbus-daemon 2>/dev/null
sleep 1
mkdir -p /run/dbus
dbus-daemon --system --fork 2>/dev/null
sleep 1
/usr/lib/polkit-1/polkitd --no-debug &>/dev/null &
sleep 1
/usr/bin/pamac-daemon &>/dev/null &
sleep 2
pamac install --no-confirm '"$PKG"' 2>&1
'

echo "Checking if $PKG is installed in container..."
podman exec -i -u 0 arch-pamac bash -c 'pacman -Q '"$PKG"' 2>/dev/null && echo "SUCCESS: '"$PKG"' installed" || echo "FAILED: '"$PKG"' not installed"'
