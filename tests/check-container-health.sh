#!/bin/bash
echo "=== D-Bus ==="
which dbus-daemon 2>/dev/null || echo "dbus-daemon NOT FOUND"
ls /usr/share/dbus-1/system-services/org.manjaro.pamac* 2>/dev/null || echo "no pamac dbus services"
ls /usr/share/dbus-1/system.d/org.manjaro.pamac* 2>/dev/null || echo "no pamac dbus config"

echo "=== Polkit ==="
ls /usr/lib/polkit-1/polkitd 2>/dev/null || echo "polkitd NOT FOUND"
ls /usr/share/polkit-1/actions/org.manjaro.pamac* 2>/dev/null || echo "no pamac polkit actions"

echo "=== Pamac ==="
which pamac-daemon 2>/dev/null || echo "pamac-daemon NOT FOUND"
which pamac 2>/dev/null || echo "pamac CLI NOT FOUND"
grep -E '^EnableAUR|^BuildDirectory' /etc/pamac.conf 2>/dev/null || echo "pamac.conf missing settings"

echo "=== Fake systemd-run ==="
ls -la /usr/local/sbin/systemd-run 2>/dev/null || echo "fake systemd-run NOT FOUND"

echo "=== Build directory ==="
ls -la /home/deck/.pamac-build 2>/dev/null || echo "build dir NOT FOUND"

echo "=== D-Bus status ==="
rm -f /run/dbus/pid 2>/dev/null
mkdir -p /run/dbus
dbus-daemon --system --fork 2>/dev/null
sleep 1
ls /run/dbus/pid 2>/dev/null && echo "dbus running" || echo "dbus FAILED"

echo "=== Polkit status ==="
/usr/lib/polkit-1/polkitd --no-debug &>/dev/null &
sleep 1
pgrep polkitd >/dev/null && echo "polkit running" || echo "polkit FAILED"

echo "=== Pamac daemon status ==="
/usr/bin/pamac-daemon &>/dev/null &
sleep 2
pgrep pamac-daemon >/dev/null && echo "pamac-daemon running" || echo "pamac-daemon FAILED"

echo "=== Pamac test ==="
pamac search neofetch 2>&1 | head -3

echo "=== Pacman DB ==="
pacman -Dk 2>&1 | head -3

echo "=== Dev packages ==="
pacman -Q base-devel 2>/dev/null || echo "base-devel NOT installed"
pacman -Q git 2>/dev/null || echo "git NOT installed"
