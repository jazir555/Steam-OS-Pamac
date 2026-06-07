#!/bin/bash
export HOME=/home/deck
export DISPLAY=:0
XAUTH="/run/user/1000/xauth_YlezhY"

echo "=== Find all pamac windows ==="
for wid in $(XAUTHORITY="$XAUTH" xdotool search --class "pamac-manager" 2>/dev/null); do
  echo ""
  echo "=== PAMAC WINDOW: 0x$(printf '%x' $wid) ==="
  echo "WID decimal: $wid"
  XAUTHORITY="$XAUTH" xprop -id "$wid" WM_CLASS WM_NAME _NET_WM_NAME _NET_WM_WINDOW_TYPE _NET_WM_STATE 2>/dev/null
  XAUTHORITY="$XAUTH" xwininfo -id "$wid" 2>/dev/null | grep -E "Width|Height|Absolute|-geometry"
  echo "---"
done

echo ""
echo "=== Also check windows by name 'Add/Remove' ==="
for wid in $(XAUTHORITY="$XAUTH" xdotool search --name "Add/Remove" 2>/dev/null); do
  echo ""
  echo "=== ADD/REMOVE WINDOW: 0x$(printf '%x' $wid) ==="
  XAUTHORITY="$XAUTH" xprop -id "$wid" WM_CLASS WM_NAME _NET_WM_NAME 2>/dev/null
  XAUTHORITY="$XAUTH" xwininfo -id "$wid" 2>/dev/null | grep -E "Width|Height|Absolute"
  echo "---"
done

echo ""
echo "=== Check current window sizes ==="
XAUTHORITY="$XAUTH" xwininfo -root -tree 2>/dev/null | grep -A1 "pamac"

echo ""
echo "DONE"