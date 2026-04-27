#!/bin/bash
set +e

LOG_FILE="$HOME/.local/share/steamos-pamac/arch-pamac/kickeraction-handler.log"
UNINSTALL_LOG="$HOME/.local/share/steamos-pamac/arch-pamac/uninstall-helper.log"

echo "=== Kickeraction Handler Log ==="
cat "$LOG_FILE" 2>/dev/null || echo "(empty or not found)"

echo ""
echo "=== Uninstall Helper Log ==="
cat "$UNINSTALL_LOG" 2>/dev/null || echo "(empty or not found)"

echo ""
echo "=== Current kickeraction desktop file ==="
cat /home/deck/.local/share/plasma/kickeractions/steamos-pamac-uninstall.desktop 2>/dev/null || echo "(not found)"

echo ""
echo "=== System kickeraction files ==="
ls -la /usr/share/plasma/kickeractions/ 2>/dev/null
ls -la /home/deck/.local/share/plasma/kickeractions/ 2>/dev/null

echo ""
echo "=== Exported desktop files and their storage IDs ==="
for f in /home/deck/.local/share/applications/arch-pamac-*.desktop; do
    [[ -f "$f" ]] || continue
    basename "$f" .desktop
    grep '^Name=' "$f" 2>/dev/null | head -1
    echo ""
done

echo ""
echo "=== KDE service cache check ==="
ls -la /home/deck/.cache/ksycoca* 2>/dev/null || echo "No ksycoca cache found"

echo ""
echo "=== Testing kickeraction handler directly ==="
/home/deck/.local/bin/steamos-pamac-kickeraction-handler "file:///home/deck/.local/share/applications/arch-pamac-librewolf.desktop" 2>&1
echo "Exit code: $?"

echo ""
echo "=== Checking if app still installed ==="
podman exec -i -u 0 arch-pamac pacman -Q librewolf-bin 2>&1 || echo "NOT INSTALLED"

echo ""
echo "=== Re-checking logs ==="
echo "--- kickeraction handler ---"
cat "$LOG_FILE" 2>/dev/null || echo "(empty)"
echo "--- uninstall helper ---"
cat "$UNINSTALL_LOG" 2>/dev/null || echo "(empty)"
