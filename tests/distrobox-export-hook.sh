#!/bin/bash
set +e
if [[ "$(id -u)" == "0" ]]; then
    exec su -s /bin/bash deck -c "PATH=/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin XDG_DATA_DIRS=/usr/local/share:/usr/share XDG_DATA_HOME=/home/deck/.local/share /usr/local/bin/distrobox-export-hook.sh" 2>/dev/null || true
    exit 0
fi

APP_DIR="/home/deck/.local/share/applications"
STATE_DIR="/home/deck/.local/share/steamos-pamac/arch-pamac"

export HOME="/home/deck"
export PATH="/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin"
export XDG_DATA_DIRS="/usr/local/share:/usr/share"
export XDG_DATA_HOME="/home/deck/.local/share"

mkdir -p "$APP_DIR" "$STATE_DIR"

# Export desktop files from explicitly installed packages
explicit_pkgs=$(pacman -Qeq 2>/dev/null || true)
for pkg in $explicit_pkgs; do
    for f in $(pacman -Qql "$pkg" 2>/dev/null | grep '\.desktop$' || true); do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" .desktop)
        host_file="$APP_DIR/arch-pamac-$name.desktop"
        if [[ ! -f "$host_file" ]]; then
            distrobox-export --app "$name" 2>/dev/null || continue
            # Wait briefly for distrobox-export to finish
            sleep 0.5
            if [[ -f "$host_file" ]]; then
                # Annotate with uninstall action and markers
                if [[ "$name" == "org.manjaro.pamac.manager" ]]; then
                    sed -i 's|^Name=.*|Name=Pamac|' "$host_file"
                    sed -i '/^Name\[/d' "$host_file"
                    sed -i "s|^Exec=.*|Exec=/home/deck/.local/bin/pamac-manager-wrapper-host %U|" "$host_file"
                else
                    sed -i "s|^Exec=.*|Exec=distrobox-enter -n arch-pamac -- $pkg %f|" "$host_file"
                fi
                if ! grep -q '^Actions=uninstall;' "$host_file"; then
                    sed -i '/^StartupWMClass=/a Actions=uninstall;' "$host_file" 2>/dev/null || true
                    sed -i '/^StartupWMClass=/a X-SteamOS-Pamac-Managed=true' "$host_file" 2>/dev/null || true
                    sed -i '/^StartupWMClass=/a X-SteamOS-Pamac-Container=arch-pamac' "$host_file" 2>/dev/null || true
                    sed -i "/^StartupWMClass=/a X-SteamOS-Pamac-SourceDesktop=$name.desktop" "$host_file" 2>/dev/null || true
                    sed -i "/^StartupWMClass=/a X-SteamOS-Pamac-SourcePackage=$pkg" "$host_file" 2>/dev/null || true
                    cat >> "$host_file" << ACTION_EOF

[Desktop Action uninstall]
Name=Remove $pkg
Exec=bash -c 'podman exec -u 0 arch-pamac pacman -R --noconfirm $pkg 2>/dev/null && rm -f $host_file && touch $(dirname $host_file) && notify-send -i edit-delete "Uninstalled" "$pkg removed" 2>/dev/null'
Icon=edit-delete
ACTION_EOF
                fi
                chmod 644 "$host_file" 2>/dev/null
            fi
        fi
    done
done
