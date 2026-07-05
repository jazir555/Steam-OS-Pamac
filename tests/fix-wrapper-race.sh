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

# Record EXISTING pamac-manager windows BEFORE launching new instance
OLD_WINDOWS=$(XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xdotool search --class "pamac-manager" 2>/dev/null | sort)

# Launch Pamac in the background via distrobox
distrobox enter "$CONTAINER" -- pamac-manager-wrapper "$@" &
LAUNCHER_PID=$!

# Poll for NEW pamac-manager windows (up to 15 seconds)
WAIT_MAX=15
WAITED=0
FOUND=0
while [[ $WAITED -lt $WAIT_MAX && $FOUND -eq 0 ]]; do
  sleep 1
  WAITED=$((WAITED + 1))
  CURRENT_WINDOWS=$(XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xdotool search --class "pamac-manager" 2>/dev/null | sort)
  # Check for NEW windows (not in OLD_WINDOWS)
  NEW_WINDOWS=$(comm -13 <(echo "$OLD_WINDOWS") <(echo "$CURRENT_WINDOWS") 2>/dev/null)
  if [[ -n "$NEW_WINDOWS" ]]; then
    FOUND=1
    # Verify at least one new window has a real size (>1)
    for wid in $NEW_WINDOWS; do
      width=$(XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xwininfo -id "$wid" 2>/dev/null | awk -F': ' '/Width:/{print $2}')
      if [[ -n "$width" ]] && [[ "$width" != "1" ]]; then
        FOUND=2
        break
      fi
    done
    if [[ $FOUND -ne 2 ]]; then
      FOUND=0  # Keep polling if no real window found yet
    else
      CURRENT_WINDOWS="$NEW_WINDOWS"
    fi
  fi
done

# Process ALL current pamac-manager windows (fix taskbar)
ALL_WINDOWS=$(XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xdotool search --class "pamac-manager" 2>/dev/null)
for wid in $ALL_WINDOWS; do
  width=$(XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xwininfo -id "$wid" 2>/dev/null | awk -F': ' '/Width:/{print $2}')
  if [ "$width" = "1" ]; then
    XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xprop -id "$wid" \
      -f _NET_WM_STATE 32a \
      -set _NET_WM_STATE _NET_WM_STATE_SKIP_TASKBAR 2>/dev/null
  elif [ -n "$width" ]; then
    XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xprop -id "$wid" \
      -f _KDE_NET_WM_DESKTOP_FILE 8u \
      -set _KDE_NET_WM_DESKTOP_FILE "$DESKTOP_FILE" 2>/dev/null
  fi
done

wait "$LAUNCHER_PID" 2>/dev/null
WRAPPER_EOF

chmod +x /home/deck/.local/bin/pamac-manager-wrapper-host
echo "Wrapper updated with new-window detection"