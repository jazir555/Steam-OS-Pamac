#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Check if Wayland is running ==="
echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
echo "XDG_SESSION_TYPE=$XDG_SESSION_TYPE"
echo "DISPLAY=$DISPLAY"

echo ""
echo "=== Check KWin process ==="
ps aux | grep -i kwin | grep -v grep | head -5

echo ""
echo "=== Check for X socket ==="
ls -la /tmp/.X11-unix/

echo ""
echo "=== Try xauth list ==="
xauth list 2>&1 | head -5

echo ""
echo "=== Try with XAUTHORITY from environment ==="
# Check running processes for XAUTHORITY
cat /proc/*/environ 2>/dev/null | tr '\0' '\n' | grep -a XAUTHORITY | sort -u | head -5

echo ""
echo "=== Check xdg runtime dir ==="
ls -la "$XDG_RUNTIME_DIR" 2>/dev/null | head -10

echo ""
echo "=== Find any .Xauthority files ==="
find /run/user -name ".Xauthority*" 2>/dev/null
find /home -name ".Xauthority*" 2>/dev/null
find /tmp -name "xauth*" 2>/dev/null

echo ""
echo "=== Try kreadconfig for display info ==="
kreadconfig5 --file startkderc --group General --key display 2>/dev/null || echo "no startkderc"

echo ""
echo "DONE"