#!/bin/bash
set -euo pipefail

echo "=== Testing systemctl --user import-environment ==="
export XDG_DATA_DIRS="/home/deck/.local/share:/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share"
systemctl --user import-environment XDG_DATA_DIRS
echo "After import-environment:"
systemctl --user show-environment 2>/dev/null | grep '^XDG_DATA_DIRS=' || echo "NOT SET"

echo ""
echo "=== Checking /usr/local/share/applications/ ==="
ls -la /usr/local/share/applications/ 2>/dev/null || echo "Directory does not exist"
echo ""
echo "=== Checking if /usr/local is writable ==="
touch /usr/local/share/.write_test 2>/dev/null && echo "WRITABLE" && rm -f /usr/local/share/.write_test || echo "NOT WRITABLE without sudo"
echo ""
echo "=== Checking if /usr/local/share/applications is writable with sudo ==="
echo "a" | sudo -S touch /usr/local/share/applications/.sudo_write_test 2>/dev/null && echo "SUDO WRITABLE" && echo "a" | sudo -S rm -f /usr/local/share/applications/.sudo_write_test || echo "SUDO NOT WRITABLE"

echo ""
echo "=== Check existing pamac desktop files ==="
find /home/deck/.local/share/applications/ /usr/local/share/applications/ /usr/share/applications/ -name '*pamac*' 2>/dev/null || echo "NONE FOUND"

echo ""
echo "=== Check steamos-readonly status ==="
steamos-readonly status 2>/dev/null || echo "steamos-readonly not found"
