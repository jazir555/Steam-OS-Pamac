#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Backing up Plasma panel config ==="
mkdir -p /home/deck/plasma-backup
cp /home/deck/.config/plasma-org.kde.plasma.desktop-appletsrc /home/deck/plasma-backup/ 2>/dev/null || echo "no appletsrc"
cp /home/deck/.config/plasmashellrc /home/deck/plasma-backup/ 2>/dev/null || echo "no plasmashellrc"
cp /home/deck/.config/latte/* /home/deck/plasma-backup/ 2>/dev/null || true
echo "Backup saved to /home/deck/plasma-backup/"

echo ""
echo "=== Current panel state ==="
grep -A5 '\[Containments\]\[1\]' /home/deck/.config/plasma-org.kde.plasma.desktop-appletsrc 2>/dev/null | head -20

echo ""
echo "=== Removing panel config to reset to defaults ==="
rm -f /home/deck/.config/plasma-org.kde.plasma.desktop-appletsrc
rm -f /home/deck/.config/plasmashellrc
echo "Config removed. Restarting plasmashell..."

systemctl --user restart plasma-plasmashell.service 2>&1
sleep 3

echo ""
echo "=== Verification ==="
if pgrep -x plasmashell >/dev/null 2>&1; then
  echo "plasmashell is running"
else
  echo "plasmashell not running - starting..."
  systemctl --user start plasma-plasmashell.service 2>&1
  sleep 3
fi

echo ""
echo "=== Check panel config recreated ==="
ls -la /home/deck/.config/plasma-org.kde.plasma.desktop-appletsrc 2>/dev/null
ls -la /home/deck/.config/plasmashellrc 2>/dev/null

echo ""
echo "DONE - check the taskbar on the Deck screen"