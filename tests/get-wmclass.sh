#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Installing xdotool in container ==="
podman exec arch-pamac pacman -S --noconfirm --needed xorg-xprop xdotool 2>&1 | tail -5

echo ""
echo "=== Finding pamac window ==="
podman exec arch-pamac bash -c '
  export DISPLAY=:0
  for wid in $(xdotool search --classname "" 2>/dev/null); do
    name=$(xprop -id "$wid" _NET_WM_NAME 2>/dev/null | cut -d\" -f2)
    if echo "$name" | grep -qi pamac 2>/dev/null; then
      echo "Found: WID=$wid NAME=\"$name\""
      echo "  WM_CLASS: $(xprop -id "$wid" WM_CLASS 2>/dev/null)"
      echo "  NET_WM_WINDOW_TYPE: $(xprop -id "$wid" _NET_WM_WINDOW_TYPE 2>/dev/null)"
      echo "  _NET_WM_STATE: $(xprop -id "$wid" _NET_WM_STATE 2>/dev/null)"
      echo "  _KDE_NET_WM_DESKTOP_FILE: $(xprop -id "$wid" _KDE_NET_WM_DESKTOP_FILE 2>/dev/null)"
    fi
  done
' 2>&1

echo ""
echo "=== xdotool search by name ==="
podman exec arch-pamac bash -c 'DISPLAY=:0 xdotool search --name "Pamac" 2>&1'
podman exec arch-pamac bash -c 'DISPLAY=:0 xdotool search --name "Add/Remove" 2>&1'
podman exec arch-pamac bash -c 'DISPLAY=:0 xdotool search --name "Software" 2>&1'

echo ""
echo "=== All window names ==="
podman exec arch-pamac bash -c 'DISPLAY=:0 xdotool search --name "." 2>&1 | while read wid; do xprop -id "$wid" _NET_WM_NAME 2>/dev/null; done' 2>&1 | head -30

echo ""
echo "DONE"