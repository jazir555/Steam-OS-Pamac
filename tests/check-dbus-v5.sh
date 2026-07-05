#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Test pamac-daemon with session bus ==="
podman exec -e DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  arch-pamac timeout 3 /usr/bin/pamac-daemon 2>&1 || true

echo ""
echo "=== Test dbus-send --system from container ==="
podman exec arch-pamac dbus-send --system --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>&1 | head -5

echo ""
echo "=== Check if pamac-daemon uses system or session bus ==="
podman exec arch-pamac strings /usr/bin/pamac-daemon 2>/dev/null | grep -i "session_bus\|system_bus\|dbus_bus\|get_bus" | head -5

echo ""
echo "=== Check if container session bus works from /tmp socket ==="
podman exec arch-pamac bash -c '
SOCK=$(ls /tmp/dbus-* 2>/dev/null | head -1)
echo "Session socket: $SOCK"
if [ -n "$SOCK" ]; then
  DBUS_SESSION_BUS_ADDRESS="unix:path=$SOCK" dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>&1 | head -5
fi
'

echo ""
echo "DONE"