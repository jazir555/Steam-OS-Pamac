#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

APP_DIR="$HOME/.local/share/applications"
KICKERACTION_DIR="$HOME/.local/share/plasma/kickeractions"
BIN_DIR="$HOME/.local/bin"
MIMEAPPS="$HOME/.config/mimeapps.list"

echo "=== Deploying Bug #36 fix: NoDisplay appstream handler ==="
echo "This suppresses KDE's 'Uninstall or Manage Add-Ons...' menu item"
echo "KApplicationTrader::preferredService() skips NoDisplay=true services"

cat > "$APP_DIR/steamos-pamac-no-appstream-handler.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=AppStream Handler
NoDisplay=true
MimeType=x-scheme-handler/appstream;
Exec=/bin/false
EOF
chmod 644 "$APP_DIR/steamos-pamac-no-appstream-handler.desktop"
echo "Created NoDisplay appstream handler"

sed -i '/x-scheme-handler\/appstream/d' "$MIMEAPPS" 2>/dev/null
if ! grep -q '\[Default Applications\]' "$MIMEAPPS" 2>/dev/null; then
    echo "[Default Applications]" >> "$MIMEAPPS"
fi
sed -i "/\[Default Applications\]/a x-scheme-handler/appstream=steamos-pamac-no-appstream-handler.desktop" "$MIMEAPPS"
echo "Set as default appstream handler in mimeapps.list"

update-desktop-database "$APP_DIR" 2>/dev/null
echo "Updated desktop database"

echo ""
echo "=== Deploying Bug #35 fix: kickeraction handler ==="
echo "KDE reads kickeraction files on startup, no plasmashell restart needed"

cat > "$BIN_DIR/steamos-pamac-kickeraction-handler" << 'HANDLER_EOF'
#!/bin/bash
set +e

APP_DIR="$HOME/.local/share/applications"
STATE_DIR="$HOME/.local/share/steamos-pamac/arch-pamac"
UNINSTALL_HELPER="$HOME/.local/bin/steamos-pamac-uninstall"
LOG_FILE="$STATE_DIR/kickeraction-handler.log"

mkdir -p "$STATE_DIR"

log_msg() {
    echo "$(date): $*" >> "$LOG_FILE"
}

log_msg "=== kickeraction-handler invoked: $* ==="

DESKTOP_FILE_URL="$1"

if [[ -z "$DESKTOP_FILE_URL" ]]; then
    log_msg "Error: No desktop file URL argument provided"
    exit 1
fi

DESKTOP_PATH="${DESKTOP_FILE_URL#file://}"
DESKTOP_PATH="$(python3 -c "import urllib.parse, sys; print(urllib.parse.unquote(sys.argv[1]))" "$DESKTOP_PATH" 2>/dev/null || echo "$DESKTOP_PATH")"

if [[ ! -f "$DESKTOP_PATH" ]]; then
    DESKTOP_PATH="$APP_DIR/$(basename "$DESKTOP_PATH")"
fi

log_msg "Received desktop file: $DESKTOP_FILE_URL -> $DESKTOP_PATH"

if [[ ! -f "$DESKTOP_PATH" ]]; then
    log_msg "Error: Desktop file not found: $DESKTOP_PATH"
    exit 1
fi

if ! grep -q '^X-SteamOS-Pamac-Managed=true' "$DESKTOP_PATH" 2>/dev/null; then
    log_msg "App is not pamac-managed, ignoring: $DESKTOP_PATH"
    exit 0
fi

SOURCE_PKG=$(grep '^X-SteamOS-Pamac-SourcePackage=' "$DESKTOP_PATH" 2>/dev/null | cut -d= -f2)
if [[ -z "$SOURCE_PKG" ]]; then
    log_msg "Error: No X-SteamOS-Pamac-SourcePackage found in $DESKTOP_PATH"
    exit 1
fi

APP_NAME=$(grep '^Name=' "$DESKTOP_PATH" 2>/dev/null | head -1 | cut -d= -f2)
DESKTOP_BASENAME=$(basename "$DESKTOP_PATH")

log_msg "Uninstalling pamac-managed app: $APP_NAME (package: $SOURCE_PKG, desktop: $DESKTOP_BASENAME)"

UNINSTALL_LOG="$STATE_DIR/kickeraction-uninstall-$(date +%s).log"
log_msg "Spawning uninstall via systemd-run in separate scope"

systemd-run --user --scope -u "steamos-pamac-uninstall-$(date +%s)" \
    bash -c "'$UNINSTALL_HELPER' --desktop-file '$DESKTOP_BASENAME' > '$UNINSTALL_LOG' 2>&1; rc=\$?; echo \"Exit code: \$rc\" >> '$UNINSTALL_LOG'; if [ \$rc -eq 0 ]; then notify-send -i edit-delete 'Uninstalled' '$APP_NAME has been removed.' 2>/dev/null; else notify-send -i dialog-error 'Uninstall Failed' 'Could not remove $APP_NAME. See log for details.' 2>/dev/null; fi" &>/dev/null &

disown
exit 0
HANDLER_EOF
chmod +x "$BIN_DIR/steamos-pamac-kickeraction-handler"
echo "Deployed kickeraction handler script"

mkdir -p "$KICKERACTION_DIR"
cat > "$KICKERACTION_DIR/steamos-pamac-uninstall.desktop" << 'KICKER_EOF'
[Desktop Entry]
Type=Service
Name=SteamOS Pamac Uninstall Action
X-KDE-OnlyForAppIds=
Actions=uninstall;

[Desktop Action uninstall]
Name=Uninstall
Icon=edit-delete
Exec=/home/deck/.local/bin/steamos-pamac-kickeraction-handler %u
KICKER_EOF
chown deck:deck "$KICKERACTION_DIR/steamos-pamac-uninstall.desktop" 2>/dev/null
chmod 644 "$KICKERACTION_DIR/steamos-pamac-uninstall.desktop"
echo "Deployed kickeraction desktop file"

echo ""
echo "=== Verification ==="
echo "NoDisplay handler:"
cat "$APP_DIR/steamos-pamac-no-appstream-handler.desktop"
echo ""
echo "mimeapps.list:"
cat "$MIMEAPPS"
echo ""
echo "kickeraction desktop:"
cat "$KICKERACTION_DIR/steamos-pamac-uninstall.desktop"
echo ""
echo "=== Deployment complete ==="
echo "NOTE: KDE will read the kickeraction file on next login/reboot."
echo "No plasmashell restart was performed."
