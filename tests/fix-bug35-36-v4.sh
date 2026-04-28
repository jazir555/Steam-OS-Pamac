#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

KICKERACTION_DIR="$HOME/.local/share/plasma/kickeractions"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"

echo "=== Bug #36 Fix v4: Disable system Discover URL handler ==="
echo "This removes org.kde.discover.urlhandler.desktop from sycoca,"
echo "so preferredService('x-scheme-handler/appstream') returns null."
echo "Discover main app still works fine - this only affects the appstream:// URL handler."

echo a | sudo -S mv /usr/share/applications/org.kde.discover.urlhandler.desktop \
    /usr/share/applications/org.kde.discover.urlhandler.desktop.disabled 2>&1
echo "Disabled system Discover URL handler"

# Also clean up the user-level override (no longer needed)
rm -f "$APP_DIR/org.kde.discover.urlhandler.desktop"
echo "Removed user-level Discover override"

# Clean up any NoDisplay handler
rm -f "$APP_DIR/steamos-pamac-no-appstream-handler.desktop"
sed -i '/x-scheme-handler\/appstream/d' ~/.config/mimeapps.list
echo "Cleaned up appstream handler references"

# Rebuild sycoca
update-desktop-database "$APP_DIR" 2>/dev/null
kbuildsycoca6 2>&1 | tail -2
sleep 1

echo ""
echo "=== Verify: xdg-mime should now return nothing ==="
result=$(xdg-mime query default x-scheme-handler/appstream 2>&1)
echo "xdg-mime query default x-scheme-handler/appstream: '$result'"
if [[ -z "$result" ]]; then
    echo "SUCCESS: No appstream handler registered"
else
    echo "WARNING: Still has handler: $result"
fi

echo ""
echo "=== Bug #35 Fix: Ensure kickeraction has empty OnlyForAppIds ==="
cat > "$KICKERACTION_DIR/steamos-pamac-uninstall.desktop" << 'KICKER_EOF'
[Desktop Entry]
Type=Service
Name=SteamOS Pamac Uninstall Action
X-KDE-OnlyForAppIds=
Actions=uninstall;

[Desktop Action uninstall]
Name=Uninstall
Icon=edit-delete
Exec=/home/deck/.local/bin/steamos-pamac-kickeraction-handler %u
KICKER_EOF
chown deck:deck "$KICKERACTION_DIR/steamos-pamac-uninstall.desktop" 2>/dev/null
chmod 644 "$KICKERACTION_DIR/steamos-pamac-uninstall.desktop"
echo "Updated kickeraction desktop file (empty OnlyForAppIds)"

echo ""
echo "=== Verify kickeraction handler exists ==="
ls -la "$BIN_DIR/steamos-pamac-kickeraction-handler" 2>&1
head -5 "$BIN_DIR/steamos-pamac-kickeraction-handler" 2>&1

echo ""
echo "=== Current state ==="
echo "kickeraction:"
cat "$KICKERACTION_DIR/steamos-pamac-uninstall.desktop"
echo ""
echo "mimeapps.list:"
cat ~/.config/mimeapps.list
