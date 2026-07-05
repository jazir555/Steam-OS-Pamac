#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Current wrapper ==="
podman exec arch-pamac cat /usr/local/bin/pamac-manager-wrapper

echo ""
echo "=== Check XAUTHORITY in running pamac ==="
podman exec arch-pamac bash -c 'echo "XAUTHORITY=$XAUTHORITY"'

echo ""
echo "=== Test xdotool from inside container ==="
podman exec arch-pamac bash -c 'export DISPLAY=:0; xdotool search --class "pamac-manager" 2>&1'

echo ""
echo "=== Test xprop from inside container ==="
podman exec arch-pamac bash -c 'export DISPLAY=:0; xprop -id $(xdotool search --class "pamac-manager" 2>/dev/null | tail -1) WM_CLASS 2>&1'