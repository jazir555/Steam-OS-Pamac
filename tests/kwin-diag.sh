#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Check KWin version ==="
kwin_x11 --version 2>&1 || kwin_wayland --version 2>/dev/null || echo "no kwin binary"

echo ""
echo "=== List windows via qdbus ==="
qdbus org.kde.KWin /KWin 2>&1 | head -20

echo ""
echo "=== Try org.kde.KWin methods ==="
qdbus org.kde.KWin /KWin org.kde.KWin.supportInformation 2>&1 | head -30

echo ""
echo "=== Check for pamac in KWin windows ==="
qdbus org.kde.KWin /KWin org.kde.KWin.supportInformation 2>&1 | grep -i pamac

echo ""
echo "=== Try scripting API ==="
qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript /dev/stdin 2>&1 << 'SCRIPTEOF'
const clients = workspace.clientList();
for (let i = 0; i < clients.length; i++) {
    const c = clients[i];
    print(c.resourceName + " | " + c.resourceClass + " | " + c.caption + " | skipTaskbar=" + c.skipTaskbar + " | windowType=" + c.windowType);
}
SCRIPTEOF

echo ""
echo "DONE"