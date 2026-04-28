#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

KWIN_PID=$(pgrep -x kwin_x11 2>/dev/null | head -1)
if [[ -z "$KWIN_PID" ]]; then
    echo "ERROR: kwin_x11 not found"
    exit 1
fi

# Read kwin's environment - deck user owns kwin so /proc/PID/environ should be readable
ENV_DATA=$(cat /proc/$KWIN_PID/environ 2>/dev/null | tr '\0' '\n')
if [[ -z "$ENV_DATA" ]]; then
    ENV_DATA=$(echo a | sudo -S cat /proc/$KWIN_PID/environ 2>/dev/null | tr '\0' '\n')
fi

# Extract and export needed vars
while IFS= read -r line; do
    case "$line" in
        DISPLAY=*) export "$line" ;;
        XAUTHORITY=*) export "$line" ;;
        DBUS_SESSION_BUS_ADDRESS=*) export "$line" ;;
        XDG_RUNTIME_DIR=*) export "$line" ;;
    esac
done <<< "$ENV_DATA"

echo "DISPLAY=$DISPLAY"
echo "XAUTHORITY=$XAUTHORITY"
echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"
echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"

if [[ -z "$DISPLAY" || -z "$DBUS_SESSION_BUS_ADDRESS" ]]; then
    echo "ERROR: Missing critical env vars"
    exit 1
fi

# Kill any existing plasmashell
pkill plasmashell 2>/dev/null
sleep 1

# Start plasmashell
nohup plasmashell </dev/null >$HOME/plasmashell-restart.log 2>&1 &
PLASMA_PID=$!
echo "Started plasmashell PID=$PLASMA_PID"

sleep 5

if kill -0 $PLASMA_PID 2>/dev/null; then
    echo "SUCCESS: plasmashell is running (PID=$PLASMA_PID)"
else
    echo "FAILED: plasmashell crashed"
    echo "--- Log ---"
    tail -20 $HOME/plasmashell-restart.log 2>/dev/null
fi
