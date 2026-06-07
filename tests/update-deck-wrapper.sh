#!/bin/bash
export HOME=/home/deck

GUI_WRAPPER="/home/deck/.local/bin/pamac-manager-wrapper-host"

cat > "$GUI_WRAPPER" << 'WRAPPER_EOF'
#!/bin/bash
export HOME=/home/deck
export DISPLAY=${DISPLAY:-:0}

# Dynamically find the XAUTHORITY for the current desktop session
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

distrobox enter "$CONTAINER" -- pamac-manager-wrapper "$@" &
LAUNCHER_PID=$!

sleep 1

WINDOW_IDS=$(XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xdotool search --class "pamac-manager" 2>/dev/null)

for wid in $WINDOW_IDS; do
  width=$(XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xwininfo -id "$wid" 2>/dev/null | awk -F': ' '/Width:/{print $2}')
  if [ "$width" = "1" ]; then
    XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xprop -id "$wid" \
      -f _NET_WM_STATE 32a \
      -set _NET_WM_STATE _NET_WM_STATE_SKIP_TASKBAR 2>/dev/null
  fi
  if [ "$width" != "1" ]; then
    XAUTHORITY="$XAUTHORITY" DISPLAY="$DISPLAY" xprop -id "$wid" \
      -f _KDE_NET_WM_DESKTOP_FILE 8u \
      -set _KDE_NET_WM_DESKTOP_FILE "$DESKTOP_FILE" 2>/dev/null
  fi
done

wait "$LAUNCHER_PID" 2>/dev/null
WRAPPER_EOF

chmod +x "$GUI_WRAPPER"
echo "Updated wrapper with dynamic XAUTHORITY detection"

echo ""
echo "Fixing desktop file Exec line"
sed -i '1,/^Exec=/s|^Exec=.*|Exec=/home/deck/.local/bin/pamac-manager-wrapper-host %U|' /home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop

echo ""
grep '^Exec=' /home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop