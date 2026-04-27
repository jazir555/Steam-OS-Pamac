#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
PID=$(cat /tmp/diverse-aur-v3.pid 2>/dev/null || echo "unknown")
ps -p "$PID" -o pid,stat,comm 2>/dev/null || echo "Process $PID gone"
wc -l /tmp/diverse-aur-results-v3.log
tail -25 /tmp/diverse-aur-results-v3.log
