#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Disabling read-only filesystem ==="
echo a | sudo -S steamos-readonly disable 2>&1

echo ""
echo "=== Disabling system Discover URL handler ==="
echo a | sudo -S mv /usr/share/applications/org.kde.discover.urlhandler.desktop \
    /usr/share/applications/org.kde.discover.urlhandler.desktop.disabled 2>&1
echo "Disabled Discover URL handler"

echo ""
echo "=== Re-enabling read-only filesystem ==="
echo a | sudo -S steamos-readonly enable 2>&1

# Rebuild sycoca
update-desktop-database ~/.local/share/applications 2>/dev/null
echo a | sudo -S update-desktop-database /usr/share/applications 2>/dev/null
kbuildsycoca6 2>&1 | tail -2
sleep 1

echo ""
echo "=== Verify: xdg-mime should return nothing ==="
result=$(xdg-mime query default x-scheme-handler/appstream 2>&1)
echo "xdg-mime result: '$result'"
if [[ -z "$result" ]]; then
    echo "SUCCESS: No appstream handler"
else
    echo "Still has handler: $result"
    echo "Checking if the handler file actually exists..."
    ls -la /usr/share/applications/org.kde.discover.urlhandler.desktop* 2>&1
fi

echo ""
echo "=== Also update kde-mimeapps.list ==="
echo a | sudo -S bash -c 'steamos-readonly disable; sed -i "/x-scheme-handler\/appstream/d" /usr/share/applications/kde-mimeapps.list; steamos-readonly enable' 2>&1
echo "Removed appstream from kde-mimeapps.list"

# Rebuild again after kde-mimeapps.list change
echo a | sudo -S update-desktop-database /usr/share/applications 2>/dev/null
kbuildsycoca6 2>&1 | tail -2
sleep 1

result=$(xdg-mime query default x-scheme-handler/appstream 2>&1)
echo "xdg-mime result after kde-mimeapps.list fix: '$result'"
