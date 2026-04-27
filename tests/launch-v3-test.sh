#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "Restarting pamac daemon..."
bash /tmp/restart-pamac-daemon.sh

echo ""
echo "Cleaning up neofetch from quick test..."
podman exec -u 0 arch-pamac pamac remove --no-confirm --no-save --no-orphans neofetch </dev/null 2>&1 | tail -2

echo ""
echo "Launching diverse AUR test v3 in background..."
nohup bash /tmp/diverse-aur-run-v3.sh </dev/null >/tmp/diverse-aur-results-v3.log 2>&1 &
disown
echo "Test launched as PID $!"
echo "Monitor: tail -f /tmp/diverse-aur-results-v3.log"
