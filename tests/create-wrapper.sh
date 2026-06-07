#!/bin/bash
export HOME=/home/deck

WRAPPER_PATH="/home/deck/.local/bin/pamac-manager-wrapper-host"
DESKTOP_FILE="/home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop"
CONTAINER="arch-pamac"
XAUTH="/run/user/1000/xauth_YlezhY"

cat > "$WRAPPER_PATH" << 'WRAPPER_EOF'
#!/bin/bash
export HOME=/home/deck
export DISPLAY=${DISPLAY:-:0}
export XAUTHORITY="${XAUTH:-/run/user/1000/xauth_YlezhY}"

DESKTOP_FILE="/home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop"
CONTAINER="arch-pamac"

# Launch Pamac in the background via distrobox
distrobox enter "$CONTAINER" -- pamac-manager-wrapper "$@" &
LAUNCHER_PID=$!

# Give GTK4 time to create its windows (placeholder + real window)
sleep 1

# Find all pamac-manager windows
WINDOW_IDS=$(XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xdotool search --class "pamac-manager" 2>/dev/null)

for wid in $WINDOW_IDS; do
  width=$(XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xwininfo -id "$wid" 2>/dev/null | awk -F': ' '/Width:/{print $2}')
  if [ "$width" = "1" ]; then
    # Hide the 1x1 placeholder from the taskbar
    XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xprop -id "$wid" \
      -f _NET_WM_STATE 32a \
      -set _NET_WM_STATE _NET_WM_STATE_SKIP_TASKBAR 2>/dev/null
  fi
  if [ "$width" != "1" ]; then
    # Associate the real window with our .desktop file
    XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xprop -id "$wid" \
      -f _KDE_NET_WM_DESKTOP_FILE 8u \
      -set _KDE_NET_WM_DESKTOP_FILE "$DESKTOP_FILE" 2>/dev/null
  fi
done

# Wait for Pamac to exit
wait "$LAUNCHER_PID" 2>/dev/null
WRAPPER_EOF

chmod +x "$WRAPPER_PATH"
echo "Created host-side wrapper: $WRAPPER_PATH"

# Update desktop file Exec to use the new host-side wrapper
sed -i 's|^Exec=.*|Exec=env XAUTHORITY=/run/user/1000/xauth_YlezhY '"$WRAPPER_PATH"' %U|' "$DESKTOP_FILE"
echo ""
grep -E '^(Exec|Startup)' "$DESKTOP_FILE"

# Rebuild sycoca so KDE picks up the new desktop file
kbuildsycoca6 --noincremental 2>&1 | tail -2
dbus-send --session --type=signal /KSycoca org.kde.KSycoca.databaseChanged 2>&1
echo "SYCOCA_DONE"
