#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Testing chaotic-aur ==="
podman exec arch-pamac pacman -Ssq chaotic-aur/google-chrome 2>/dev/null || echo "google-chrome not found"
podman exec arch-pamac pacman -Ssq chaotic-aur/pamac-aur 2>/dev/null || echo "pamac-aur not in chaotic"

echo ""
echo "=== Testing archlinuxcn ==="
podman exec arch-pamac pacman -Ssq archlinuxcn/google-chrome 2>/dev/null || echo "not in archlinuxcn"

echo ""
echo "=== Testing endeavouros ==="
podman exec arch-pamac pacman -Ssq endeavouros/endeavouros-keyring 2>/dev/null || echo "endeavouros-keyring not found"

echo ""
echo "=== Package count per extra repo ==="
for repo in chaotic-aur archlinuxcn endeavouros; do
  count=$(podman exec arch-pamac pacman -Sl $repo 2>/dev/null | wc -l)
  echo "$repo: $count packages"
done

echo ""
echo "DONE"