#!/bin/bash
set -e

# Fix pamac-daemon.service
printf '[D-BUS Service]\nName=org.manjaro.pamac.daemon\nExec=/usr/bin/pamac-daemon\n' > /usr/share/dbus-1/system-services/org.manjaro.pamac.daemon.service
echo 1_OK

# Fix PolicyKit1.service
printf '[D-BUS Service]\nName=org.freedesktop.PolicyKit1\nExec=/usr/lib/polkit-1/polkitd --no-debug\n' > /usr/share/dbus-1/system-services/org.freedesktop.PolicyKit1.service
echo 2_OK

# Kill everything
killall -9 pamac-daemon polkitd dbus-daemon 2>/dev/null || true
sleep 3

# Clean start
rm -f /run/dbus/pid
dbus-daemon --system --fork 2>&1 || true
sleep 2
/usr/lib/polkit-1/polkitd --no-debug 2>/dev/null &
sleep 3
/usr/bin/pamac-daemon 2>/dev/null &
sleep 3

# Verify
busctl --system list 2>&1
echo ===
pgrep -la pamac-daemon
