#!/bin/bash
set -uo pipefail

export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Deploying fixed export hook to container ==="
CONTAINER_NAME="arch-pamac"

# Copy the fixed hook into the container
cat /home/deck/.local/share/steamos-pamac/arch-pamac/export-hook.log 2>/dev/null | tail -3
echo "=== Copying fixed hook ==="

# We need to get the hook from the local workspace copy
# But we're on the Deck, so let's just SCP it from the host
echo "Hook must be copied from Windows host via SCP first"
