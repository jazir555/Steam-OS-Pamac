#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

BIN_DIR="$HOME/.local/bin"

echo "=== Deploying updated handlers with menu refresh ==="

cp /tmp/steamos-pamac-kickeraction-handler "$BIN_DIR/steamos-pamac-kickeraction-handler" 2>/dev/null
cp /tmp/steamos-pamac-appstream-handler "$BIN_DIR/steamos-pamac-appstream-handler" 2>/dev/null
chmod +x "$BIN_DIR/steamos-pamac-kickeraction-handler" "$BIN_DIR/steamos-pamac-appstream-handler"

echo "=== Verify ==="
echo "kickeraction handler:"
head -3 "$BIN_DIR/steamos-pamac-kickeraction-handler"
echo "..."
grep -c "kbuildsycoca6" "$BIN_DIR/steamos-pamac-kickeraction-handler"
echo "appstream handler:"
head -3 "$BIN_DIR/steamos-pamac-appstream-handler"
echo "..."
grep -c "kbuildsycoca6" "$BIN_DIR/steamos-pamac-appstream-handler"

echo ""
echo "=== Check kickeraction desktop file ==="
cat "$HOME/.local/share/plasma/kickeractions/steamos-pamac-uninstall.desktop" 2>&1

echo ""
echo "=== Check appstream handler desktop ==="
cat "$HOME/.local/share/applications/steamos-pamac-appstream-handler.desktop" 2>&1

echo ""
echo "=== Done ==="
