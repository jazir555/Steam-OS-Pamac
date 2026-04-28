#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
export DISPLAY=:0
export XAUTHORITY=/run/user/1000/xauth_bnwaof
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

echo "=== Check what appstream handler KDE discovers ==="
qdbus org.kde.plasmashell 2>&1 | head -3 || echo "plasmashell not on dbus"

echo "=== List all appstream mime handlers ==="
grep -r "x-scheme-handler/appstream" ~/.local/share/applications/ /usr/share/applications/ 2>/dev/null

echo "=== Check Discover desktop file ==="
find /usr/share/applications -name "*discover*" -o -name "*packagekit*" 2>/dev/null | head -10

echo "=== Check if discover is installed ==="
which discover 2>&1
rpm -q discover 2>/dev/null || pacman -Q discover 2>/dev/null || echo "discover package not found via rpm/pacman"
flatpak list 2>/dev/null | grep -i discover || echo "no flatpak discover"

echo "=== Check plasma-discover desktop ==="
cat /usr/share/applications/org.kde.discover.desktop 2>/dev/null | head -20 || echo "no discover desktop file"

echo "=== Check what services handle appstream ==="
find /usr/share/applications ~/.local/share/applications -name "*.desktop" -exec grep -l "x-scheme-handler/appstream" {} \; 2>/dev/null

echo "=== Check KApplicationTrader behavior ==="
# Test if NoDisplay really makes preferredService return null
python3 << 'PYEOF'
import subprocess, os

# Check what xdg-mime returns
result = subprocess.run(['xdg-mime', 'query', 'default', 'x-scheme-handler/appstream'], 
                       capture_output=True, text=True)
print(f"xdg-mime default: {result.stdout.strip()}")

# Check the desktop file
handler = result.stdout.strip()
if handler:
    paths = [
        os.path.expanduser(f'~/.local/share/applications/{handler}'),
        f'/usr/share/applications/{handler}'
    ]
    for p in paths:
        if os.path.exists(p):
            with open(p) as f:
                print(f"\nContent of {p}:")
                print(f.read())
            break
    else:
        print(f"Handler desktop file not found: {handler}")
PYEOF

echo "=== Check sycoca cache for appstream ==="
kbuildsycoca6 2>&1 | tail -5
