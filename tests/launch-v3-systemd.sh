#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

> /tmp/diverse-aur-results-v3.log

echo "a" | sudo -S systemd-run --unit=diverse-aur-test --scope bash /tmp/diverse-aur-run-v3.sh </dev/null >/tmp/diverse-aur-results-v3.log 2>&1 &
echo "Launched PID=$!"

sleep 3
ps aux | grep diverse-aur-run | grep -v grep | head -3
wc -l /tmp/diverse-aur-results-v3.log
