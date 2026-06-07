#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

DESKTOP_FILE="/home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop"

echo "=== Check available KDE launchers ==="
which kstart5 2>&1 || which kstart 2>&1 || echo "no kstart"
which kioclient5 2>&1 || which kioclient 2>&1 || echo "no kioclient"
which kdeinit5 2>&1 || echo "no kdeinit5"

echo ""
echo "=== Check if pamac window has skip-taskbar via wmctrl ==="
podman exec arch-pamac bash -c '
  which wmctrl 2>/dev/null || echo "wmctrl not installed"
'

echo ""
echo "=== Check pamac binary for window class hints ==="
podman exec arch-pamac bash -c 'strings /usr/bin/pamac-manager | grep -iE "set_program_class|set_prgname|set_application_name|wmclass|gdk.*class"' | head -10

echo ""
echo "=== Check gtk4 class registration in strings ==="
podman exec arch-pamac bash -c 'strings /usr/bin/pamac-manager | grep "org.manjaro"' | head -5

echo ""
echo "=== Check g_application_id usage ==="
podman exec arch-pamac bash -c 'strings /usr/bin/pamac-manager | grep "application.id"' | head -5

echo ""
echo "DONE"