#!/bin/bash
set -euo pipefail

echo "=== Approach: override systemd XDG_DATA_DIRS at session level ==="

# Check if there's a systemd user conf.d we can use
echo "systemd user conf dirs:"
ls -la ~/.config/systemd/user.conf.d/ 2>/dev/null || echo "no user.conf.d"
ls -la ~/.config/systemd/user/ 2>/dev/null | head -20 || echo "no systemd user dir"

echo ""
echo "=== Check plasma-session startup ==="
# Find how plasmashell is started
ps aux 2>/dev/null | grep -i plasma | grep -v grep || true

echo ""
echo "=== Check for plasma startup scripts ==="
ls -la ~/.config/plasma-workspace/env/ 2>/dev/null || echo "no plasma-workspace/env dir"
ls -la ~/.config/autostart/ 2>/dev/null || echo "no autostart dir"

echo ""
echo "=== Check /etc/xdg/plasma-workspace/env/ ==="
ls -la /etc/xdg/plasma-workspace/env/ 2>/dev/null || echo "no /etc/xdg/plasma-workspace/env/"

echo ""
echo "=== Try writing to /usr/local/share with steamos-readonly ==="
# Actually check mount options for /usr/local
mount | grep '/usr/local' || echo "/usr/local not a separate mount"
echo ""
stat /usr/local/share/applications/ 2>/dev/null | head -5

echo ""
echo "=== Check if we can symlink ==="
echo "a" | sudo -S ln -sf /home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop /usr/local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop 2>&1 || echo "symlink failed"
