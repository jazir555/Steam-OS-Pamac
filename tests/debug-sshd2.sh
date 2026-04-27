#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
echo "=== Direct: PATH=$PATH ==="
echo "=== Direct: which sshpass ==="
which sshpass 2>&1 || echo "NOT_FOUND_DIRECT"

echo "=== Nested SSH env ==="
sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 deck@192.168.2.111 "echo PATH=\$PATH; echo BASHRC_SOURCED=\$(grep -c local /home/deck/.bashrc 2>/dev/null); cat /home/deck/.bashrc; echo ---; ls -la /home/deck/.local/bin/sshpass" 2>&1
