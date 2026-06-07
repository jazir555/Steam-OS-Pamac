#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Current chaotic-mirrorlist ==="
podman exec arch-pamac cat /etc/pacman.d/chaotic-mirrorlist

echo ""
echo "=== Removing duplicate [options] from pacman.conf ==="
# Use sed: delete all [options] lines after the first one
podman exec arch-pamac bash -c '
  sed -i "0,/^\[options\]/!s/^\[options\]$/#DELETED_DUPLICATE_OPTIONS/" /etc/pacman.conf
'
echo "Done fixing"

echo ""
echo "=== Verifying pacman.conf has only one [options] ==="
podman exec arch-pamac grep -c '^\[options\]' /etc/pacman.conf

echo ""
echo "=== Testing sync ==="
podman exec arch-pamac pacman -Sy 2>&1 | tail -15

echo ""
echo "DONE"