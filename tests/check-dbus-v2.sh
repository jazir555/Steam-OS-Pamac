#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Session bus in container ==="
podman exec arch-pamac bash -c '
echo "Session bus address:"
echo "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-NOT_SET}"
echo ""
echo "Session bus socket:"
ls -la /run/user/1000/bus 2>/dev/null || echo "NOT FOUND"
ls -la $XDG_RUNTIME_DIR/bus 2>/dev/null || echo "runtime bus NOT FOUND"
echo ""
echo "Check dbus env:"
env | grep -i dbus 2>/dev/null || echo "no dbus env"
'

echo ""
echo "=== Pamac daemon check ==="
podman exec arch-pamac bash -c '
echo "pamac-daemon binary:"
which pamac-daemon 2>/dev/null || echo "NOT FOUND"
echo ""
echo "pamac systemd service:"
ls -la /usr/lib/systemd/system/pamac* 2>/dev/null || echo "no systemd service"
ls -la /etc/systemd/system/pamac* 2>/dev/null || echo "no etc systemd"
echo ""
echo "D-Bus pamac service files:"
ls -la /usr/share/dbus-1/system-services/org.manjaro.pamac* 2>/dev/null || echo "NOT FOUND"
ls -la /usr/share/dbus-1/services/org.manjaro.pamac* 2>/dev/null || echo "NOT FOUND"
'

echo ""
echo "=== Try starting pamac-daemon manually ==="
podman exec arch-pamac bash -c 'pamac-daemon --version 2>&1' || echo "no version"
podman exec arch-pamac pamac-daemon 2>&1 &
sleep 3
echo ""
echo "=== Check if daemon started ==="
podman exec arch-pamac bash -c 'pgrep -a pamac-daemon 2>/dev/null || echo "no daemon"'

echo ""
echo "DONE"