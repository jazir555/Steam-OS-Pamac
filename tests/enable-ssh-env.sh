#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Current PermitUserEnvironment ==="
grep -i PermitUserEnvironment /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || echo "NOT_SET"

echo "=== Enabling PermitUserEnvironment ==="
echo "PermitUserEnvironment yes" | echo a | sudo -S tee /etc/ssh/sshd_config.d/permit-user-env.conf 2>/dev/null
echo a | sudo -S chmod 644 /etc/ssh/sshd_config.d/permit-user-env.conf 2>/dev/null
cat /etc/ssh/sshd_config.d/permit-user-env.conf 2>/dev/null

echo "=== Restarting sshd ==="
echo a | sudo -S systemctl restart sshd 2>&1 || echo a | sudo -S rc-service sshd restart 2>&1 || echo "MANUAL_RESTART_NEEDED"

sleep 2

echo "=== Testing nested SSH ==="
sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 deck@192.168.2.111 "echo PATH=\$PATH; which sshpass 2>&1 || echo NO_SSHPASS" 2>&1
