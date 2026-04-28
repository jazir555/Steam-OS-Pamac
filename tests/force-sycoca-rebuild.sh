#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Force sycoca cache rebuild ==="
# Delete the sycoca cache to force full rebuild
rm -f ~/.cache/ksycoca6* 2>/dev/null
echo a | sudo -S rm -f /var/cache/ksycoca6* 2>/dev/null

# Also check if there's a system-level cache
find /var/cache -name "ksycoca*" 2>/dev/null
find ~/.cache -name "ksycoca*" 2>/dev/null

# Force rebuild
KSYCOCA_MTIME=0 kbuildsycoca6 --noincremental 2>&1 | tail -5
sleep 1

echo ""
echo "=== Verify ==="
result=$(xdg-mime query default x-scheme-handler/appstream 2>&1)
echo "xdg-mime result: '$result'"

echo ""
echo "=== Check if disabled file still in mimeinfo.cache ==="
grep appstream /usr/share/applications/mimeinfo.cache 2>&1
echo "---"
grep appstream ~/.local/share/applications/mimeinfo.cache 2>&1 || echo "No appstream in user mimeinfo.cache"

echo ""
echo "=== System mimeinfo.cache needs rebuild ==="
echo a | sudo -S update-desktop-database /usr/share/applications 2>&1
sleep 1
grep appstream /usr/share/applications/mimeinfo.cache 2>&1 || echo "No appstream in system mimeinfo.cache (good!)"

# Force another sycoca rebuild
rm -f ~/.cache/ksycoca6* 2>/dev/null
KSYCOCA_MTIME=0 kbuildsycoca6 --noincremental 2>&1 | tail -5
sleep 1

echo ""
echo "=== Final verify ==="
result=$(xdg-mime query default x-scheme-handler/appstream 2>&1)
echo "xdg-mime result: '$result'"
