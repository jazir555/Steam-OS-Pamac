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

get_exec_binary() {
  local desktop_file="$1"
  grep '^Exec=' "$desktop_file" 2>/dev/null | head -1 | sed 's/^Exec=//' | sed 's/ .*//' | sed 's|^.*/||'
}

_fix_desktop_permissions() {
  local desktop_file="$1"
  if [[ "$(id -u)" -eq 0 ]]; then
    chown 1000:1000 "$desktop_file" 2>/dev/null || true
  fi
  chmod 644 "$desktop_file" 2>/dev/null || true
}

annotate_desktop() {
  local desktop_file="$1"
  local app_name="$2"
  local export_name="$3"
  local owner_pkg="$4"

  [[ -f "$desktop_file" ]] || return 1

  _fix_desktop_permissions "$desktop_file"

  if [[ "$app_name" == "org.manjaro.pamac.manager" ]]; then
    cat > "$desktop_file" << PAMAC_DESKTOP
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
Actions=uninstall;
X-SteamOS-Pamac-Managed=true
X-SteamOS-Pamac-Container=arch-pamac
X-SteamOS-Pamac-SourceApp=pamac-manager
X-SteamOS-Pamac-SourceDesktop=org.manjaro.pamac.manager.desktop
X-SteamOS-Pamac-SourcePackage=pamac-aur

[Desktop Action uninstall]
Name=Uninstall Packages
Exec=/home/deck/.local/bin/steamos-pamac-uninstall --desktop-file arch-pamac-org.manjaro.pamac.manager.desktop
Icon=edit-delete
PAMAC_DESKTOP
    _fix_desktop_permissions "$desktop_file"
    return 0
  fi

 local tmp_file
 tmp_file="$(mktemp)"
 local existing_actions=""
 local in_action=false
 {
 while IFS= read -r line || [[ -n "$line" ]]; do
 case "$line" in
 'X-SteamOS-Pamac-Managed='*) continue ;;
 'X-SteamOS-Pamac-Container='*) continue ;;
 'X-SteamOS-Pamac-SourceApp='*) continue ;;
 'X-SteamOS-Pamac-SourceDesktop='*) continue ;;
 'X-SteamOS-Pamac-SourcePackage='*) continue ;;
 'Actions='*)
 existing_actions="${line#Actions=}"
 continue
 ;;
 '[Desktop Action uninstall]')
 in_action=true
 continue
 ;;
 esac
 if $in_action; then
 case "$line" in
 'Name=Uninstall'|'Name=Uninstall '*|'Exec='*steamos-pamac-uninstall*|'Icon=edit-delete'|'['*)
 if [[ "$line" == '['* ]]; then
 in_action=false
 printf '%s\n' "$line"
 fi
 continue
 ;;
 esac
 fi
 if [[ "$line" == '['Desktop\ Action* ]]; then
 in_action=true
 fi
 if $in_action; then
 case "$line" in
 'StartupWMClass='*) continue ;;
 esac
 fi
 printf '%s\n' "$line"
 done < "$desktop_file"
 } > "$tmp_file"
 mv "$tmp_file" "$desktop_file"

	local combined_actions=""
	if [[ -n "$existing_actions" ]]; then
		local stripped="${existing_actions%%;}"
		combined_actions="${stripped};uninstall;"
	else
		combined_actions="uninstall;"
	fi

	desktop_basename="$(basename "$desktop_file")"

	# Insert Actions= key into [Desktop Entry] section (before first [Desktop Action...])
	# and append X-SteamOS markers + [Desktop Action uninstall] at the end
	local actions_inserted=false
	tmp_file="$(mktemp)"
	{
		while IFS= read -r line || [[ -n "$line" ]]; do
			if ! $actions_inserted && [[ "$line" == '[Desktop Action'* ]]; then
				printf 'Actions=%s\n' "$combined_actions"
				printf 'X-SteamOS-Pamac-Managed=true\n'
				printf 'X-SteamOS-Pamac-Container=arch-pamac\n'
				printf 'X-SteamOS-Pamac-SourceApp=%s\n' "$export_name"
				printf 'X-SteamOS-Pamac-SourceDesktop=%s.desktop\n' "$app_name"
				printf 'X-SteamOS-Pamac-SourcePackage=%s\n' "$owner_pkg"
				printf '\n'
				actions_inserted=true
			fi
			printf '%s\n' "$line"
		done < "$desktop_file"

		if ! $actions_inserted; then
			printf 'Actions=%s\n' "$combined_actions"
			printf 'X-SteamOS-Pamac-Managed=true\n'
			printf 'X-SteamOS-Pamac-Container=arch-pamac\n'
			printf 'X-SteamOS-Pamac-SourceApp=%s\n' "$export_name"
			printf 'X-SteamOS-Pamac-SourceDesktop=%s.desktop\n' "$app_name"
			printf 'X-SteamOS-Pamac-SourcePackage=%s\n' "$owner_pkg"
		fi

		printf '\n[Desktop Action uninstall]\nName=Uninstall\nExec=/home/deck/.local/bin/steamos-pamac-uninstall --desktop-file %s\nIcon=edit-delete\n' "$desktop_basename"
	} > "$tmp_file"
	mv "$tmp_file" "$desktop_file"
  _fix_desktop_permissions "$desktop_file"
}

run_distrobox_export() {
  local app_name="$1"
  local fallback_name="${2:-}"

  local xdg_data_dirs="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  local xdg_data_home="${XDG_DATA_HOME:-/home/deck/.local/share}"
  local user_path="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

  _do_export() {
    local name="$1"
    if [[ "$(id -u)" -eq 0 ]]; then
      sudo -Hu "deck" \
        env HOME="/home/deck" \
        XDG_DATA_DIRS="$xdg_data_dirs" \
        XDG_DATA_HOME="$xdg_data_home" \
        PATH="$user_path" \
        distrobox-export --app "$name" 2>/dev/null
    else
      export HOME="/home/deck"
      export XDG_DATA_DIRS="$xdg_data_dirs"
      export XDG_DATA_HOME="$xdg_data_home"
      distrobox-export --app "$name" 2>/dev/null
    fi
  }

  if _do_export "$app_name"; then
    return 0
  fi

  if [[ -n "$fallback_name" && "$fallback_name" != "$app_name" ]]; then
    echo "distrobox-export --app $app_name failed, trying fallback: $fallback_name" >> "$EXPORT_LOG" 2>/dev/null
    if _do_export "$fallback_name"; then
      return 0
    fi
  fi

  return 1
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

    exec_binary="$(get_exec_binary "$desktop")"

  if run_distrobox_export "$export_name" "$exec_binary"; then
    host_desktop=""
    for candidate in "$APP_DIR/arch-pamac-${app_name}.desktop" "$APP_DIR/arch-pamac-${export_name}.desktop" "$APP_DIR/arch-pamac-${exec_binary}.desktop"; do
      if [[ -f "$candidate" ]]; then
        _fix_desktop_permissions "$candidate"
        host_desktop="$candidate"
        break
      fi
    done
    if [[ -z "$host_desktop" ]]; then
      host_desktop="$(find "$APP_DIR" -maxdepth 1 -name "arch-pamac-*.desktop" -newer "$EXPLICIT_FILE" -print -quit 2>/dev/null)"
      if [[ -n "$host_desktop" ]]; then
        _fix_desktop_permissions "$host_desktop"
      fi
    fi
    if [[ -n "$host_desktop" && -f "$host_desktop" ]]; then
      annotate_desktop "$host_desktop" "$app_name" "$export_name" "$owner_pkg" || true
        printf '%s\n' "$host_desktop" >> "$NEW_STATE_FILE"
      fi
      exported=$((exported + 1))
    else
      echo "Failed to export $app_name (tried: $export_name, $exec_binary)" >> "$EXPORT_LOG"
    fi
  done
  echo "$(date): Exported $exported apps" >> "$EXPORT_LOG"
fi

rm -f "$APP_DIR/arch-pamac.desktop" 2>/dev/null || true

for f in "$APP_DIR"/arch-pamac-*.desktop; do
  [[ -f "$f" ]] || continue
  _fix_desktop_permissions "$f"
done

if [[ -f "$STATE_FILE" ]]; then
  while IFS= read -r old_export; do
    [[ -n "$old_export" ]] || continue
    if [[ ! -f "$old_export" ]]; then
      echo "Removing state entry for missing file: $old_export" >> "$EXPORT_LOG"
      continue
    fi
    local_source_pkg="$(grep '^X-SteamOS-Pamac-SourcePackage=' "$old_export" 2>/dev/null | cut -d= -f2-)"
    if [[ -n "$local_source_pkg" ]]; then
      if ! pacman -Q "$local_source_pkg" >/dev/null 2>&1; then
        echo "Removing stale export (package $local_source_pkg uninstalled): $old_export" >> "$EXPORT_LOG"
        rm -f "$old_export"
        continue
      fi
      if ! grep -Fxq "$local_source_pkg" "$EXPLICIT_FILE" 2>/dev/null; then
        echo "Removing dependency export (package $local_source_pkg not explicitly installed): $old_export" >> "$EXPORT_LOG"
        rm -f "$old_export"
        continue
      fi
    fi
    printf '%s\n' "$old_export" >> "$NEW_STATE_FILE"
  done < "$STATE_FILE"
fi

while IFS= read -r existing_export; do
  [[ -n "$existing_export" ]] || continue
  if grep -q '^X-SteamOS-Pamac-SourceApp=pamac-manager$' "$existing_export" 2>/dev/null; then
    echo "Preserving pamac-manager export: $existing_export" >> "$EXPORT_LOG"
    printf '%s\n' "$existing_export" >> "$NEW_STATE_FILE"
    continue
  fi
  existing_source_pkg="$(grep '^X-SteamOS-Pamac-SourcePackage=' "$existing_export" 2>/dev/null | cut -d= -f2-)"
  if [[ -n "$existing_source_pkg" ]]; then
    if ! pacman -Q "$existing_source_pkg" >/dev/null 2>&1; then
      echo "Removing orphaned export (package $existing_source_pkg uninstalled): $existing_export" >> "$EXPORT_LOG"
      rm -f "$existing_export"
      continue
    fi
    if ! grep -Fxq "$existing_source_pkg" "$EXPLICIT_FILE" 2>/dev/null; then
      echo "Removing dependency export (package $existing_source_pkg not explicitly installed): $existing_export" >> "$EXPORT_LOG"
      rm -f "$existing_export"
      continue
    fi
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

KICKERACTION_DIR="/home/deck/.local/share/plasma/kickeractions"
rm -f "$KICKERACTION_DIR/steamos-pamac-uninstall.desktop" 2>/dev/null
echo "$(date): Removed kickeraction file (using appstream intercept instead)" >> "$EXPORT_LOG"

APPSTREAM_HANDLER_DIR="/home/deck/.local/share/applications"
APPSTREAM_HANDLER_DESKTOP="$APPSTREAM_HANDLER_DIR/steamos-pamac-appstream-handler.desktop"
APPSTREAM_HANDLER_BIN="/home/deck/.local/bin/steamos-pamac-appstream-handler"

if [[ ! -f "$APPSTREAM_HANDLER_DESKTOP" ]]; then
mkdir -p "$APPSTREAM_HANDLER_DIR"
cat > "$APPSTREAM_HANDLER_DESKTOP" << HANDLER_EOF
[Desktop Entry]
Type=Application
Name=SteamOS Pamac AppStream Handler
NoDisplay=true
MimeType=x-scheme-handler/appstream;
Exec=$APPSTREAM_HANDLER_BIN %U
HANDLER_EOF
echo "$(date): Deployed appstream handler desktop file" >> "$EXPORT_LOG"
fi

if [[ -f "$APPSTREAM_HANDLER_BIN" ]]; then
chmod +x "$APPSTREAM_HANDLER_BIN" 2>/dev/null
fi
