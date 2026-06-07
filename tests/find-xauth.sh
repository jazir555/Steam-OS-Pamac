#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Find Xwayland process ==="
ps aux | grep Xwayland | grep -v grep | head -3

echo ""
echo "=== Extract auth file from Xwayland ==="
XAUTH=$(ps aux | grep Xwayland | grep -v grep | sed -n 's/.*-auth \([^ ]*\).*/\1/p' | head -1)
echo "XAUTH=$XAUTH"

echo ""
echo "=== Check if auth file exists ==="
if [ -n "$XAUTH" ] && [ -f "$XAUTH" ]; then
  echo "Auth file found!"

  echo ""
  echo "=== Test xdotool with XAUTHORITY ==="
  XAUTHORITY="$XAUTH" DISPLAY=:0 xdotool search --onlyvisible "." 2>&1 | head -10

  echo ""
  echo "=== Find Pamac window ==="
  for wid in $(XAUTHORITY="$XAUTH" DISPLAY=:0 xdotool search --onlyvisible "." 2>/dev/null); do
    name=$(XAUTHORITY="$XAUTH" DISPLAY=:0 xprop -id "$wid" _NET_WM_NAME 2>/dev/null | cut -d'"' -f2)
    wmclass=$(XAUTHORITY="$XAUTH" DISPLAY=:0 xprop -id "$wid" WM_CLASS 2>/dev/null)
    if echo "$name" | grep -qi pamac 2>/dev/null; then
      echo "=== PAMAC FOUND ==="
      echo "WID=$wid"
      echo "NAME=$name"
      echo "WM_CLASS=$wmclass"
      XAUTHORITY="$XAUTH" DISPLAY=:0 xprop -id "$wid" _NET_WM_WINDOW_TYPE 2>/dev/null
      XAUTHORITY="$XAUTH" DISPLAY=:0 xprop -id "$wid" _NET_WM_STATE 2>/dev/null
      XAUTHORITY="$XAUTH" DISPLAY=:0 xprop -id "$wid" _KDE_NET_WM_DESKTOP_FILE 2>/dev/null
      XAUTHORITY="$XAUTH" DISPLAY=:0 xprop -id "$wid" WM_NAME 2>/dev/null
    fi
  done
else
  echo "Auth file not found"
fi

echo ""
echo "DONE"