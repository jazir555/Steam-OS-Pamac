#!/bin/bash
podman rm -f test-noinit 2>/dev/null
podman rm -f test-withinit 2>/dev/null
podman rm -f arch-pamac 2>/dev/null
echo "--- dmesg OOM check ---"
dmesg 2>/dev/null | grep -i 'killed process\|oom' | tail -10 || echo "No OOM events found"
echo "--- Containers ---"
podman ps -a
