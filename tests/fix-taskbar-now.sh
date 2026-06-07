#!/bin/bash
export HOME=/home/deck
export DISPLAY=:0
XAUTH="/run/user/1000/xauth_YlezhY"

echo "=== Fixing Pamac taskbar NOW ==="

echo ""
echo "=== Step 1: Find 1x1 placeholder window and skip taskbar ==="
for wid in $(XAUTHORITY="$XAUTH" xdotool search --class "pamac-manager" 2>/dev/null); do
  width=$(XAUTHORITY="$XAUTH" xwininfo -id "$wid" 2>/dev/null | grep Width | awk '{print $2}')
  if [ "$width" = "1" ]; then
    echo "Found placeholder window $wid (1x1 px)"
    XAUTHORITY="$XAUTH" xprop -id "$wid" -f _NET_WM_STATE 32a -set _NET_WM_STATE _NET_WM_STATE_SKIP_TASKBAR 2>/dev/null
    echo "  Set SKIP_TASKBAR"
  fi
done

echo ""
echo "=== Step 2: Set KDE desktop file on real window ==="
DESKTOP_FILE="/home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop"
for wid in $(XAUTHORITY="$XAUTH" xdotool search --class "pamac-manager" 2>/dev/null); do
  width=$(XAUTHORITY="$XAUTH" xwininfo -id "$wid" 2>/dev/null | grep Width | awk '{print $2}')
  if [ "$width" != "1" ]; then
    echo "Found real window $wid (${width}x...) — setting desktop file property"
    XAUTHORITY="$XAUTH" xprop -id "$wid" -f _KDE_NET_WM_DESKTOP_FILE 8u -set _KDE_NET_WM_DESKTOP_FILE "$DESKTOP_FILE" 2>/dev/null
    echo "  _KDE_NET_WM_DESKTOP_FILE set"
  fi
done

echo ""
echo "=== Verify ==="
for wid in $(XAUTHORITY="$XAUTH" xdotool search --class "pamac-manager" 2>/dev/null); do
  echo "Window $wid:"
  XAUTHORITY="$XAUTH" xwininfo -id "$wid" 2>/dev/null | grep -E "Width|Height"
  XAUTHORITY="$XAUTH" xprop -id "$wid" _KDE_NET_WM_DESKTOP_FILE _NET_WM_STATE 2>/dev/null
  echo "---"
done

echo ""
echo "DONE - check taskbar now"
