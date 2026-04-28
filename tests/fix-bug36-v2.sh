#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

APP_DIR="$HOME/.local/share/applications"
MIMEAPPS="$HOME/.config/mimeapps.list"

echo "=== Bug #36 Fix v2: Remove appstream handler entirely ==="
echo "Strategy: Remove ALL appstream handlers so preferredService() returns null."
echo "This means appstreamActions() returns empty list and no menu item appears."

# Remove our NoDisplay handler
rm -f "$APP_DIR/steamos-pamac-no-appstream-handler.desktop"
echo "Removed NoDisplay appstream handler"

# Remove appstream from mimeapps.list
sed -i '/x-scheme-handler\/appstream/d' "$MIMEAPPS"
echo "Removed appstream handler from mimeapps.list"

# Override the system-level kde-mimeapps.list entry for this user
# By putting an explicit empty/none default in user mimeapps.list
# Actually, we need to set it to an empty string or a non-existent handler
# to override the system default. Setting it to "" won't work.
# The correct approach: add to [Default Applications] with value that
# resolves to nothing. Or we can use the RemovedAssociations group.

# Check system-level defaults
echo "System kde-mimeapps.list:"
cat /usr/share/applications/kde-mimeapps.list 2>/dev/null | grep appstream

echo ""
echo "Current user mimeapps.list:"
cat "$MIMEAPPS"

echo ""
echo "=== Testing: what does preferredService return now? ==="
# Rebuild sycoca first
kbuildsycoca6 2>&1 | tail -2
xdg-mime query default x-scheme-handler/appstream 2>&1

echo ""
echo "=== If Discover still shows as default, we need to override ==="
echo "The system kde-mimeapps.list sets appstream=org.kde.discover.urlhandler.desktop"
echo "We need the USER mimeapps.list to override this with no handler."
echo ""
echo "Per freedesktop.org mime-apps-spec, setting the default to a"
echo "non-existent desktop file in user config overrides system config."
echo "But preferredService uses sycoca which may still find Discover."

echo ""
echo "=== Alternative: just remove the appstream mime type from Discover ==="
echo "We can copy the system desktop file to user dir and remove the MimeType"
