#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
export DISPLAY=:0
export XAUTHORITY=/run/user/1000/xauth_bnwaof
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

echo "=== Test preferredService via KApplicationTrader ==="
# Use ktraderclient6 to query
ktraderclient6 --mimetype x-scheme-handler/appstream 2>&1 | head -20 || echo "ktraderclient6 not available"

echo ""
echo "=== Test via python KService ==="
python3 << 'PYEOF'
import subprocess
result = subprocess.run(
    ['ktraderclient6', '--mimetype', 'x-scheme-handler/appstream'],
    capture_output=True, text=True
)
print("ktraderclient6 stdout:", result.stdout[:500])
print("ktraderclient6 stderr:", result.stderr[:500])
PYEOF

echo ""
echo "=== Alternative: use kioclient ==="
kioclient6 exec 'appstream://' 2>&1 || echo "no handler"

echo ""
echo "=== Check sycoca directly ==="
kbuildsycoca6 2>&1 | tail -2
# Try to look up the service
python3 << 'PYEOF2'
import subprocess
# Use kservice query to find services for appstream
result = subprocess.run(
    ['qdbus', 'org.kde.plasmashell', '/KDE', 'org.kde.KService.query', 'x-scheme-handler/appstream'],
    capture_output=True, text=True
)
print("qdbus result:", result.stdout[:200], result.stderr[:200])
PYEOF2

echo ""
echo "=== Check if user override takes priority in sycoca ==="
# The key question: does sycoca use the user-level desktop file
# (which has no MimeType) or the system one (which does)?
# If user-level takes priority, preferredService should return null
grep -r "appstream" "$HOME/.local/share/applications/mimeinfo.cache" 2>&1 || echo "No appstream in user mimeinfo.cache (good!)"
echo ""
grep -r "appstream" /usr/share/applications/mimeinfo.cache 2>&1 | head -3
