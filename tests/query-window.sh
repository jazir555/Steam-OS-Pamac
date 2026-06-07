#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
export DISPLAY=:0

echo "=== Find Xauthority files ==="
ls -la /run/user/1000/xauth_* 2>/dev/null
ls -la /run/pressure-vessel/Xauthority 2>/dev/null

echo ""
echo "=== Check which Xauthority works ==="
for XA in /run/user/1000/xauth_* /run/pressure-vessel/Xauthority; do
  if [ -f "$XA" ]; then
    result=$(XAUTHORITY="$XA" DISPLAY=:0 xdotool search --onlyvisible "." 2>&1 | head -1)
    if echo "$result" | grep -q '^[0-9]'; then
      echo "WORKING: $XA - found windows: $result"
      WORKING_XA="$XA"
    else
      echo "FAILED: $XA - $result"
    fi
  fi
done

if [ -n "${WORKING_XA:-}" ]; then
  echo ""
  echo "=== Using $WORKING_XA to find Pamac window ==="
  for wid in $(XAUTHORITY="$WORKING_XA" DISPLAY=:0 xdotool search --onlyvisible "." 2>/dev/null); do
    name=$(XAUTHORITY="$WORKING_XA" DISPLAY=:0 xprop -id "$wid" _NET_WM_NAME 2>/dev/null | cut -d'"' -f2)
    if echo "$name" | grep -qi pamac 2>/dev/null; then
      echo "=== PAMAC FOUND: WID=$wid ==="
      echo "NAME=$name"
      echo "WM_CLASS: $(XAUTHORITY="$WORKING_XA" DISPLAY=:0 xprop -id "$wid" WM_CLASS 2>/dev/null)"
      echo "WM_NAME: $(XAUTHORITY="$WORKING_XA" DISPLAY=:0 xprop -id "$wid" WM_NAME 2>/dev/null)"
      echo "NET_WM_WINDOW_TYPE: $(XAUTHORITY="$WORKING_XA" DISPLAY=:0 xprop -id "$wid" _NET_WM_WINDOW_TYPE 2>/dev/null)"
      echo "NET_WM_STATE: $(XAUTHORITY="$WORKING_XA" DISPLAY=:0 xprop -id "$wid" _NET_WM_STATE 2>/dev/null)"
      echo "KDE_NET_WM_DESKTOP_FILE: $(XAUTHORITY="$WORKING_XA" DISPLAY=:0 xprop -id "$wid" _KDE_NET_WM_DESKTOP_FILE 2>/dev/null)"
    fi
  done
fi

echo ""
echo "DONE"