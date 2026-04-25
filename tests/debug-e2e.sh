#!/bin/bash
set -euo pipefail

SSH_HOST="deck@192.168.2.110"
CONTAINER_NAME="arch-pamac"

SSH_CMD="sshpass -p 'a' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"

ssh_check() { eval "$SSH_CMD '$SSH_HOST' \"$@\" 2>/dev/null"; }

distrobox_exec() {
    local cmd="${1//\'/\\\'}"
    local timeout_sec="${2:-}"
    if [[ -n "$timeout_sec" ]]; then
        ssh_check "timeout $timeout_sec distrobox-enter '$CONTAINER_NAME' -- bash -c '$cmd' 2>&1"
    else
        ssh_check "distrobox-enter '$CONTAINER_NAME' -- bash -c '$cmd' 2>&1"
    fi
}

echo "=== Test 1: echo ==="
result=$(distrobox_exec "echo hello_world" 10 2>&1)
echo "Result: [$result]"

echo "=== Test 2: pamac search ==="
result=$(distrobox_exec "pamac search neofetch 2>/dev/null" 30 2>&1 | head -3)
echo "Result: [$result]"

echo "=== Test 3: direct ssh_check ==="
result=$(ssh_check "timeout 30 distrobox-enter arch-pamac -- bash -c 'pamac search neofetch 2>/dev/null' 2>&1" | head -3)
echo "Result: [$result]"
