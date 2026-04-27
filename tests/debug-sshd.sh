#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
echo "=== SSHD Config ==="
grep -vE '^[[:space:]]*#|^[[:space:]]*$' /etc/ssh/sshd_config 2>/dev/null || echo "NO_SSHD_CONFIG"
echo "=== SSHD Config Drop-ins ==="
ls /etc/ssh/sshd_config.d/ 2>/dev/null || echo "NO_DROPINS"
echo "=== Env in nested SSH ==="
sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 deck@192.168.2.111 "echo HOME=\$HOME; echo PATH=\$PATH; type sshpass 2>&1 || echo NO_SSHPASS" 2>&1
