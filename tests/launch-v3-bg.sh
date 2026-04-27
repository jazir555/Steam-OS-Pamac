#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
setsid bash /tmp/diverse-aur-run-v3.sh </dev/null >/tmp/diverse-aur-results-v3.log 2>&1 &
echo "Test launched. PID=$!"
