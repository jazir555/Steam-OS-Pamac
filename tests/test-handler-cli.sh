#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

echo "=== Testing handler with celluloid URL ==="
/home/deck/.local/bin/steamos-pamac-appstream-handler 'appstream://io.github.celluloid_player.Celluloid' &
HANDLER_PID=$!
sleep 5
echo "=== Handler PID: $HANDLER_PID ==="
echo "=== Handler logs ==="
cat ~/.local/share/steamos-pamac/arch-pamac/appstream-handler.log 2>&1
echo "=== Done ==="
