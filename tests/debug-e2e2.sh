#!/bin/bash
set -euo pipefail

SSH_HOST="deck@192.168.2.110"
CONTAINER_NAME="arch-pamac"

if grep -qi microsoft /proc/version 2>/dev/null || uname -r 2>/dev/null | grep -qi microsoft; then
SSH_CMD="sshpass -p 'a' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"
elif command -v wsl.exe >/dev/null 2>&1; then
SSH_CMD="wsl -d Arch -- sshpass -p 'a' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"
else
SSH_CMD="sshpass -p 'a' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"
fi

echo "SSH_CMD: $SSH_CMD"

ssh_check() { eval "$SSH_CMD '$SSH_HOST' \"$@\" 2>/dev/null"; }
ssh_exec() { eval "$SSH_CMD '$SSH_HOST' \"$@\""; }

distrobox_exec() {
    local cmd="${1//\'/\\\'}"
    local timeout_sec="${2:-}"
    echo "DEBUG distrobox_exec: cmd=[$cmd] timeout=[$timeout_sec]"
    if [[ -n "$timeout_sec" ]]; then
        local full_cmd="timeout $timeout_sec distrobox-enter '$CONTAINER_NAME' -- bash -c '$cmd' 2>&1"
        echo "DEBUG full_cmd=[$full_cmd]"
        ssh_check "$full_cmd"
    else
        local full_cmd="distrobox-enter '$CONTAINER_NAME' -- bash -c '$cmd' 2>&1"
        echo "DEBUG full_cmd=[$full_cmd]"
        ssh_check "$full_cmd"
    fi
}

echo "=== Test: distrobox_exec pamac search ==="
result=$(distrobox_exec "pamac search neofetch 2>/dev/null" 30 2>&1)
echo "Result: [$result]" | head -5

echo ""
echo "=== Test: what ssh_check actually runs ==="
full_cmd="timeout 30 distrobox-enter 'arch-pamac' -- bash -c 'pamac search neofetch 2>/dev/null' 2>&1"
echo "eval command: eval \"$SSH_CMD '$SSH_HOST' \\\"$full_cmd\\\" 2>/dev/null\""
