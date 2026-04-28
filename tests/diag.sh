#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Current kickeraction handler ==="
cat ~/.local/bin/steamos-pamac-kickeraction-handler

echo ""
echo "=== Current uninstall helper ==="
cat ~/.local/bin/steamos-pamac-uninstall

echo ""
echo "=== Current appstream intercept ==="
cat ~/.local/bin/steamos-pamac-appstream-intercept 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== Appstream intercept desktop ==="
cat ~/.local/share/applications/steamos-pamac-appstream-intercept.desktop 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== x-scheme-handler/appstream ==="
xdg-mime query default x-scheme-handler/appstream 2>/dev/null

echo ""
echo "=== mimeapps.list ==="
cat ~/.config/mimeapps.list 2>/dev/null | grep appstream

echo ""
echo "=== Kickeraction handler log (last 20) ==="
tail -20 ~/.local/share/steamos-pamac/arch-pamac/kickeraction-handler.log 2>/dev/null

echo ""
echo "=== Journal plasma crash last 5 min ==="
journalctl --user --since "5 min ago" 2>/dev/null | grep -i "plasma\|crash\|segfault\|kill\|core" | tail -10
