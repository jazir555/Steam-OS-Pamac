#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Currently exported pamac desktop files ==="
for f in ~/.local/share/applications/arch-pamac-*.desktop; do
  if grep -q 'X-SteamOS-Pamac-Managed=true' "$f" 2>/dev/null; then
    basename "$f"
  fi
done

echo ""
echo "=== Kickeraction X-KDE-OnlyForAppIds ==="
grep 'X-KDE-OnlyForAppIds' ~/.local/share/plasma/kickeractions/steamos-pamac-uninstall.desktop 2>/dev/null
