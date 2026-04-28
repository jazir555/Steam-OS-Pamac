#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Simplifying: remove kickeraction, keep only appstream intercept ==="
echo "This gives a SINGLE 'Uninstall or Manage Add-Ons...' menu item"
echo "that we intercept for pamac-managed apps."

echo ""
echo "=== Step 1: Remove kickeraction ==="
rm -f "$HOME/.local/share/plasma/kickeractions/steamos-pamac-uninstall.desktop"
rm -f "$HOME/.local/bin/steamos-pamac-kickeraction-handler"
echo "Removed kickeraction desktop file and handler"

echo ""
echo "=== Step 2: Remove old NoDisplay/Hidden overrides ==="
rm -f "$HOME/.local/share/applications/org.kde.discover.urlhandler.desktop"
rm -f "$HOME/.local/share/applications/steamos-pamac-no-appstream-handler.desktop"
echo "Removed old overrides"

echo ""
echo "=== Step 3: Rebuild caches ==="
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null
rm -f ~/.cache/ksycoca6* 2>/dev/null
kbuildsycoca6 2>&1 | tail -2

echo ""
echo "=== Step 4: Verify appstream intercept handler ==="
echo "Handler script:"
head -5 "$HOME/.local/bin/steamos-pamac-appstream-handler" 2>&1
echo ""
echo "Handler desktop:"
cat "$HOME/.local/share/applications/steamos-pamac-appstream-handler.desktop" 2>&1
echo ""
echo "mimeapps.list:"
cat "$HOME/.config/mimeapps.list" 2>&1
echo ""
echo "xdg-mime default:"
xdg-mime query default x-scheme-handler/appstream 2>&1

echo ""
echo "=== Done ==="
echo "Now there should be only ONE 'Uninstall or Manage Add-Ons...' item."
echo "Clicking it on a pamac app will use our uninstaller."
echo "Clicking it on a non-pamac app will open Discover."
