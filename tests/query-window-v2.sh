#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
export DISPLAY=:0

XAUTH="/run/user/1000/xauth_YlezhY"
echo "Using XAUTHORITY=$XAUTH"

echo ""
echo "=== Count total windows ==="
XAUTHORITY="$XAUTH" xdotool search "" 2>&1 | wc -l

echo ""
echo "=== Search for pamac (all windows) ==="
XAUTHORITY="$XAUTH" xdotool search --name "Pamac" 2>&1
XAUTHORITY="$XAUTH" xdotool search --class "pamac" 2>&1
XAUTHORITY="$XAUTH" xdotool search --classname "pamac-manager" 2>&1
XAUTHORITY="$XAUTH" xdotool search --classname "org.manjaro.pamac.manager" 2>&1

echo ""
echo "=== Get window IDs and check all ==="
for wid in $(XAUTHORITY="$XAUTH" xdotool search "" 2>/dev/null | head -30); do
  name=$(XAUTHORITY="$XAUTH" xprop -id "$wid" WM_NAME 2>/dev/null)
  wmclass=$(XAUTHORITY="$XAUTH" xprop -id "$wid" WM_CLASS 2>/dev/null)
  netname=$(XAUTHORITY="$XAUTH" xprop -id "$wid" _NET_WM_NAME 2>/dev/null)
  echo "WID=$wid WM_NAME=$name WM_CLASS=$wmclass NET_WM_NAME=$netname"
  echo "---"
done

echo ""
echo "DONE"