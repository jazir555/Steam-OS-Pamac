#!/bin/bash
export HOME=/home/deck

cat > /home/deck/.local/bin/pamac-manager-wrapper-host << 'WRAPPER_EOF'
#!/bin/bash
export HOME=/home/deck
export DISPLAY=${DISPLAY:-:0}

# ---- Dynamically find XAUTHORITY ----
if [[ -n "${XAUTH:-}" && -f "$XAUTH" ]]; then
  export XAUTHORITY="$XAUTH"
elif [[ -f "$HOME/.Xauthority" ]]; then
  export XAUTHORITY="$HOME/.Xauthority"
else
  newest_xauth=$(ls -t /run/user/$(id -u)/xauth_* 2>/dev/null | head -1)
  if [[ -n "$newest_xauth" && -f "$newest_xauth" ]]; then
    export XAUTHORITY="$newest_xauth"
  fi
fi

DESKTOP_FILE="$HOME/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop"
CONTAINER="arch-pamac"

# Launch Pamac in the background
distrobox enter "$CONTAINER" -- pamac-manager-wrapper "$@" &
LAUNCHER_PID=$!

# Poll for pamac-manager windows (up to 15 seconds)
WAIT_MAX=15
WAITED=0
FOUND=0
while [[ $WAITED -lt $WAIT_MAX && $FOUND -eq 0 ]]; do
  sleep 1
  WAITED=$((WAITED + 1))
  # Find all pamac-manager windows
  WINDOW_IDS=$(XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xdotool search --class "pamac-manager" 2>/dev/null)
  for wid in $WINDOW_IDS; do
    width=$(XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xwininfo -id "$wid" 2>/dev/null | awk -F': ' '/Width:/{print $2}')
    if [[ -n "$width" ]] && [[ "$width" != "1" ]]; then
      # Found a real window
      FOUND=1
    fi
  done
done

# Process all pamac-manager windows
for wid in $WINDOW_IDS; do
  width=$(XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xwininfo -id "$wid" 2>/dev/null | awk -F': ' '/Width:/{print $2}')
  if [ "$width" = "1" ]; then
    # Hide the 1x1 placeholder from the taskbar
    XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xprop -id "$wid" \
      -f _NET_WM_STATE 32a \
      -set _NET_WM_STATE _NET_WM_STATE_SKIP_TASKBAR 2>/dev/null
  elif [ -n "$width" ]; then
    # Associate the real window with our .desktop file
    XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xprop -id "$wid" \
      -f _KDE_NET_WM_DESKTOP_FILE 8u \
      -set _KDE_NET_WM_DESKTOP_FILE "$DESKTOP_FILE" 2>/dev/null
  fi
done

wait "$LAUNCHER_PID" 2>/dev/null
WRAPPER_EOF

chmod +x /home/deck/.local/bin/pamac-manager-wrapper-host
echo "Done. Wrapper now polls up to 15 seconds for windows."

echo ""
echo "Killing any running pamac-manager"
pkill -f "pamac-manager" 2>/dev/null || true
sleep 1

echo ""
echo "Launching Pamac via wrapper from SSH..."
# Run the wrapper and capture log
nohup /home/deck/.local/bin/pamac-manager-wrapper-host > /tmp/pamac-wrapper.log 2>&1 &
echo "Wrapper launched, PID=$!"
echo ""
echo "Waiting 5 seconds for windows..."
sleep 5

echo "=== Check windows now ==="
export XAUTHORITY=$(ls -t /run/user/1000/xauth_* 2>/dev/null | head -1)
export DISPLAY=:0
for wid in $(xdotool search --class "pamac-manager" 2>/dev/null); do
  width=$(xwininfo -id "$wid" 2>/dev/null | grep Width | awk '{print $2}')
  name=$(xprop -id "$wid" _NET_WM_NAME 2>/dev/null | cut -d'"' -f2)
  wmclass=$(xprop -id "$wid" WM_CLASS 2>/dev/null)
  desktopfile=$(xprop -id "$wid" _KDE_NET_WM_DESKTOP_FILE 2>/dev/null)
  state=$(xprop -id "$wid" _NET_WM_STATE 2>/dev/null)
  echo "WID=$wid width=$width name='$name'"
  echo "  WM_CLASS=$wmclass"
  echo "  _KDE_NET_WM_DESKTOP_FILE=$desktopfile"
  echo "  _NET_WM_STATE=$state"
done
echo "=== DONE ==="