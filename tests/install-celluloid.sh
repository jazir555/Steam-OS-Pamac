#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Starting pamac services ==="
podman exec arch-pamac bash -c '
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
echo "Services started, installing celluloid..."
pamac install --no-confirm celluloid 2>&1
'

echo ""
echo "=== Running export hook ==="
podman exec arch-pamac /usr/local/bin/distrobox-export-hook.sh </dev/null 2>/dev/null || true

echo ""
echo "=== Check if Celluloid desktop file exists ==="
ls -la ~/.local/share/applications/arch-pamac-*celluloid* 2>&1
