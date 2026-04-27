#!/bin/bash
echo "HOME=$HOME"
echo "PATH=$PATH"
echo "SSH_SELF_TEST:"
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 deck@192.168.2.111 "echo SELF_SSH_OK" 2>&1
