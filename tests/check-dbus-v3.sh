#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Check D-Bus service files ==="
podman exec arch-pamac bash -c '
cat /usr/share/dbus-1/system-services/org.manjaro.pamac.daemon.service
echo "---"
cat /usr/share/dbus-1/services/org.manjaro.pamac.manager.service
'

echo ""
echo "=== Check pamac-daemon systemd service ==="
podman exec arch-pamac bash -c '
cat /usr/lib/systemd/system/pamac-daemon.service
'

echo ""
echo "=== Test D-Bus connection ==="
podman exec -e DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus arch-pamac bash -c '
echo "Testing session bus:"
dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>&1 | head -5
'

echo ""
echo "=== Test system bus ==="
podman exec arch-pamac bash -c '
echo "Testing system bus:"
dbus-send --system --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>&1 | head -5
'