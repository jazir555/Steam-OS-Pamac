#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Check wayland socket in container ==="
podman exec arch-pamac ls -la /run/user/1000/wayland-0 2>&1
podman exec arch-pamac ls -la "$XDG_RUNTIME_DIR/wayland-0" 2>&1

echo ""
echo "=== Check X11 socket in container ==="
podman exec arch-pamac ls -la /tmp/.X11-unix/ 2>&1

echo ""
echo "=== Check pamac process environment ==="
PAMAC_PID=$(pgrep pamac-manager | head -1)
if [ -n "$PAMAC_PID" ]; then
  echo "PID=$PAMAC_PID"
  tr '\0' '\n' < "/proc/$PAMAC_PID/environ" 2>/dev/null | grep -iE 'DISPLAY|WAYLAND|GDK|GTK|DESKTOP' | head -10
fi

echo ""
echo "=== Run xdotool from container ==="
podman exec arch-pamac bash -c 'export DISPLAY=:0; xdotool search --onlyvisible --name "" 2>&1 | head -5' 2>&1

echo ""
echo "DONE"