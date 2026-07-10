#!/bin/bash
set +e

# distrobox-export refuses to run as root. Pacman hooks always run as root,
# so skip export here — desktop file exports are handled by the installer
# and host wrapper instead.
if [[ "$(id -u)" == "0" ]]; then
    exit 0
fi

APP_DIR="/home/deck/.local/share/applications"
STATE_DIR="/home/deck/.local/share/steamos-pamac/arch-pamac"
STATE_FILE="$STATE_DIR/exported-apps.list"
EXPORT_LOG="$STATE_DIR/export-hook.log"
EXPLICIT_FILE="$(mktemp)"
NEW_STATE_FILE="$(mktemp)"
HASH_FILE="$STATE_DIR/.last-explicit-hash"
echo "$(date): Hook triggered" > "$EXPORT_LOG"
mkdir -p "$APP_DIR" "$STATE_DIR"
trap 'rm -f "$EXPLICIT_FILE" "$NEW_STATE_FILE"' EXIT

pacman -Qeq > "$EXPLICIT_FILE" 2>/dev/null || true

CURRENT_HASH="$(md5sum "$EXPLICIT_FILE" 2>/dev/null | awk '{print $1}')"
if [[ -d /usr/share/applications ]]; then
    DESKTOP_SIG="$(find /usr/share/applications -maxdepth 1 -type f -name '*.desktop' \
        -printf '%p %s %T@\n' 2>/dev/null | sort | md5sum | awk '{print $1}')"
    CURRENT_HASH="${CURRENT_HASH}:${DESKTOP_SIG}"
fi
if [[ -f "$HASH_FILE" ]]; then
    LAST_HASH="$(cat "$HASH_FILE" 2>/dev/null || echo "")"
    if [[ "$CURRENT_HASH" == "$LAST_HASH" ]]; then
        echo "$(date): Package list and desktop files unchanged. Skipping." >> "$EXPORT_LOG"
        exit 0
    fi
fi
echo "$CURRENT_HASH" > "$HASH_FILE" 2>/dev/null || true
echo "$(date): Package list or desktop files changed. Running export." >> "$EXPORT_LOG"

for f in /usr/share/applications/*.desktop; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f" .desktop)
    distrobox-export --app "$name" 2>/dev/null || true
done
