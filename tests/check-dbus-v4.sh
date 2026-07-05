#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Check D-Bus socket details ==="
podman exec arch-pamac bash -c '
echo "System bus socket (readlink):"
readlink -f /var/run/dbus/system_bus_socket 2>/dev/null
readlink -f /run/dbus/system_bus_socket 2>/dev/null
echo ""
echo "Session bus socket:"
ls -la /run/user/1000/bus 2>/dev/null
echo ""
echo "Check if dbus-broker is listening:"
ss -x -a 2>/dev/null | grep -i dbus || echo "no matching sockets"
echo ""
echo "Check socket inode:"
stat /run/dbus/system_bus_socket 2>/dev/null | grep Inode
stat /run/user/1000/bus 2>/dev/null | grep Inode
'

echo ""
echo "=== Host sockets ==="
stat /run/dbus/system_bus_socket 2>/dev/null | grep Inode
stat /run/user/1000/bus 2>/dev/null | grep Inode

echo ""
echo "=== Try starting pamac-daemon with system bus ==="
podman exec -e DBUS_SYSTEM_BUS_ADDRESS=unix:path=/var/run/dbus/system_bus_socket arch-pamac timeout 3 /usr/bin/pamac-daemon 2>&1 || echo "daemon start attempted"

echo ""
echo "DONE"