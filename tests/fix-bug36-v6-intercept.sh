#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

APP_DIR="$HOME/.local/share/applications"
BIN_DIR="$HOME/.local/bin"
MIMEAPPS="$HOME/.config/mimeapps.list"

echo "=== Bug #36 Fix v6: Intercept appstream:// URL handler ==="
echo "Strategy: Register a user-level appstream URL handler that:"
echo "1. If the app is pamac-managed, runs our uninstall helper"
echo "2. Otherwise, passes the URL to Discover (preserving normal behavior)"
echo "This REPLACES the NoDisplay approach and the Hidden=true approach."

echo ""
echo "=== Step 1: Remove the Hidden=true override ==="
rm -f "$APP_DIR/org.kde.discover.urlhandler.desktop"

echo "=== Step 2: Create the appstream intercept handler ==="
cat > "$BIN_DIR/steamos-pamac-appstream-handler" << 'HANDLER_EOF'
#!/bin/bash
set +e

APP_DIR="$HOME/.local/share/applications"
STATE_DIR="$HOME/.local/share/steamos-pamac/arch-pamac"
UNINSTALL_HELPER="$HOME/.local/bin/steamos-pamac-uninstall"
LOG_FILE="$STATE_DIR/appstream-handler.log"

mkdir -p "$STATE_DIR"

log_msg() {
    echo "$(date): $*" >> "$LOG_FILE"
}

log_msg "=== appstream-handler invoked: $* ==="

APPSTREAM_URL="$1"

if [[ -z "$APPSTREAM_URL" ]]; then
    log_msg "Error: No URL argument provided"
    # Fall through to Discover
    exec plasma-discover "$@"
fi

# Extract component ID from appstream://<component-id>
COMPONENT_ID="${APPSTREAM_URL#appstream://}"

if [[ -z "$COMPONENT_ID" ]]; then
    log_msg "Error: Empty component ID from URL: $APPSTREAM_URL"
    exec plasma-discover "$@"
fi

log_msg "Component ID: $COMPONENT_ID"

# Try to find a matching pamac-managed desktop file
# The component ID from AppStream is like "io.github.celluloid_player.Celluloid.desktop"
# Our desktop files are prefixed with "arch-pamac-"
FOUND_DESKTOP=""

for desktop_file in "$APP_DIR"/arch-pamac-*.desktop; do
    [[ -f "$desktop_file" ]] || continue
    
    # Get the SourceDesktop (original desktop file name)
    SOURCE_DESKTOP=$(grep '^X-SteamOS-Pamac-SourceDesktop=' "$desktop_file" 2>/dev/null | cut -d= -f2)
    
    if [[ "$SOURCE_DESKTOP" == "$COMPONENT_ID" ]]; then
        FOUND_DESKTOP="$desktop_file"
        log_msg "Found matching pamac-managed app: $desktop_file (source: $SOURCE_DESKTOP)"
        break
    fi
    
    # Also try matching by the desktop entry name derived from filename
    BASENAME=$(basename "$desktop_file" .desktop)
    ENTRY_NAME="${BASENAME#arch-pamac-}"
    if [[ "$ENTRY_NAME" == "${COMPONENT_ID%.desktop}" ]]; then
        FOUND_DESKTOP="$desktop_file"
        log_msg "Found matching pamac-managed app by entry name: $desktop_file"
        break
    fi
done

if [[ -n "$FOUND_DESKTOP" ]]; then
    log_msg "Routing to pamac uninstall handler for: $(basename "$FOUND_DESKTOP")"
    
    SOURCE_PKG=$(grep '^X-SteamOS-Pamac-SourcePackage=' "$FOUND_DESKTOP" 2>/dev/null | cut -d= -f2)
    APP_NAME=$(grep '^Name=' "$FOUND_DESKTOP" 2>/dev/null | head -1 | cut -d= -f2)
    DESKTOP_BASENAME=$(basename "$FOUND_DESKTOP")
    
    UNINSTALL_LOG="$STATE_DIR/kickeraction-uninstall-$(date +%s).log"
    
    # Use kdialog for confirmation
    if command -v kdialog >/dev/null 2>&1; then
        CONFIRM=$(kdialog --yesno "Remove $APP_NAME? This was installed via Pamac (AUR)." --title "Uninstall" 2>/dev/null)
        if [[ $? -ne 0 ]]; then
            log_msg "User cancelled uninstall"
            exit 0
        fi
    fi
    
    systemd-run --user --scope -u "steamos-pamac-uninstall-$(date +%s)" \
        bash -c "'$UNINSTALL_HELPER' --desktop-file '$DESKTOP_BASENAME' > '$UNINSTALL_LOG' 2>&1; rc=\$?; echo \"Exit code: \$rc\" >> '$UNINSTALL_LOG'; if [ \$rc -eq 0 ]; then notify-send -i edit-delete 'Uninstalled' '$APP_NAME has been removed.' 2>/dev/null; else notify-send -i dialog-error 'Uninstall Failed' 'Could not remove $APP_NAME. See log for details.' 2>/dev/null; fi" &>/dev/null &
    
    disown
    exit 0
else
    log_msg "No pamac-managed app found for component: $COMPONENT_ID, passing to Discover"
    exec plasma-discover "$@"
fi
HANDLER_EOF
chmod +x "$BIN_DIR/steamos-pamac-appstream-handler"
echo "Created appstream intercept handler"

echo "=== Step 3: Create the handler desktop file ==="
cat > "$APP_DIR/steamos-pamac-appstream-handler.desktop" << 'DESKTOP_EOF'
[Desktop Entry]
Type=Application
Name=SteamOS Pamac AppStream Handler
NoDisplay=true
MimeType=x-scheme-handler/appstream;
Exec=/home/deck/.local/bin/steamos-pamac-appstream-handler %U
DESKTOP_EOF
chmod 644 "$APP_DIR/steamos-pamac-appstream-handler.desktop"
echo "Created handler desktop file"

echo "=== Step 4: Register as default appstream handler in mimeapps.list ==="
sed -i '/x-scheme-handler\/appstream/d' "$MIMEAPPS"
if ! grep -q '\[Default Applications\]' "$MIMEAPPS" 2>/dev/null; then
    echo "[Default Applications]" >> "$MIMEAPPS"
fi
sed -i "/\[Default Applications\]/a x-scheme-handler/appstream=steamos-pamac-appstream-handler.desktop" "$MIMEAPPS"
echo "Registered as default appstream handler"

echo "=== Step 5: Rebuild caches ==="
update-desktop-database "$APP_DIR" 2>/dev/null
rm -f ~/.cache/ksycoca6* 2>/dev/null
kbuildsycoca6 2>&1 | tail -2

echo ""
echo "=== Verification ==="
echo "xdg-mime default:"
xdg-mime query default x-scheme-handler/appstream 2>&1

echo ""
echo "mimeapps.list:"
cat "$MIMEAPPS"

echo ""
echo "Handler desktop:"
cat "$APP_DIR/steamos-pamac-appstream-handler.desktop"

echo ""
echo "=== Done ==="
echo "Now both 'Uninstall or Manage Add-Ons...' and 'Uninstall' will work."
echo "For pamac apps, the appstream handler will intercept and use our uninstaller."
echo "For non-pamac apps, it falls through to Discover."
