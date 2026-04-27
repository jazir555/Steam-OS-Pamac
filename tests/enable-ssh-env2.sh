#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "a" | sudo -S bash -c 'echo "PermitUserEnvironment yes" > /etc/ssh/sshd_config.d/permit-user-env.conf && chmod 644 /etc/ssh/sshd_config.d/permit-user-env.conf && echo WRITTEN && cat /etc/ssh/sshd_config.d/permit-user-env.conf' 2>&1

echo "=== Restarting sshd ==="
echo "a" | sudo -S bash -c 'systemctl restart sshd 2>&1 || kill -HUP $(cat /run/sshd.pid 2>/dev/null || pgrep -f "sshd:.*listener" | head -1) 2>&1; echo RESTARTED' 2>&1

sleep 2

echo "=== Testing nested SSH ==="
sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 deck@192.168.2.111 "echo PATH=\$PATH; which sshpass 2>&1 || echo NO_SSHPASS" 2>&1
