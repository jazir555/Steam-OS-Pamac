#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "Killing any stale diverse-aur processes..."
for pid in $(ps aux | grep 'diverse-aur-run-v3' | grep -v grep | awk '{print $2}'); do
  kill -9 "$pid" 2>/dev/null
  echo "Killed $pid"
done

echo "Killing stale podman exec conmon processes..."
for pid in $(ps aux | grep 'conmon.*exec' | grep -v grep | awk '{print $2}'); do
  kill -9 "$pid" 2>/dev/null
  echo "Killed conmon $pid"
done

sleep 1

echo "Cleaning stale temp dirs..."
rm -rf /tmp/tmp.*/pamac_ver /tmp/tmp.*/search_out /tmp/tmp.*/pkg_check /tmp/tmp.*/inst 2>/dev/null

echo "Verifying pamac works..."
timeout 10 podman exec -u 0 arch-pamac pamac --version </dev/null 2>&1 | head -1

echo "Done"
