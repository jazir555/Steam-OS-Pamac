#!/bin/bash
set +e

APP_DIR="/home/deck/.local/share/applications"
STATE_DIR="/home/deck/.local/share/steamos-pamac/arch-pamac"
STATE_FILE="$STATE_DIR/exported-apps.list"
EXPORT_LOG="$STATE_DIR/export-hook.log"
EXPLICIT_FILE="$(mktemp)"
NEW_STATE_FILE="$(mktemp)"
echo "$(date): Hook triggered" > "$EXPORT_LOG"
mkdir -p "$APP_DIR" "$STATE_DIR"
trap 'rm -f "$EXPLICIT_FILE" "$NEW_STATE_FILE"' EXIT

pacman -Qeq > "$EXPLICIT_FILE" 2>/dev/null || true

should_export_desktop() {
local desktop_file="$1"
local app_name="$2"
local owner_pkg="$3"

[[ -f "$desktop_file" ]] || return 1
grep -qi '^NoDisplay=true' "$desktop_file" && return 1
grep -qi '^Hidden=true' "$desktop_file" && return 1
grep -qi '^TerminalOnly=true' "$desktop_file" && return 1
if grep -qi '^Type=' "$desktop_file" && ! grep -qi '^Type=Application$' "$desktop_file"; then
return 1
fi

case "$app_name" in
"arch-pamac"|distrobox*)
return 1
;;
pamac-installer|pamac-tray)
return 1
;;
esac

[[ -n "$owner_pkg" ]] || return 1
grep -Fxq "$owner_pkg" "$EXPLICIT_FILE"
}

annotate_desktop() {
local desktop_file="$1"
local app_name="$2"
local export_name="$3"
local owner_pkg="$4"

[[ -f "$desktop_file" ]] || return 1

if [[ "$app_name" == "org.manjaro.pamac.manager" ]]; then
cat > "$desktop_file" << 'PAMAC_DESKTOP'
[Desktop Entry]
Type=Application
Name=Add/Remove Software (on arch-pamac)
Comment=Manage packages inside the arch-pamac distrobox
Exec=distrobox enter arch-pamac -- pamac-manager-wrapper %U
Icon=system-software-install
Terminal=false
Categories=System;PackageManager;Settings;
Keywords=package;manager;software;arch;aur;
StartupNotify=true
StartupWMClass=pamac-manager
NoDisplay=false
DBusActivatable=false
X-SteamOS-Pamac-Managed=true
X-SteamOS-Pamac-Container=arch-pamac
X-SteamOS-Pamac-SourceApp=pamac-manager
X-SteamOS-Pamac-SourceDesktop=org.manjaro.pamac.manager.desktop
X-SteamOS-Pamac-SourcePackage=pamac-aur
PAMAC_DESKTOP
chmod +x "$desktop_file"
return 0
fi

sed -i \
-e '/^X-SteamOS-Pamac-Managed=/d' \
-e '/^X-SteamOS-Pamac-Container=/d' \
-e '/^X-SteamOS-Pamac-SourceApp=/d' \
-e '/^X-SteamOS-Pamac-SourceDesktop=/d' \
-e '/^X-SteamOS-Pamac-SourcePackage=/d' \
"$desktop_file"
printf '\nX-SteamOS-Pamac-Managed=true\nX-SteamOS-Pamac-Container=%s\nX-SteamOS-Pamac-SourceApp=%s\nX-SteamOS-Pamac-SourceDesktop=%s.desktop\nX-SteamOS-Pamac-SourcePackage=%s\n' \
"arch-pamac" "$export_name" "$app_name" "$owner_pkg" >> "$desktop_file"
}

run_distrobox_export() {
local app_name="$1"

local xdg_data_dirs="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
local xdg_data_home="${XDG_DATA_HOME:-/home/deck/.local/share}"
local user_path="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

if [[ "$(id -u)" -eq 0 ]]; then
sudo -Hu "deck" \
env HOME="/home/deck" \
XDG_DATA_DIRS="$xdg_data_dirs" \
XDG_DATA_HOME="$xdg_data_home" \
PATH="$user_path" \
distrobox-export --app "$app_name"
else
export HOME="/home/deck"
export XDG_DATA_DIRS="$xdg_data_dirs"
export XDG_DATA_HOME="$xdg_data_home"
distrobox-export --app "$app_name"
fi
}

if command -v distrobox-export >/dev/null 2>&1; then
exported=0
for desktop in /usr/share/applications/*.desktop; do
[[ -f "$desktop" ]] || continue
app_name="$(basename "$desktop" .desktop)"
export_name="$app_name"
[[ "$app_name" == "org.manjaro.pamac.manager" ]] && export_name="pamac-manager"
owner_pkg="$(pacman -Qoq "$desktop" 2>/dev/null || true)"
should_export_desktop "$desktop" "$app_name" "$owner_pkg" || continue

if run_distrobox_export "$export_name" >/dev/null 2>&1; then
host_desktop=""
for candidate in "$APP_DIR/arch-pamac-${app_name}.desktop" "$APP_DIR/arch-pamac-${export_name}.desktop"; do
if [[ -f "$candidate" ]]; then
host_desktop="$candidate"
break
fi
done
if [[ -z "$host_desktop" ]]; then
host_desktop="$(find "$APP_DIR" -maxdepth 1 -name "arch-pamac-*.desktop" -newer "$EXPLICIT_FILE" -print -quit 2>/dev/null)"
fi
if [[ -n "$host_desktop" && -f "$host_desktop" ]]; then
annotate_desktop "$host_desktop" "$app_name" "$export_name" "$owner_pkg" || true
printf '%s\n' "$host_desktop" >> "$NEW_STATE_FILE"
fi
exported=$((exported + 1))
fi
done
echo "$(date): Exported $exported apps" >> "$EXPORT_LOG"
fi

rm -f "$APP_DIR/arch-pamac.desktop" 2>/dev/null || true

if [[ -f "$STATE_FILE" ]]; then
while IFS= read -r old_export; do
[[ -n "$old_export" ]] || continue
if [[ -f "$old_export" ]]; then
printf '%s\n' "$old_export" >> "$NEW_STATE_FILE"
fi
done < "$STATE_FILE"
fi

while IFS= read -r existing_export; do
[[ -n "$existing_export" ]] || continue
if grep -q '^X-SteamOS-Pamac-SourceApp=pamac-manager$' "$existing_export" 2>/dev/null; then
echo "Preserving pamac-manager export: $existing_export" >> "$EXPORT_LOG"
printf '%s\n' "$existing_export" >> "$NEW_STATE_FILE"
continue
fi
if ! grep -Fxq "$existing_export" "$NEW_STATE_FILE" 2>/dev/null; then
echo "Removing stale container export: $existing_export" >> "$EXPORT_LOG"
rm -f "$existing_export"
fi
done < <(find "$APP_DIR" -maxdepth 1 -type f -name "arch-pamac-*.desktop" ! -name "arch-pamac.desktop" 2>/dev/null | sort)

sort -u "$NEW_STATE_FILE" > "$STATE_FILE"

if command -v update-desktop-database >/dev/null 2>&1 && [[ -d "$APP_DIR" ]]; then
update-desktop-database "$APP_DIR" 2>/dev/null || true
fi
