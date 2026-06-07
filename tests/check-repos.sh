#!/bin/bash
set -euo pipefail

echo "=== Testing extra repos setup on existing container ==="

DESKTOP_FILE="/home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop"

echo "=== Current pacman.conf repos ==="
podman exec arch-pamac grep '^\[' /etc/pacman.conf 2>/dev/null || echo "Could not read pacman.conf"

echo ""
echo "=== Current chaotic-mirrorlist ==="
podman exec arch-pamac cat /etc/pacman.d/chaotic-mirrorlist 2>/dev/null | head -10 || echo "no chaotic-mirrorlist"

echo ""
echo "=== Current keyrings installed ==="
podman exec arch-pamac pacman -Q 2>/dev/null | grep -i keyring || echo "no keyrings found"

echo ""
echo "=== Checking available packages from extra repos ==="
podman exec arch-pamac pacman -Sl 2>/dev/null | awk '{print $1}' | sort -u || echo "Could not list repos"
