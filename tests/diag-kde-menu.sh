#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

echo "=== Direct test: does KDE's appstreamActions show for apps? ==="
echo "We'll check by seeing if the kickeraction 'Uninstall' appears"
echo "AND if the 'Uninstall or Manage Add-Ons' also appears."
echo ""
echo "Current state of kickeraction:"
ls -la ~/.local/share/plasma/kickeractions/ 2>&1
cat ~/.local/share/plasma/kickeractions/steamos-pamac-uninstall.desktop 2>&1

echo ""
echo "Current Discover override:"
cat ~/.local/share/applications/org.kde.discover.urlhandler.desktop 2>&1

echo ""
echo "=== The real test is: does the menu show both items? ==="
echo "User needs to right-click a pamac app in KDE menu and check."

echo ""
echo "=== Alternative approach: just rename the system Discover urlhandler ==="
echo "We could: echo a | sudo -S mv /usr/share/applications/org.kde.discover.urlhandler.desktop /usr/share/applications/org.kde.discover.urlhandler.desktop.disabled"
echo "This would remove it from sycoca entirely. But it's a system file change."

echo ""
echo "=== Check if our kickeraction is loaded by plasmashell ==="
# Check kicker's QML context - see if our kickeraction is recognized
qdbus org.kde.plasmashell 2>&1 | head -5 || echo "plasmashell not on dbus"

echo ""
echo "=== Try a different approach: use XDG data dirs priority ==="
echo "User XDG_DATA_DIRS:"
echo "$XDG_DATA_DIRS"
echo ""
echo "System XDG_DATA_DIRS:"
tr '\0' '\n' < /proc/$(pgrep -x plasmashell | head -1)/environ 2>/dev/null | grep XDG_DATA || echo "cannot read plasmashell env"
