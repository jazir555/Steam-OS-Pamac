#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Installing celluloid for GUI test ==="
podman exec -u 0 arch-pamac pamac install --no-confirm celluloid </dev/null 2>&1 | tail -5
echo ""

echo "=== Running export hook ==="
podman exec -u 0 arch-pamac /usr/local/bin/distrobox-export-hook.sh </dev/null 2>&1 | tail -5
echo ""

echo "=== Checking desktop file ==="
desktop=$(grep -rl "X-SteamOS-Pamac-SourcePackage=celluloid" ~/.local/share/applications/ 2>/dev/null | head -1)
if [[ -n "$desktop" ]]; then
  echo "Desktop file: $desktop"
  echo "---"
  cat "$desktop"
  echo "---"
else
  echo "ERROR: No desktop file found for celluloid"
fi

echo ""
echo "=== Checking kickeraction file ==="
cat ~/.local/share/plasma/kickeractions/steamos-pamac-uninstall.desktop 2>/dev/null || echo "No kickeraction file"
