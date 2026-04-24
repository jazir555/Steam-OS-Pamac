#!/bin/bash
# Test script to verify wrapper creation inside container
# This recreates the EXACT commands from the installer's pamac_script

set -euo pipefail

current_user="mmeadow"

echo "Creating pamac-manager launch wrapper..."
printf '%s\n' \
    '#!/bin/bash' \
    'init_proc=$(cat /proc/1/comm 2>/dev/null || echo unknown)' \
    'if [[ "$init_proc" != "systemd" ]]; then' \
    '  if [[ ! -S /run/dbus/system_bus_socket ]]; then' \
    '    mkdir -p /run/dbus 2>/dev/null || true' \
    '    dbus-daemon --system --fork 2>/dev/null || true' \
    '  fi' \
    '  if command -v pamac-daemon >/dev/null 2>&1; then' \
    '    if ! pidof pamac-daemon >/dev/null 2>&1; then' \
    '      pamac-daemon 2>/dev/null &' \
    '      sleep 1' \
    '    fi' \
    '  fi' \
    'fi' \
    'exec pamac-manager "$@"' \
    > /tmp/pamac-manager-wrapper
chmod +x /tmp/pamac-manager-wrapper
echo "Wrapper created successfully."

# Verify content
echo "=== Wrapper content ==="
cat /tmp/pamac-manager-wrapper
echo "=== Syntax check ==="
bash -n /tmp/pamac-manager-wrapper && echo "Syntax OK"
