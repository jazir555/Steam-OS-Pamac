#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== xdg-mime query ==="
xdg-mime query default x-scheme-handler/appstream 2>&1

echo "=== mimeapps.list ==="
cat ~/.config/mimeapps.list

echo "=== NoDisplay handler file ==="
cat ~/.local/share/applications/steamos-pamac-no-appstream-handler.desktop

echo "=== kreadconfig6 ==="
kreadconfig6 --file mimeapps.list --group "Default Applications" --key "x-scheme-handler/appstream" 2>&1

echo "=== desktop-file-validate ==="
desktop-file-validate ~/.local/share/applications/steamos-pamac-no-appstream-handler.desktop 2>&1

echo "=== KApplicationTrader test via ktrade ==="
qdbus org.kde.kiod5 2>&1 || echo "kiod5 not available"

echo "=== Check if KDE sees the handler ==="
kbuildsycoca6 --nocheckfiles 2>&1 | tail -5
echo "sycoca updated"

echo "=== Check preferredService via python ==="
python3 -c "
import subprocess, os
os.environ['DISPLAY'] = ':0'
os.environ['XDG_RUNTIME_DIR'] = '/run/user/1000'
result = subprocess.run(['kreadconfig6', '--file', 'mimeapps.list', '--group', 'Default Applications', '--key', 'x-scheme-handler/appstream'], capture_output=True, text=True)
print('kreadconfig6 result:', repr(result.stdout.strip()))
" 2>&1

echo "=== kickeraction handler log ==="
cat ~/.local/share/steamos-pamac/arch-pamac/kickeraction-handler.log 2>&1 | tail -20

echo "=== Celluloid desktop still exists? ==="
ls -la ~/.local/share/applications/arch-pamac-io.github.celluloid_player.Celluloid.desktop 2>&1

echo "=== exported-apps.list ==="
cat ~/.local/share/steamos-pamac/arch-pamac/exported-apps.list 2>&1
