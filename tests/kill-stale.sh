#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "Killing stale podman exec conmon processes..."
kill 1356190 2>/dev/null
sleep 1
kill -9 1356190 2>/dev/null

echo "Checking remaining conmon processes..."
ps aux | grep conmon | grep -v grep | grep exec | head -5

echo "Done"
