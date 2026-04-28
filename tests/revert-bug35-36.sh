#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

APP_DIR="$HOME/.local/share/applications"
KICKERACTION_DIR="$HOME/.local/share/plasma/kickeractions"
MIMEAPPS="$HOME/.config/mimeapps.list"
BIN_DIR="$HOME/.local/bin"

echo "=== Reverting deploy-bug35-36-fix.sh changes ==="

# 1. Remove NoDisplay appstream handler
rm -f "$APP_DIR/steamos-pamac-no-appstream-handler.desktop"
echo "Removed steamos-pamac-no-appstream-handler.desktop"

# 2. Remove appstream handler from mimeapps.list
sed -i '/x-scheme-handler\/appstream/d' "$MIMEAPPS"
echo "Removed appstream handler from mimeapps.list"

# 3. Remove kickeraction desktop file
rm -f "$KICKERACTION_DIR/steamos-pamac-uninstall.desktop"
echo "Removed kickeraction desktop file"

# 4. Remove kickeraction handler script
rm -f "$BIN_DIR/steamos-pamac-kickeraction-handler"
echo "Removed kickeraction handler script"

# 5. Remove handler log
rm -f "$HOME/.local/share/steamos-pamac/arch-pamac/kickeraction-handler.log"
echo "Removed kickeraction handler log"

# 6. Update desktop database
update-desktop-database "$APP_DIR" 2>/dev/null
echo "Updated desktop database"

echo ""
echo "=== Remaining state ==="
echo "mimeapps.list:"
cat "$MIMEAPPS" 2>/dev/null
echo ""
echo "kickeractions dir:"
ls -la "$KICKERACTION_DIR" 2>/dev/null
echo ""
echo "NoDisplay handler exists:"
ls -la "$APP_DIR/steamos-pamac-no-appstream-handler.desktop" 2>&1
echo ""
echo "=== Revert complete ==="
