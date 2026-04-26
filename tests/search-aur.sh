#!/bin/bash
set -uo pipefail

rm -f /run/dbus/pid 2>/dev/null
pkill pamac-daemon 2>/dev/null
pkill polkitd 2>/dev/null
pkill dbus-daemon 2>/dev/null
sleep 1
mkdir -p /run/dbus
dbus-daemon --system --fork 2>/dev/null
sleep 1
/usr/lib/polkit-1/polkitd --no-debug &>/dev/null &
sleep 1
/usr/bin/pamac-daemon &>/dev/null &
sleep 2

echo "=== ripgrep ==="
pamac search --aur ripgrep 2>/dev/null | grep "^ripgrep"
echo "=== bat ==="
pamac search --aur bat 2>/dev/null | grep "^bat[^a-z]"
echo "=== fd ==="
pamac search --aur fd 2>/dev/null | grep "^fd[^a-z]"
echo "=== github-cli ==="
pamac search --aur github-cli 2>/dev/null | grep "^github"
echo "=== ttf-ms ==="
pamac search --aur ttf-ms 2>/dev/null | grep "^ttf-ms"
echo "=== ttf-nerd ==="
pamac search --aur ttf-nerd 2>/dev/null | grep "^ttf-nerd"
echo "=== font packages ==="
pamac search --aur ttf-font 2>/dev/null | head -10
echo "=== DONE ==="
