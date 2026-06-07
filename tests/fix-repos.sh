#!/bin/bash
set -euo pipefail
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Fixing chaotic-mirrorlist ==="
podman exec arch-pamac bash -c 'cat > /etc/pacman.d/chaotic-mirrorlist' << 'MIRROREOF'
## Chaotic-AUR mirrorlist
Server = https://cdn-mirror.chaotic.cx/chaotic-aur/$arch
Server = https://geo-mirror.chaotic.cx/chaotic-aur/$arch
MIRROREOF
echo "chaotic-mirrorlist fixed"

echo "=== Fixing archlinuxcn keyring ==="
podman exec arch-pamac bash -c '
  pacman-key --recv-key 11C2E2D1D43CF75C 2>/dev/null || true
  pacman-key --lsign-key 11C2E2D1D43CF75C 2>/dev/null || true
'
echo "archlinuxcn key fixed"

echo "=== Fixing endeavouros keyring ==="
podman exec arch-pamac bash -c '
  pacman-key --recv-key F52611D11AFD4556 2>/dev/null || true
  pacman-key --lsign-key F52611D11AFD4556 2>/dev/null || true
'
echo "endeavouros key fixed"

echo "=== Retry pacman sync ==="
podman exec arch-pamac pacman -Sy 2>&1 | tail -25

echo ""
echo "DONE"