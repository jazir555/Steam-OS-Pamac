#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

TMP_WRAPPER="/tmp/pamac-manager-wrapper-new"
cat > "$TMP_WRAPPER" << 'WRAPPER_SCRIPT'
#!/bin/bash
set +e

/usr/local/bin/pamac-session-bootstrap.sh >/dev/null 2>&1 || true

export DISPLAY=${DISPLAY:-:0}
DESKTOP_FILE="/home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop"

pamac-manager "$@" &
PAMAC_PID=$!

WAIT_MAX=30
WAITED=0
FOUND=0

while [[ $WAITED -lt $WAIT_MAX && $FOUND -eq 0 ]]; do
  sleep 2
  WAITED=$((WAITED + 2))
  for wid in $(xdotool search --class "pamac-manager" 2>/dev/null); do
    width=$(xwininfo -id "$wid" 2>/dev/null | awk '/Width:/{print $NF}')
    if [[ -n "$width" ]] && [[ "$width" -gt 1 ]]; then
      xprop -id "$wid" -f _KDE_NET_WM_DESKTOP_FILE 8u \
        -set _KDE_NET_WM_DESKTOP_FILE "$DESKTOP_FILE" 2>/dev/null
      echo "$(date): Set _KDE_NET_WM_DESKTOP_FILE on WID=$wid (width=$width)" >> /tmp/pamac-wrapper-debug.log
      FOUND=1
      break
    fi
  done
done

if [[ $FOUND -eq 0 ]]; then
  echo "$(date): TIMEOUT - no real window found in $WAIT_MAX seconds" >> /tmp/pamac-wrapper-debug.log
fi

wait "$PAMAC_PID" 2>/dev/null
WRAPPER_SCRIPT

podman cp "$TMP_WRAPPER" arch-pamac:/usr/local/bin/pamac-manager-wrapper
podman exec arch-pamac chmod +x /usr/local/bin/pamac-manager-wrapper

echo "=== Updated wrapper (timeout=30s) ==="
podman exec arch-pamac head -20 /usr/local/bin/pamac-manager-wrapper

rm -f "$TMP_WRAPPER"
echo ""
echo "=== Killing old pamac ==="
pkill -f pamac-manager 2>/dev/null || true

echo ""
echo "=== Launching fresh ==="
nohup /home/deck/.local/bin/pamac-manager-wrapper-host > /tmp/wrapper-host.log 2>&1 &
echo "Launched PID=$!"

sleep 20

echo ""
echo "=== Checking windows ==="
export DISPLAY=:0
export XAUTHORITY=$(ls -t /run/user/1000/xauth_* 2>/dev/null | head -1)
for wid in $(xdotool search --class "pamac-manager" 2>/dev/null); do
  width=$(xwininfo -id "$wid" 2>/dev/null | grep Width | awk '{print $2}')
  name=$(xprop -id "$wid" _NET_WM_NAME 2>/dev/null | cut -d'"' -f2)
  desktopfile=$(xprop -id "$wid" _KDE_NET_WM_DESKTOP_FILE 2>/dev/null)
  echo "WID=$wid width=$width name='$name'"
  echo "  _KDE=$desktopfile"
done

echo ""
echo "=== Debug log ==="
podman exec arch-pamac cat /tmp/pamac-wrapper-debug.log 2>/dev/null || echo "no debg log"