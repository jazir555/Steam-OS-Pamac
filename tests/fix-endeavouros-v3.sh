#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Current endeavouros section ==="
podman exec arch-pamac sed -n '/^\[endeavouros\]/,/^\[/p' /etc/pacman.conf

echo ""
echo "=== Updating endeavouros Server line ==="
podman exec arch-pamac sed -i \
  '/^\[endeavouros\]/,/^\[/ s|Server = .*|Server = https://mirror.freedif.org/EndeavourOS/repo/$repo/$arch|' \
  /etc/pacman.conf

echo "=== Updated endeavouros section ==="
podman exec arch-pamac sed -n '/^\[endeavouros\]/,/^\[/p' /etc/pacman.conf

echo ""
echo "=== Testing endeavouros sync ==="
podman exec arch-pamac timeout 30 pacman -Sy --noconfirm endeavouros 2>&1 | tail -10

echo ""
echo "=== Full sync ==="
podman exec arch-pamac timeout 60 pacman -Sy 2>&1 | tail -20

echo ""
echo "DONE"