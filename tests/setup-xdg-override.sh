#!/bin/bash
set -euo pipefail

echo "=== Creating systemd drop-in for plasma-plasmashell.service ==="

# Create the drop-in directory
mkdir -p ~/.config/systemd/user/plasma-plasmashell.service.d/

# Create the override
cat > ~/.config/systemd/user/plasma-plasmashell.service.d/override-xdg-data-dirs.conf <<'OVERRIDE'
[Service]
Environment=XDG_DATA_DIRS=/home/deck/.local/share:/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share
OVERRIDE

echo "Drop-in created:"
cat ~/.config/systemd/user/plasma-plasmashell.service.d/override-xdg-data-dirs.conf

echo ""
echo "=== Reloading systemd user daemon ==="
systemctl --user daemon-reload

echo ""
echo "=== Checking plasma-plasmashell.service environment ==="
systemctl --user show plasma-plasmashell.service | grep -i environment || echo "No Environment lines found"

echo ""
echo "=== Also update the environment.d config to be consistent ==="
mkdir -p ~/.config/environment.d/
cat > ~/.config/environment.d/30-xdg-data-dirs.conf <<'ENVCONF'
XDG_DATA_DIRS=/home/deck/.local/share:/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share
ENVCONF

echo "environment.d updated (with literal path, not %h):"
cat ~/.config/environment.d/30-xdg-data-dirs.conf

echo ""
echo "=== Import into current systemd environment ==="
export XDG_DATA_DIRS="/home/deck/.local/share:/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share"
systemctl --user import-environment XDG_DATA_DIRS
systemctl --user show-environment | grep '^XDG_DATA_DIRS='

echo ""
echo "=== DONE. User needs to log out and back in for plasmashell to pick up the change. ==="
