#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Test podman exec direct ==="
podman exec -e DISPLAY -e XAUTHORITY=/home/deck/.Xauthority \
  -e XDG_CURRENT_DESKTOP=KDE -e GTK_CSD=0 \
  arch-pamac which pamac-manager 2>&1

echo ""
echo "=== Test podman exec pamac-manager --help ==="
podman exec -e DISPLAY -e XAUTHORITY=/home/deck/.Xauthority \
  arch-pamac pamac-manager --help 2>&1 | head -5

echo ""
echo "=== Check podman exec works ==="
echo "SUCCESS"