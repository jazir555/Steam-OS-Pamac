#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

APP_DIR="$HOME/.local/share/applications"
MIMEAPPS="$HOME/.config/mimeapps.list"

echo "=== Bug #36 Fix v3: Override Discover URL handler at user level ==="

# Step 1: Remove any old NoDisplay handler
rm -f "$APP_DIR/steamos-pamac-no-appstream-handler.desktop"

# Step 2: Create a user-level override of org.kde.discover.urlhandler.desktop
# that removes the MimeType=x-scheme-handler/appstream line
# KDE sycoca gives precedence to user-level desktop files over system ones
cat > "$APP_DIR/org.kde.discover.urlhandler.desktop" << 'EOF'
[Desktop Entry]
Name=Discover
Type=Application
NoDisplay=true
Icon=plasmadiscover
Exec=plasma-discover %U
EOF
chmod 644 "$APP_DIR/org.kde.discover.urlhandler.desktop"
echo "Created user-level override of Discover URL handler (no MimeType)"

# Step 3: Clean up mimeapps.list
sed -i '/x-scheme-handler\/appstream/d' "$MIMEAPPS"

# Step 4: Rebuild sycoca and check
update-desktop-database "$APP_DIR" 2>/dev/null
kbuildsycoca6 2>&1 | tail -2

sleep 1

echo ""
echo "=== xdg-mime query default ==="
xdg-mime query default x-scheme-handler/appstream 2>&1

echo ""
echo "=== Check mimeinfo.cache for appstream ==="
grep appstream "$APP_DIR/mimeinfo.cache" 2>&1

echo ""
echo "=== User-level Discover override ==="
cat "$APP_DIR/org.kde.discover.urlhandler.desktop"

echo ""
echo "=== System-level Discover URL handler (still has MimeType) ==="
grep MimeType /usr/share/applications/org.kde.discover.urlhandler.desktop 2>&1

echo ""
echo "=== Done ==="
