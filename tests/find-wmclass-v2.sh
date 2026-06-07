#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Install xdotool in container ==="
podman exec arch-pamac pacman -S --noconfirm --needed xorg-xprop xdotool 2>&1 | tail -3

echo ""
echo "=== Check DISPLAY in container ==="
podman exec arch-pamac bash -c 'echo "DISPLAY=$DISPLAY"; ls -la /tmp/.X11-unix/ 2>&1 || echo "no X11 socket"'

echo ""
echo "=== List all windows from container ==="
podman exec arch-pamac bash -c '
  export DISPLAY=:0
  xdotool search --onlyvisible --name "" 2>/dev/null | while read wid; do
    name="$(xprop -id "$wid" _NET_WM_NAME 2>/dev/null | cut -d\" -f2)"
    echo "WID=$wid NAME=\"$name\""
  done
' 2>&1 | head -20

echo ""
echo "=== Searching for Pamac windows ==="
podman exec arch-pamac bash -c '
  export DISPLAY=:0
  for wid in $(xdotool search --onlyvisible --name "" 2>/dev/null); do
    name="$(xprop -id "$wid" _NET_WM_NAME 2>/dev/null | cut -d\" -f2)"
    if echo "$name" | grep -qi pamac 2>/dev/null; then
      echo "=== PAMAC WINDOW FOUND ==="
      echo "WID=$wid"
      echo "NAME=\"$name\""
      echo "WM_CLASS: $(xprop -id "$wid" WM_CLASS 2>/dev/null)"
      echo "WM_NAME: $(xprop -id "$wid" WM_NAME 2>/dev/null)"
      echo "_NET_WM_WINDOW_TYPE: $(xprop -id "$wid" _NET_WM_WINDOW_TYPE 2>/dev/null)"
      echo "_NET_WM_STATE: $(xprop -id "$wid" _NET_WM_STATE 2>/dev/null)"
      echo "_KDE_NET_WM_DESKTOP_FILE: $(xprop -id "$wid" _KDE_NET_WM_DESKTOP_FILE 2>/dev/null)"
    fi
  done
' 2>&1

echo ""
echo "DONE"