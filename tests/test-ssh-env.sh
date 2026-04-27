#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

mkdir -p /home/deck/.ssh
echo "PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin" > /home/deck/.ssh/environment
chmod 600 /home/deck/.ssh/environment
echo "=== .ssh/environment ==="
cat /home/deck/.ssh/environment

echo "=== Testing nested SSH ==="
sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 deck@192.168.2.111 "echo PATH=\$PATH; which sshpass 2>&1 || echo NO_SSHPASS" 2>&1
