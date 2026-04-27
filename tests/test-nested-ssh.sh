#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Single SSH ==="
sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 deck@192.168.2.111 "echo OK1" 2>&1

echo "=== Double SSH ==="
sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 deck@192.168.2.111 "sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 deck@192.168.2.111 echo OK2" 2>&1

echo "=== Triple SSH ==="
sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 deck@192.168.2.111 "sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 deck@192.168.2.111 'sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 deck@192.168.2.111 echo OK3'" 2>&1

echo "=== All done ==="
