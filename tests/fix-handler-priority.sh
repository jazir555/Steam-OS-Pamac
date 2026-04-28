#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

HANDLER_DESKTOP=~/.local/share/applications/steamos-pamac-appstream-handler.desktop

cat > "$HANDLER_DESKTOP" << 'EOF'
[Desktop Entry]
Type=Application
Name=SteamOS Pamac AppStream Handler
NoDisplay=true
MimeType=x-scheme-handler/appstream;
Exec=/home/deck/.local/bin/steamos-pamac-appstream-handler %U
InitialPreference=10
EOF

echo "=== Updated handler desktop with InitialPreference=10 ==="
cat "$HANDLER_DESKTOP"

echo ""
echo "=== Re-register as default ==="
xdg-mime default steamos-pamac-appstream-handler.desktop x-scheme-handler/appstream
xdg-mime query default x-scheme-handler/appstream

echo ""
echo "=== Refresh sycoca ==="
update-desktop-database ~/.local/share/applications 2>/dev/null
rm -f ~/.cache/ksycoca6* 2>/dev/null
kbuildsycoca6 2>&1 | tail -1

echo ""
echo "=== Verify Celluloid still installed ==="
ls ~/.local/share/applications/arch-pamac-*celluloid* 2>&1

echo ""
echo "=== DONE ==="
