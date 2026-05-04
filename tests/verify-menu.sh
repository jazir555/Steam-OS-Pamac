#!/bin/bash
set -euo pipefail

echo "=== Rebuild sycoca cache with correct XDG_DATA_DIRS ==="
export XDG_DATA_DIRS="/home/deck/.local/share:/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share"
kbuildsycoca6 --noincremental 2>&1 | tail -3

echo ""
echo "=== Check sycoca cache timestamp ==="
find /home/deck/.cache/ -name 'ksycoca6*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -3

echo ""
echo "=== Verify pamac desktop file is well-formed ==="
desktop-file-validate /home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop 2>&1 || echo "validation issues found"

echo ""
echo "=== Check if KDE now sees the pamac app ==="
# Try to look it up via kservice
QDBUS_OUTPUT=$(qdbus6 org.kde.plasmashell 2>&1 || echo "FAILED")
echo "qdbus6 plasmashell: ${QDBUS_OUTPUT:0:100}"

echo ""
echo "=== Test kservice lookup ==="
kserviceclient6 2>/dev/null || true
# Try querying the sycoca database directly
PYTHON3=$(which python3 2>/dev/null || echo "")
if [[ -n "$PYTHON3" ]]; then
    python3 -c "
import subprocess, os
os.environ['XDG_DATA_DIRS'] = '/home/deck/.local/share:/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share'
result = subprocess.run(['kbuildsycoca6', '--noincremental'], capture_output=True, text=True)
print('sycoca rebuild:', result.returncode)
" 2>&1 || echo "python3 test failed"
fi

echo ""
echo "=== List all desktop files in user applications ==="
ls -la /home/deck/.local/share/applications/*pamac* 2>/dev/null || echo "NO PAMAC DESKTOP FILES"

echo ""
echo "=== Check if NoDisplay is set ==="
grep -i 'NoDisplay\|Hidden' /home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop 2>/dev/null || echo "NoDisplay/Hidden not set (good)"

echo ""
echo "=== Full pamac desktop file ==="
cat /home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop 2>/dev/null || echo "NOT FOUND"
