#!/bin/bash
export HOME=/home/deck
export DISPLAY=:0
XAUTH="/run/user/1000/xauth_YlezhY"

echo "=== Pamac window details ==="
XAUTHORITY="$XAUTH" xprop -id 0x3800002 2>/dev/null

echo ""
echo "=== Check child windows of 0x3800002 ==="
XAUTHORITY="$XAUTH" xwininfo -id 0x3800002 -children 2>/dev/null | head -30

echo ""
echo "=== Check all pamac-related windows ==="
XAUTHORITY="$XAUTH" xwininfo -root -tree 2>/dev/null | grep -B2 -A5 "pamac"

echo ""
echo "=== Check if there are multiple pamac windows ==="
XAUTHORITY="$XAUTH" xdotool search --class "pamac-manager" 2>&1
XAUTHORITY="$XAUTH" xdotool search --classname "pamac-manager" 2>&1

echo ""
echo "=== Get active window ==="
ACTIVE=$(XAUTHORITY="$XAUTH" xdotool getactivewindow 2>/dev/null)
echo "Active window: $ACTIVE"
XAUTHORITY="$XAUTH" xprop -id "$ACTIVE" WM_CLASS _NET_WM_NAME WM_NAME 2>/dev/null

echo ""
echo "DONE"