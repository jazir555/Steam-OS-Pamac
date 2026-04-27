#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
systemd-run --user --scope -u diverse-aur-test bash /tmp/diverse-aur-run-v3.sh </dev/null >/tmp/diverse-aur-results-v3.log 2>&1 &
echo "Test launched. PID=$!"
