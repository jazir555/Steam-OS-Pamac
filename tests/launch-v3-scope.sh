#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

rm -f /tmp/diverse-aur-v3.pid
> /tmp/diverse-aur-results-v3.log

echo "Launching via systemd-run --user --scope ..."
systemd-run --user --scope -u diverse-aur-test bash /tmp/diverse-aur-run-v3.sh </dev/null >/tmp/diverse-aur-results-v3.log 2>&1 &
PID=$!
echo $PID > /tmp/diverse-aur-v3.pid

sleep 3
ps -p $PID -o pid,stat,comm 2>/dev/null && echo "Process alive" || echo "Process dead"
wc -l /tmp/diverse-aur-results-v3.log
tail -5 /tmp/diverse-aur-results-v3.log
