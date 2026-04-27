#!/bin/bash
# Monitor the diverse AUR test progress and write results to a local file
# Usage: bash monitor-diverse-test.sh

SSH_HOST="deck@192.168.2.111"
SSH_PASS="a"
LOG_FILE="/tmp/diverse-aur-results-v3.log"

while true; do
    RESULT=$(wsl -d Arch -- sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$SSH_HOST" "export HOME=/home/deck; export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin; tail -5 $LOG_FILE 2>/dev/null" 2>/dev/null)
    if [[ -z "$RESULT" ]]; then
        echo "Cannot connect to Deck or log file empty"
        sleep 30
        continue
    fi
    echo "$(date +%H:%M:%S): $RESULT"
    
    # Check if test is complete
    if echo "$RESULT" | grep -q "Diverse AUR Package Test Results"; then
        echo "=== TEST COMPLETE ==="
        wsl -d Arch -- sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "$SSH_HOST" "export HOME=/home/deck; export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin; cat $LOG_FILE" 2>/dev/null | tail -20
        break
    fi
    
    sleep 60
done
