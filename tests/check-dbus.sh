#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Check D-Bus in container ==="
podman exec arch-pamac bash -c '
echo "System bus socket:"
ls -la /var/run/dbus/system_bus_socket 2>/dev/null || echo "NOT FOUND"
ls -la /run/dbus/system_bus_socket 2>/dev/null || echo "NOT FOUND"
echo ""
echo "Session bus:"
echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"
echo ""
echo "Running D-Bus daemons:"
pgrep -a dbus 2>/dev/null || echo "no dbus daemon"
echo ""
echo "Polkit:"
pgrep -a polkit 2>/dev/null || echo "no polkit"
echo ""
echo "Pamac daemon:"
pgrep -a pamac 2>/dev/null || echo "no pamac daemon"
'

echo ""
echo "=== Check host D-Bus ==="
ls -la /var/run/dbus/system_bus_socket 2>/dev/null
ls -la /run/dbus/system_bus_socket 2>/dev/null
ls -la /run/user/1000/bus 2>/dev/null

echo ""
echo "=== Check if container has dbus service ==="
podman exec arch-pamac bash -c '
systemctl list-units --type=service 2>/dev/null | grep -i dbus || echo "no systemd dbus"
'

echo ""
echo "DONE"