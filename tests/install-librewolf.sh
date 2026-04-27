#!/bin/bash
set -uo pipefail

export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Installing LibreWolf via pamac ==="

podman exec -i -u 0 arch-pamac bash -c '
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin
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

echo "Installing librewolf-bin from AUR..."
pamac install --no-confirm librewolf-bin 2>&1
echo "=== Install exit code: $? ==="

echo "=== Verifying installation ==="
pacman -Qs librewolf 2>&1
echo "=== Checking binary ==="
which librewolf 2>&1 || echo "librewolf binary not found"
echo "=== Checking desktop file in container ==="
find /usr/share/applications -name "*librewolf*" -o -name "*LibreWolf*" 2>/dev/null
echo "=== Checking desktop file on host ==="
' 2>&1

echo "=== Checking host-side desktop files ==="
ls -la /home/deck/.local/share/applications/ 2>&1 | grep -i libre
echo "=== Checking exported-apps list ==="
cat /home/deck/.local/share/steamos-pamac/arch-pamac/exported-apps.list 2>/dev/null
echo "=== Running export hook manually ==="
podman exec -i -u 0 arch-pamac /usr/local/bin/distrobox-export-hook.sh 2>&1
echo "=== Re-checking host desktop files ==="
ls -la /home/deck/.local/share/applications/ 2>&1 | grep -i libre
echo "=== Re-checking exported-apps list ==="
cat /home/deck/.local/share/steamos-pamac/arch-pamac/exported-apps.list 2>/dev/null
