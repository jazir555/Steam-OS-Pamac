#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Xauthority files ==="
ls -la /home/deck/.Xauthority* 2>&1

echo ""
echo "=== X11 runtime files ==="
ls -la /run/user/1000/ 2>&1 | grep -i x11

echo ""
echo "=== Environment ==="
env | grep -iE 'XAUTHORITY|DISPLAY|WAYLAND'

echo ""
echo "=== Try with xauth ==="
xauth list 2>&1 | head -5

echo ""
echo "=== Try XDG_RUNTIME_DIR ==="
echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
ls -la "$XDG_RUNTIME_DIR" 2>&1 | head -10

echo ""
echo "=== Find actual Xauthority ==="
find /home/deck -name '.Xauthority*' 2>/dev/null
find /run -name '.Xauthority*' 2>/dev/null

echo ""
echo "=== Check if this is wayland session ==="
echo "XDG_SESSION_TYPE=$XDG_SESSION_TYPE"
echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
loginctl show-session self -p Type 2>/dev/null

echo ""
echo "DONE"