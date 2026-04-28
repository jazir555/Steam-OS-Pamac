#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

APP_DIR="$HOME/.local/share/applications"

echo "=== Bug #36 Fix v5: User-level Hidden override of Discover URL handler ==="
echo "Per XDG desktop file spec, Hidden=true means the service should be ignored."
echo "A user-level file with the same name overrides the system one in sycoca."

cat > "$APP_DIR/org.kde.discover.urlhandler.desktop" << 'EOF'
[Desktop Entry]
Name=Discover
Type=Application
Hidden=true
EOF
chmod 644 "$APP_DIR/org.kde.discover.urlhandler.desktop"
echo "Created user-level Hidden=true override"

# Rebuild caches
update-desktop-database "$APP_DIR" 2>/dev/null
rm -f ~/.cache/ksycoca6* 2>/dev/null
kbuildsycoca6 --noincremental 2>&1 | tail -2
sleep 1

echo ""
echo "=== Verify ==="
result=$(xdg-mime query default x-scheme-handler/appstream 2>&1)
echo "xdg-mime result: '$result'"

echo ""
echo "=== Check user mimeinfo.cache ==="
grep appstream "$APP_DIR/mimeinfo.cache" 2>&1 || echo "No appstream in user cache"

echo ""
echo "=== Check system mimeinfo.cache ==="
grep appstream /usr/share/applications/mimeinfo.cache 2>&1 | head -3

echo ""
echo "=== If Hidden=true doesn't work, try another approach ==="
echo "Testing: does KDE's queryByMimeType respect Hidden=true?"
