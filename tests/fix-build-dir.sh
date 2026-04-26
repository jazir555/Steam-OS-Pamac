#!/bin/bash
# Fix pamac build directory and test install
sed -i 's|^BuildDirectory = /var/tmp|BuildDirectory = /home/deck/.pamac-build|' /etc/pamac.conf
mkdir -p /home/deck/.pamac-build
chown deck:deck /home/deck/.pamac-build
echo "Build directory changed to /home/deck/.pamac-build"
grep BuildDirectory /etc/pamac.conf

# Kill existing services
pkill pamac-daemon 2>/dev/null
pkill polkitd 2>/dev/null  
pkill dbus-daemon 2>/dev/null
sleep 1
rm -f /run/dbus/pid

# Start services fresh
mkdir -p /run/dbus
dbus-daemon --system --fork
sleep 1
/usr/lib/polkit-1/polkitd --no-debug &>/dev/null &
sleep 1
/usr/bin/pamac-daemon &>/dev/null &
sleep 2

echo "Services started, testing pamac install as root..."
timeout 120 pamac install --no-confirm neofetch 2>&1 | tail -20
echo "EXIT_CODE=$?"
pacman -Q neofetch 2>/dev/null && echo "NEOFETCH_INSTALLED" || echo "NEOFETCH_NOT_INSTALLED"
