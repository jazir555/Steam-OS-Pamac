#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Deploying fixed appstream handler ==="
cp /tmp/steamos-pamac-appstream-handler "$HOME/.local/bin/steamos-pamac-appstream-handler"
chmod +x "$HOME/.local/bin/steamos-pamac-appstream-handler"
echo "Deployed"

echo ""
echo "=== Verify handler has HOME/PATH ==="
head -6 "$HOME/.local/bin/steamos-pamac-appstream-handler"

echo ""
echo "=== Reinstall Celluloid for testing ==="
podman exec arch-pamac bash -c '
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
pamac install --no-confirm celluloid 2>&1
'

echo ""
echo "=== Run export hook ==="
podman exec arch-pamac /usr/local/bin/distrobox-export-hook.sh </dev/null 2>/dev/null || true

echo ""
echo "=== Refresh caches ==="
update-desktop-database ~/.local/share/applications 2>/dev/null
rm -f ~/.cache/ksycoca6* 2>/dev/null
kbuildsycoca6 2>&1 | tail -2

echo ""
echo "=== Verify Celluloid is back ==="
ls -la ~/.local/share/applications/arch-pamac-*celluloid* 2>&1
