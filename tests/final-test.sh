#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Container wrapper ==="
podman exec arch-pamac cat /usr/local/bin/pamac-manager-wrapper

echo ""
echo "=== Running pamac ==="
pgrep -a pamac 2>/dev/null || echo "not running"

echo ""
echo "=== Killing for fresh test ==="
pkill -f pamac-manager 2>/dev/null || true
sleep 1

echo ""
echo "=== Launch via host wrapper ==="
nohup /home/deck/.local/bin/pamac-manager-wrapper-host > /tmp/wrapper-host.log 2>&1 &
echo "PID=$!"

echo ""
echo "=== Wait 15 seconds ==="
echo "The wrapper will find the window and set _KDE_NET_WM_DESKTOP_FILE"
echo "Check the KDE taskbar now — the Pamac icon should appear"
echo ""
echo "=== After launch, verify ==="
echo "Run: DISPLAY=:0 XAUTHORITY=\$(ls -t /run/user/1000/xauth_* | head -1) xprop -id \$(xdotool search --class pamac-manager 2>/dev/null | tail -1) _KDE_NET_WM_DESKTOP_FILE"