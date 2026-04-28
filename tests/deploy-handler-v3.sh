#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Step 1: Deploy updated appstream handler ==="
cp /tmp/steamos-pamac-appstream-handler ~/.local/bin/steamos-pamac-appstream-handler
chmod +x ~/.local/bin/steamos-pamac-appstream-handler
echo "Handler deployed"

echo ""
echo "=== Step 2: Deploy updated export hook into container ==="
podman cp /tmp/distrobox-export-hook.sh arch-pamac:/usr/local/bin/distrobox-export-hook.sh
podman exec arch-pamac chmod +x /usr/local/bin/distrobox-export-hook.sh
echo "Export hook deployed"

echo ""
echo "=== Step 3: Remove kickeraction file ==="
rm -f ~/.local/share/plasma/kickeractions/steamos-pamac-uninstall.desktop
echo "Kickeraction file removed"
ls -la ~/.local/share/plasma/kickeractions/ 2>&1

echo ""
echo "=== Step 4: Ensure appstream handler desktop file exists ==="
HANDLER_DESKTOP=~/.local/share/applications/steamos-pamac-appstream-handler.desktop
if [[ ! -f "$HANDLER_DESKTOP" ]]; then
cat > "$HANDLER_DESKTOP" << 'EOF'
[Desktop Entry]
Type=Application
Name=SteamOS Pamac AppStream Handler
NoDisplay=true
MimeType=x-scheme-handler/appstream;
Exec=/home/deck/.local/bin/steamos-pamac-appstream-handler %U
EOF
echo "Created handler desktop file"
else
echo "Handler desktop file already exists"
fi

echo ""
echo "=== Step 5: Ensure appstream handler is registered ==="
xdg-mime default steamos-pamac-appstream-handler.desktop x-scheme-handler/appstream
xdg-mime query default x-scheme-handler/appstream

echo ""
echo "=== Step 6: Refresh caches ==="
update-desktop-database ~/.local/share/applications 2>/dev/null
rm -f ~/.cache/ksycoca6* 2>/dev/null
kbuildsycoca6 2>&1 | tail -1

echo ""
echo "=== Step 7: Verify Celluloid still present ==="
ls -la ~/.local/share/applications/arch-pamac-*celluloid* 2>&1

echo ""
echo "=== DONE - Ready for GUI test ==="
