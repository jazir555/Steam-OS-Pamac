#!/bin/bash
# WSL test runner for SteamOS-Pamac-Installer
set -euo pipefail

INSTALLER="/mnt/c/Users/mmeadow/Documents/Steam-OS-Pamac/SteamOS-Pamac-Installer.sh"

echo "=== Syntax Check ==="
if bash -n "$INSTALLER"; then
    echo "SYNTAX OK"
else
    echo "SYNTAX ERROR"
    exit 1
fi

echo "=== Running --check ==="
bash "$INSTALLER" --check 2>&1
echo "CHECK exit code: $?"

echo "=== Running install (normal mode) ==="
set +e
bash "$INSTALLER" 2>&1
exit_code=$?
set -e
echo "INSTALL exit code: $exit_code"

echo "=== Checking for output artifacts ==="
echo "Container status:"
podman ps -a --filter "name=arch-pamac" --format "{{.Names}} {{.Status}}" 2>/dev/null || echo "  No containers"

echo "Desktop files:"
find "$HOME/.local/share/applications" -maxdepth 1 -name "arch-pamac-*.desktop" 2>/dev/null || echo "  None found"

echo "Export state:"
ls -la "$HOME/.local/share/steamos-pamac/arch-pamac/" 2>/dev/null || echo "  Not found"

echo "CLI wrapper:"
ls -la "$HOME/.local/bin/pamac-arch-pamac" 2>/dev/null || echo "  Not found"

echo "=== Full log tail ==="
tail -50 "$HOME/distrobox-pamac-setup.log" 2>/dev/null || echo "  No log found"
