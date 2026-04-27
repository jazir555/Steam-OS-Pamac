#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
echo "=== Check background script ==="
ps -p 1372059 -o pid,stat,comm 2>/dev/null || echo "Process gone"
echo "=== podman exec sessions ==="
ps aux | grep 'podman.exec' | grep -v grep | head -5
echo "=== conmon exec ==="
ps aux | grep 'conmon.*exec' | grep -v grep | head -5
echo "=== pamac daemon ==="
podman exec arch-pamac ps aux | grep pamac | grep -v grep
