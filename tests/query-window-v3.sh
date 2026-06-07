#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
export DISPLAY=:0
XAUTH="/run/user/1000/xauth_YlezhY"

echo "Using XAUTHORITY=$XAUTH"
echo ""

echo "=== Try searching all windows by name .* ==="
XAUTHORITY="$XAUTH" xdotool search --onlyvisible --name ".*" 2>&1 | head -20

echo ""
echo "=== Try search by class .* ==="
XAUTHORITY="$XAUTH" xdotool search --onlyvisible --class ".*" 2>&1 | head -20

echo ""
echo "=== Try getactivewindow ==="
XAUTHORITY="$XAUTH" xdotool getactivewindow 2>&1
XAUTHORITY="$XAUTH" xdotool getactivewindow getwindowname 2>&1

echo ""
echo "=== Try xwininfo ==="
XAUTHORITY="$XAUTH" xwininfo -root -tree 2>&1 | head -30

echo ""
echo "DONE"