#!/bin/bash
echo '=== Creating test container ==='
podman rm -f oomtest 2>/dev/null
distrobox create --name oomtest --image archlinux:latest --yes 2>&1
echo '=== Running pacman in container ==='
distrobox enter oomtest -- bash -c '
echo "Memory available:"
grep MemAvailable /proc/meminfo
echo "Ulimit:"
ulimit -a 2>&1 | head -10
echo "Installing sudo..."
pacman -Syy --noconfirm 2>&1 | tail -3
pacman -S --noconfirm --needed sudo 2>&1
echo "Exit code: $?"
echo "=== done ==="
' 2>&1
echo '=== cleanup ==='
podman rm -f oomtest 2>/dev/null
