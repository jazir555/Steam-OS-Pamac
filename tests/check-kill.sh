#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
echo "=== Signal in log ==="
grep -i "SIGNAL" /tmp/diverse-aur-results-v3.log || echo "No signal caught"
echo "=== OOM kills ==="
dmesg 2>/dev/null | grep -i "oom\|kill" | tail -5 || echo "No dmesg"
echo "=== Journal kills ==="
journalctl --since "5 min ago" 2>/dev/null | grep -i "kill\|oom" | tail -5 || echo "No journal"
echo "=== Process check ==="
ps aux | grep diverse | grep -v grep | head -3 || echo "No diverse process"
