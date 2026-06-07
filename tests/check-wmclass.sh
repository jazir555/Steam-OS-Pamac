#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Check if pamac-manager is running ==="
pgrep -a pamac

echo ""
echo "=== Check any pamac-related windows (xprop) ==="
export DISPLAY=:0
xdotool search --name pamac 2>/dev/null | head -5 | while read wid; do
  echo "Window $wid:"
  xprop -id "$wid" WM_CLASS 2>/dev/null
  xprop -id "$wid" _NET_WM_NAME 2>/dev/null
  echo "---"
done

echo ""
echo "=== Check all window classes on display ==="
xdotool search --onlyvisible --name "" 2>/dev/null | head -20 | while read wid; do
  name=$(xprop -id "$wid" _NET_WM_NAME 2>/dev/null | awk -F'"' '{print $2}')
  wmclass=$(xprop -id "$wid" WM_CLASS 2>/dev/null)
  if echo "$name" | grep -qi pamac 2>/dev/null; then
    echo "WID=$wid NAME='$name' WM_CLASS=$wmclass"
  fi
done

echo ""
echo "DONE"