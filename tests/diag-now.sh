#!/bin/bash
export HOME=/home/deck
export DISPLAY=:0
XAUTH=$(ls -t /run/user/1000/xauth_* 2>/dev/null | head -1)
export XAUTHORITY="$XAUTH"

echo "XAUTHORITY=$XAUTHORITY"
echo ""

echo "=== Total windows ==="
xdotool search "" 2>&1 | wc -l

echo ""
echo "=== Search pamac class ==="
xdotool search --class pamac-manager 2>&1

echo ""
echo "=== Active window ==="
xdotool getactivewindow 2>&1

echo ""
echo "=== xwininfo root ==="
xwininfo -root -tree 2>&1 | head -40 | tail -30