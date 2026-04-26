#!/bin/bash
set -x

export XDG_DATA_DIRS=/usr/local/share:/usr/share
export XDG_DATA_HOME=/home/deck/.local/share
export HOME=/home/deck

echo "=== Testing distrobox-export for mousepad ==="
distrobox-export --app org.xfce.mousepad 2>&1
echo "exit=$?"
ls -la /home/deck/.local/share/applications/arch-pamac-org.xfce.mousepad.desktop 2>/dev/null
echo "=== Testing distrobox-export for btop ==="
distrobox-export --app btop 2>&1
echo "exit=$?"
ls -la /home/deck/.local/share/applications/arch-pamac-btop.desktop 2>/dev/null
echo "=== DONE ==="
