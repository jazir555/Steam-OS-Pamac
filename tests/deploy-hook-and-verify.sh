#!/bin/bash
set +e

echo "=== Deploying fixed export hook to container ==="

# Copy the fixed hook from /tmp into the container
podman cp /tmp/distrobox-export-hook.sh arch-pamac:/usr/local/bin/distrobox-export-hook.sh 2>&1
RC=$?
if [[ $RC -ne 0 ]]; then
    echo "ERROR: podman cp failed with exit code $RC"
    exit 1
fi

podman exec -i arch-pamac chmod +x /usr/local/bin/distrobox-export-hook.sh 2>&1
echo "Hook deployed and made executable"

# Verify the fix is in place
echo "=== Verifying hook contains Actions fix ==="
podman exec -i arch-pamac grep -n 'existing_actions' /usr/local/bin/distrobox-export-hook.sh 2>&1
if [[ $? -eq 0 ]]; then
    echo "PASS: Hook contains existing_actions fix"
else
    echo "FAIL: Hook does NOT contain existing_actions fix"
    exit 1
fi

# Remove the old broken LibreWolf desktop file so the hook regenerates it fresh
echo "=== Removing old broken LibreWolf desktop file ==="
rm -f /home/deck/.local/share/applications/arch-pamac-librewolf.desktop 2>&1
echo "Old desktop file removed"

# Re-run the export hook inside the container
echo "=== Re-running export hook ==="
podman exec -i -u 0 arch-pamac /usr/local/bin/distrobox-export-hook.sh 2>&1
RC=$?
echo "Export hook exit code: $RC"

# Check the regenerated LibreWolf desktop file
echo "=== Checking LibreWolf desktop file ==="
if [[ -f /home/deck/.local/share/applications/arch-pamac-librewolf.desktop ]]; then
    echo "LibreWolf desktop file exists"
    echo "--- Actions line ---"
    grep '^Actions=' /home/deck/.local/share/applications/arch-pamac-librewolf.desktop 2>&1
    echo "--- X-SteamOS markers ---"
    grep '^X-SteamOS' /home/deck/.local/share/applications/arch-pamac-librewolf.desktop 2>&1
    echo "--- Desktop Action sections ---"
    grep '^\[Desktop Action' /home/deck/.local/share/applications/arch-pamac-librewolf.desktop 2>&1
else
    echo "FAIL: LibreWolf desktop file not found"
    echo "Checking what arch-pamac desktop files exist:"
    ls -la /home/deck/.local/share/applications/arch-pamac-*.desktop 2>&1
fi

# Run desktop-file-validate
echo "=== Running desktop-file-validate ==="
if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate /home/deck/.local/share/applications/arch-pamac-librewolf.desktop 2>&1
    RC=$?
    if [[ $RC -eq 0 ]]; then
        echo "PASS: desktop-file-validate reports no errors"
    else
        echo "FAIL: desktop-file-validate reports errors (exit code $RC)"
    fi
else
    echo "desktop-file-validate not found on host, trying in container..."
    podman exec -i arch-pamac desktop-file-validate /usr/share/applications/librewolf.desktop 2>&1 || true
    echo "NOTE: Cannot validate host desktop file from container"
fi

# Check kickeraction file
echo "=== Checking kickeraction file ==="
if [[ -f /home/deck/.local/share/plasma/kickeractions/steamos-pamac-uninstall.desktop ]]; then
    cat /home/deck/.local/share/plasma/kickeractions/steamos-pamac-uninstall.desktop
else
    echo "FAIL: Kickeraction file not found"
fi

# Rebuild KDE service cache with proper environment
echo "=== Rebuilding KDE service cache ==="
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export XDG_DATA_DIRS=/home/deck/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share
export XDG_DATA_HOME=/home/deck/.local/share
export XDG_CONFIG_DIRS=/home/deck/.config/kdedefaults:/etc/xdg
export XDG_CURRENT_DESKTOP=KDE

kbuildsycoca6 --noincremental 2>&1
echo "kbuildsycoca6 exit code: $?"

# Try to verify LibreWolf appears in the menu
echo "=== Checking if LibreWolf appears in KDE menu ==="
if command -v kioclient6 >/dev/null 2>&1; then
    kioclient6 cat applications:///arch-pamac-librewolf.desktop 2>&1 | head -5
    if [[ $? -eq 0 ]]; then
        echo "PASS: LibreWolf found in applications:///"
    else
        echo "WARN: LibreWolf not found in applications:/// (may need plasmashell restart)"
    fi
else
    echo "kioclient6 not available"
fi

echo "=== Done ==="
