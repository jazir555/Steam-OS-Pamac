#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Changing endeavouros mirror ==="
podman exec arch-pamac bash -c '
  sed -i "s|mirror.albony.xyz/endeavouros/repo|mirror.freedif.org/EndeavourOS/repo|" /etc/pacman.conf
'

echo "=== Current endeavouros section ==="
podman exec arch-pamac grep -A1 "^\[endeavouros\]" /etc/pacman.conf

echo ""
echo "=== Testing endeavouros sync ==="
podman exec arch-pamac timeout 30 pacman -Sy --noconfirm endeavouros 2>&1 | tail -10

echo ""
echo "DONE"