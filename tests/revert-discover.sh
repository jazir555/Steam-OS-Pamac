#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Reverting: restore Discover URL handler ==="
echo a | sudo -S steamos-readonly disable 2>&1
echo a | sudo -S mv /usr/share/applications/org.kde.discover.urlhandler.desktop.disabled \
    /usr/share/applications/org.kde.discover.urlhandler.desktop 2>&1
echo a | sudo -S steamos-readonly enable 2>&1
echo "Restored Discover URL handler"

echo "=== Reverting: restore kde-mimeapps.list ==="
echo a | sudo -S steamos-readonly disable 2>&1
# Add the appstream line back if missing
if ! grep -q 'x-scheme-handler/appstream' /usr/share/applications/kde-mimeapps.list 2>/dev/null; then
    echo a | sudo -S sed -i '/\[Default Applications\]/a x-scheme-handler/appstream=org.kde.discover.urlhandler.desktop' /usr/share/applications/kde-mimeapps.list 2>&1
fi
echo a | sudo -S steamos-readonly enable 2>&1
echo "Restored kde-mimeapps.list"

# Rebuild caches
rm -f ~/.cache/ksycoca6* 2>/dev/null
update-desktop-database ~/.local/share/applications 2>/dev/null
kbuildsycoca6 2>&1 | tail -2

echo ""
echo "=== Verify Discover URL handler is back ==="
xdg-mime query default x-scheme-handler/appstream 2>&1

echo ""
echo "=== Clean up user-level override (if any) ==="
rm -f ~/.local/share/applications/org.kde.discover.urlhandler.desktop
echo "Done"
