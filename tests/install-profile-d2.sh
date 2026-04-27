#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo 'export PATH="/home/deck/.local/bin:$PATH"' > /tmp/deck-local-bin.sh
echo a | sudo -S cp /tmp/deck-local-bin.sh /etc/profile.d/deck-local-bin.sh 2>/dev/null
echo a | sudo -S chmod +x /etc/profile.d/deck-local-bin.sh 2>/dev/null
echo "=== Profile.d contents ==="
cat /etc/profile.d/deck-local-bin.sh 2>/dev/null

echo "=== Testing nested SSH ==="
sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 deck@192.168.2.111 "echo PATH=\$PATH; which sshpass 2>&1 || echo NO_SSHPASS" 2>&1
