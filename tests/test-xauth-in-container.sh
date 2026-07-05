#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Test xdotool with XAUTHORITY ==="
XAUTH=$(ls -t /run/user/1000/xauth_* 2>/dev/null | head -1)

podman exec -e DISPLAY=:0 -e XAUTHORITY="$XAUTH" arch-pamac xdotool search --class "pamac-manager" 2>&1

echo ""
echo "=== Test xdotool without XAUTHORITY (current behavior) ==="
podman exec arch-pamac xdotool search --class "pamac-manager" 2>&1

echo ""
echo "=== Check container's bashrc/XAUTHORITY ==="
podman exec arch-pamac bash -c 'echo "XAUTHORITY=$XAUTHORITY DISPLAY=$DISPLAY"'

echo ""
echo "DONE"