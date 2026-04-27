#!/bin/bash
podman exec -u 0 arch-pamac bash -c 'pkill pamac-daemon 2>/dev/null; pkill polkitd 2>/dev/null; pkill dbus-daemon 2>/dev/null; sleep 1; rm -f /run/dbus/pid; mkdir -p /run/dbus; dbus-daemon --system --fork; sleep 1; /usr/lib/polkit-1/polkitd --no-debug & sleep 1; /usr/bin/pamac-daemon & sleep 2' </dev/null
echo "Daemon restarted"
podman exec -u 0 arch-pamac pamac --version </dev/null 2>&1 | head -2
