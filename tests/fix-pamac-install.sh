#!/bin/bash
set -uo pipefail

export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Installing pamac-aur in container ==="

# Run inside container as deck user
podman exec -i arch-pamac bash -lc '
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin
rm -f /var/lib/pacman/db.lck

for attempt in 1 2 3; do
    echo "Attempt $attempt to install pamac-aur..."
    if sudo -Hu deck bash -lc "yay -S --noconfirm --needed --noprogressbar pamac-aur"; then
        echo "pamac-aur installed successfully on attempt $attempt"
        break
    fi
    echo "Attempt $attempt failed, retrying in 5s..."
    sleep 5
    sudo -Hu deck bash -lc "yay -Y --gendb" 2>/dev/null || true
    rm -f /var/lib/pacman/db.lck
done

echo "=== Verifying pamac packages ==="
pacman -Qs pamac
echo "=== Checking binaries ==="
ls -la /usr/bin/pamac* 2>&1
echo "=== pamac version ==="
pamac --version 2>&1 || echo "pamac CLI not found"
echo "=== pamac-manager ==="
which pamac-manager 2>&1 || echo "pamac-manager not found"
' 2>&1
