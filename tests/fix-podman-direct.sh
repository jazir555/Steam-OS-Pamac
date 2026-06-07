#!/bin/bash
export HOME=/home/deck

DESKTOP_FILE="/home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop"

echo "=== Direct podman exec launcher ==="
echo "This script creates a host-side wrapper and updates the desktop file"

# Create host-side wrapper
cat > /home/deck/.local/bin/pamac-launcher << 'PAMAC_WRAPPER'
#!/bin/bash
# Direct podman exec launcher for Pamac
# Bypasses distrobox enter to avoid startup notification PID mismatch
export HOME=/home/deck
export DISPLAY=${DISPLAY:-:0}
export XDG_CURRENT_DESKTOP=KDE
exec podman exec -e DISPLAY -e XDG_CURRENT_DESKTOP arch-pamac pamac-manager "$@"
PAMAC_WRAPPER

chmod +x /home/deck/.local/bin/pamac-launcher
echo "Created /home/deck/.local/bin/pamac-launcher"

# Update desktop file
sed -i 's|^Exec=.*|Exec=/home/deck/.local/bin/pamac-launcher %U|' "$DESKTOP_FILE"

echo ""
echo "=== Updated desktop file ==="
grep -E '^(Exec|Startup)' "$DESKTOP_FILE"

echo ""
kbuildsycoca6 --noincremental 2>&1 | tail -2
dbus-send --session --type=signal /KSycoca org.kde.KSycoca.databaseChanged 2>&1
echo "READY"