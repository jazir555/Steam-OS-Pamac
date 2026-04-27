#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo a | sudo -S cp /tmp/diverse-aur-test.service /etc/systemd/system/diverse-aur-test.service
echo a | sudo -S systemctl daemon-reload
echo a | sudo -S bash -c 'echo > /tmp/diverse-aur-results-v3.log'
echo a | sudo -S systemctl start diverse-aur-test
sleep 3
echo a | sudo -S systemctl status diverse-aur-test 2>&1 | head -10
wc -l /tmp/diverse-aur-results-v3.log
tail -5 /tmp/diverse-aur-results-v3.log
