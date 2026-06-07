#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

DESKTOP_FILE="/home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop"

echo "=== Install xdotool in container ==="
podman exec arch-pamac pacman -Sy --noconfirm xorg-xprop xdotool 2>&1 | tail -5

echo ""
echo "=== Check if xdotool works from container ==="
podman exec arch-pamac bash -c 'export DISPLAY=:0; xdotool search --name "Pamac" 2>&1' 2>&1

echo ""
echo "=== Find all windows from container ==="
podman exec arch-pamac bash -c 'export DISPLAY=:0; xdotool search --onlyvisible "" 2>&1 | while read wid; do wmname=$(xprop -id "$wid" WM_NAME 2>/dev/null); echo "WID=$wid $wmname"; done' 2>&1 | head -20

echo ""
echo "=== Search for any window with Software or Add/Remove in name ==="
podman exec arch-pamac bash -c 'export DISPLAY=:0; xdotool search --onlyvisible "" 2>&1 | while read wid; do name=$(xprop -id "$wid" _NET_WM_NAME 2>/dev/null | cut -d\" -f2); if echo "$name" | grep -qiE "software|pamac|remove|add" 2>/dev/null; then echo "FOUND: WID=$wid NAME=$name"; xprop -id "$wid" WM_CLASS _NET_WM_WINDOW_TYPE _NET_WM_STATE _KDE_NET_WM_DESKTOP_FILE 2>/dev/null; fi; done' 2>&1

echo ""
echo "DONE"