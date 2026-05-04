#!/bin/bash
set -euo pipefail

echo "=== All pamac-related desktop files ==="
find /home/deck/.local/share/applications/ -name '*pamac*' -o -name '*add*remove*' -o -name '*software*install*' 2>/dev/null | while read f; do
    echo "--- $f ---"
    grep -E '^(Name=|NoDisplay=|Hidden=|Exec=)' "$f" 2>/dev/null
    echo ""
done

echo "=== Desktop files in /usr/local/share/applications/ ==="
grep -rl 'pamac' /usr/local/share/applications/ 2>/dev/null || echo "none"

echo "=== Desktop files in /usr/share/applications/ ==="
grep -rl 'pamac' /usr/share/applications/ 2>/dev/null || echo "none"

echo "=== Check what KDE sees - sycoca query ==="
export XDG_DATA_DIRS="/home/deck/.local/share:/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share"
kbuildsycoca6 --noincremental 2>/dev/null || true

echo "=== Full content of main pamac desktop file ==="
cat /home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop 2>/dev/null || echo "NOT FOUND"
