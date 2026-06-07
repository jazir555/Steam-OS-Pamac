#!/bin/bash
export HOME=/home/deck
export XAUTHORITY=/home/deck/.Xauthority
export DISPLAY=:0

echo "=== All windows from host ==="
xdotool search --onlyvisible --name '.' 2>&1 | while read wid; do
  name=$(xprop -id "$wid" _NET_WM_NAME 2>/dev/null | cut -d'"' -f2)
  wmclass=$(xprop -id "$wid" WM_CLASS 2>/dev/null)
  echo "WID=$wid NAME='$name' WM_CLASS=$wmclass"
done | head -20

echo ""
echo "=== Searching for Pamac ==="
xdotool search --onlyvisible --name '.' 2>&1 | while read wid; do
  name=$(xprop -id "$wid" _NET_WM_NAME 2>/dev/null | cut -d'"' -f2)
  wmclass=$(xprop -id "$wid" WM_CLASS 2>/dev/null)
  if echo "$name" | grep -qi pamac 2>/dev/null; then
    echo "=== PAMAC FOUND ==="
    echo "WID=$wid NAME='$name'"
    echo "WM_CLASS=$wmclass"
    xprop -id "$wid" _NET_WM_WINDOW_TYPE 2>/dev/null
    xprop -id "$wid" _NET_WM_STATE 2>/dev/null
    xprop -id "$wid" _KDE_NET_WM_DESKTOP_FILE 2>/dev/null
  fi
done

echo ""
echo "DONE"