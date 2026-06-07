#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Search pamac-manager binary for WM_CLASS ==="
podman exec arch-pamac bash -c 'strings /usr/bin/pamac-manager | grep -iE "wm.class|pamac.manager|prgname"' | head -20

echo ""
echo "=== Check GTK app ID from desktop file ==="
podman exec arch-pamac grep -E 'Name|Exec|StartupWMClass|DBusActivatable' /usr/share/applications/org.manjaro.pamac.manager.desktop

echo ""
echo "=== Check if GSETTINGS or env might affect window class ==="
podman exec arch-pamac bash -c 'ls /usr/share/glib-2.0/schemas/ | grep -i pamac' 2>/dev/null || echo "no schemas"

echo ""
echo "DONE"