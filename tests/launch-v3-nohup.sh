#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
rm -f /tmp/diverse-aur-v3.pid
> /tmp/diverse-aur-results-v3.log
nohup bash /tmp/diverse-aur-run-v3.sh </dev/null >/tmp/diverse-aur-results-v3.log 2>&1 &
echo $! > /tmp/diverse-aur-v3.pid
echo "Launched PID=$(cat /tmp/diverse-aur-v3.pid)"
sleep 2
ps -p $(cat /tmp/diverse-aur-v3.pid) -o pid,stat,comm 2>/dev/null || echo "Process already gone!"
wc -l /tmp/diverse-aur-results-v3.log
