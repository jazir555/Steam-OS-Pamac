#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

if [[ ! -f /etc/profile.d/deck-local-bin.sh ]]; then
    echo 'export PATH="/home/deck/.local/bin:$PATH"' | sudo tee /etc/profile.d/deck-local-bin.sh
    sudo chmod +x /etc/profile.d/deck-local-bin.sh
    echo "Created /etc/profile.d/deck-local-bin.sh"
else
    echo "/etc/profile.d/deck-local-bin.sh already exists"
fi

echo "=== Testing nested SSH with profile.d ==="
sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 deck@192.168.2.111 "echo PATH=\$PATH; which sshpass 2>&1 || echo NO_SSHPASS" 2>&1
