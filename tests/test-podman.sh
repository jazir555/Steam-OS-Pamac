#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Test podman exec direct ==="
podman exec -e DISPLAY arch-pamac bash -c 'echo "Container PATH: $PATH"; which pamac-manager 2>/dev/null || find /usr -name pamac-manager -type f 2>/dev/null | head -3'

echo ""
echo "DONE"