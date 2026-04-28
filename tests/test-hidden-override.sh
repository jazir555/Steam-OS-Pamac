#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

echo "=== Testing: does KDE show 'Uninstall or Manage Add-Ons' for pamac apps? ==="
echo ""
echo "Current state of Hidden=true override:"
cat ~/.local/share/applications/org.kde.discover.urlhandler.desktop 2>&1
echo ""
echo "User mimeinfo.cache:"
cat ~/.local/share/applications/mimeinfo.cache 2>&1 | grep appstream || echo "No appstream in user cache"
echo ""
echo "xdg-mime result:"
xdg-mime query default x-scheme-handler/appstream 2>&1

echo ""
echo "=== The REAL test: check what KDE plasmashell actually does ==="
echo "We need the user to right-click a pamac app and check if"
echo "'Uninstall or Manage Add-Ons...' still appears."
echo ""
echo "Alternatively, we can check by using kreadconfig6 to see what KDE uses:"
kreadconfig6 --file mimeapps.list --group "Default Applications" --key "x-scheme-handler/appstream" 2>&1

echo ""
echo "=== Also check: does Hidden=true override make sycoca skip it? ==="
echo "Force sycoca rebuild and check..."
rm -f ~/.cache/ksycoca6* 2>/dev/null
KSYCOCA_MTIME=0 kbuildsycoca6 --noincremental 2>&1 | tail -2

echo ""
echo "=== Check if Discover URL handler is in sycoca ==="
# Look for it in the sycoca file
for f in ~/.cache/ksycoca6_*; do
    if [[ -f "$f" ]]; then
        echo "Found sycoca cache: $f"
        # Try to extract service info - sycoca is binary but we can grep
        strings "$f" 2>/dev/null | grep -i "discover.urlhandler" | head -5
        echo "---"
        strings "$f" 2>/dev/null | grep -i "appstream" | head -5
    fi
done
