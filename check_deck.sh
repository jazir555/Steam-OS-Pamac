#!/bin/bash
echo "=== PODMAN INFO ==="
podman info --format '{{.Host.OS}}' 2>&1
echo "=== PODMAN PS ==="
podman ps -a 2>&1
echo "=== DISTROBOX LIST ==="
distrobox list 2>&1
echo "=== DISK SPACE ==="
df -h /home 2>&1
echo "=== PODMAN IMAGES ==="
podman images 2>&1
echo "=== SYSTEMD ==="
systemctl is-system-running 2>&1 || true
echo "=== PODMAN CHECK COMPLETE ==="
