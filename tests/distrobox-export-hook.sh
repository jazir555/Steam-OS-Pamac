#!/bin/bash
set +e
if [[ "$(id -u)" == "0" ]]; then
    exec su -s /bin/bash deck -c "PATH=/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin XDG_DATA_DIRS=/usr/local/share:/usr/share XDG_DATA_HOME=/home/deck/.local/share /usr/local/bin/distrobox-export-hook.sh" 2>/dev/null || true
    exit 0
fi

APP_DIR="/home/deck/.local/share/applications"
STATE_DIR="/home/deck/.local/share/steamos-pamac/arch-pamac"
EXPORT_LOG="$STATE_DIR/export-hook.log"

export HOME="/home/deck"
export PATH="/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin"
export XDG_DATA_DIRS="/usr/local/share:/usr/share"
export XDG_DATA_HOME="/home/deck/.local/share"

mkdir -p "$APP_DIR" "$STATE_DIR"

# Only export desktop files from explicitly installed packages
explicit_pkgs=$(pacman -Qeq 2>/dev/null || true)
for pkg in $explicit_pkgs; do
    for f in $(pacman -Qql "$pkg" 2>/dev/null | grep '\.desktop$' || true); do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" .desktop)
        # Skip if already exported
        if [[ -f "$APP_DIR/arch-pamac-$name.desktop" ]]; then
            continue
        fi
        distrobox-export --app "$name" 2>/dev/null || true
    done
done
