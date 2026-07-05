#!/bin/bash
export HOME=/home/deck
export DISPLAY=:0
XAUTH=$(ls -t /run/user/1000/xauth_* 2>/dev/null | head -1)
export XAUTHORITY="$XAUTH"

echo "=== Pamac windows ==="
for wid in $(xdotool search --class "pamac-manager" 2>/dev/null); do
  width=$(xwininfo -id "$wid" 2>/dev/null | grep Width | awk '{print $2}')
  name=$(xprop -id "$wid" _NET_WM_NAME 2>/dev/null | cut -d'"' -f2)
  desktopfile=$(xprop -id "$wid" _KDE_NET_WM_DESKTOP_FILE 2>/dev/null)
  wmclass=$(xprop -id "$wid" WM_CLASS 2>/dev/null)
  echo "WID=$wid width=$width name='$name'"
  echo "  _KDE=$desktopfile"
  echo "  WM_CLASS=$wmclass"
done

echo ""
echo "=== Process check ==="
pgrep -a pamac 2>/dev/null || echo "no pamac process"