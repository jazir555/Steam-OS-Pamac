#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Killing running pamac ==="
pkill -f "pamac-manager" 2>/dev/null || true
sleep 2

echo ""
echo "=== Verify no pamac running ==="
pgrep -a pamac-manager 2>/dev/null || echo "none"

echo ""
echo "=== Launching via host wrapper in background ==="
nohup /home/deck/.local/bin/pamac-manager-wrapper-host > /tmp/wrapper-host.log 2>&1 &
echo "Launched PID=$!"

sleep 8

echo ""
echo "=== Check for windows ==="
export DISPLAY=:0
export XAUTHORITY=$(ls -t /run/user/1000/xauth_* 2>/dev/null | head -1)
for wid in $(xdotool search --class "pamac-manager" 2>/dev/null); do
  width=$(xwininfo -id "$wid" 2>/dev/null | grep Width | awk '{print $2}')
  name=$(xprop -id "$wid" _NET_WM_NAME 2>/dev/null | cut -d'"' -f2)
  desktopfile=$(xprop -id "$wid" _KDE_NET_WM_DESKTOP_FILE 2>/dev/null)
  state=$(xprop -id "$wid" _NET_WM_STATE 2>/dev/null)
  echo "WID=$wid width=$width name='$name'"
  echo "  _KDE_NET_WM_DESKTOP_FILE=$desktopfile"
  echo "  _NET_WM_STATE=$state"
done

echo ""
echo "=== Host wrapper log ==="
tail -5 /tmp/wrapper-host.log 2>/dev/null || echo "no log"