#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Testing handler with non-pamac URL (should fall through to Discover) ==="
/home/deck/.local/bin/steamos-pamac-appstream-handler 'appstream://org.kde.gwenview' &
HANDLER_PID=$!
sleep 3
echo "=== Handler logs ==="
cat ~/.local/share/steamos-pamac/arch-pamac/appstream-handler.log 2>&1
echo "=== Done ==="
