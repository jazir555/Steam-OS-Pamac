#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Updating container's pamac-manager-wrapper ==="
podman exec arch-pamac bash -c '
cat > /usr/local/bin/pamac-manager-wrapper << INNER_EOF
#!/bin/bash
set +e

/usr/local/bin/pamac-session-bootstrap.sh >/dev/null 2>&1 || true

export DISPLAY=${DISPLAY:-:0}
DESKTOP_FILE="/home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop"

pamac-manager "$@" &
PAMAC_PID=$!

WAIT_MAX=10
WAITED=0
FOUND=0

while [[ $WAITED -lt $WAIT_MAX && $FOUND -eq 0 ]]; do
  sleep 1
  WAITED=$((WAITED + 1))
  for wid in $(xdotool search --class "pamac-manager" 2>/dev/null); do
    width=$(xwininfo -id "$wid" 2>/dev/null | awk "/Width:/{print \$NF}")
    if [[ -n "$width" ]] && [[ "$width" -gt 1 ]]; then
      xprop -id "$wid" -f _KDE_NET_WM_DESKTOP_FILE 8u \
        -set _KDE_NET_WM_DESKTOP_FILE "$DESKTOP_FILE" 2>/dev/null
      FOUND=1
      break
    fi
  done
done

wait "$PAMAC_PID" 2>/dev/null
INNER_EOF
'
podman exec arch-pamac chmod +x /usr/local/bin/pamac-manager-wrapper

echo "=== Updated wrapper ==="
podman exec arch-pamac cat /usr/local/bin/pamac-manager-wrapper

echo ""
echo "DONE"