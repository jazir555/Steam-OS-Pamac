#!/bin/bash
export CONTAINER_NAME="arch-pamac"
desktop_dir="$HOME/.local/share/applications"
exported_desktop="$desktop_dir/${CONTAINER_NAME}-org.manjaro.pamac.manager.desktop"

rm -f "$exported_desktop"

cat > "$exported_desktop" << DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=Add/Remove Software (on ${CONTAINER_NAME})
Comment=Manage packages inside the ${CONTAINER_NAME} distrobox
Exec=distrobox enter ${CONTAINER_NAME} -- pamac-manager-wrapper %U
Icon=system-software-install
Terminal=false
Categories=System;PackageManager;Settings;
Keywords=package;manager;software;arch;aur;
StartupNotify=true
StartupWMClass=pamac-manager
NoDisplay=false
DBusActivatable=false
X-SteamOS-Pamac-Managed=true
X-SteamOS-Pamac-Container=${CONTAINER_NAME}
X-SteamOS-Pamac-SourceApp=pamac-manager
X-SteamOS-Pamac-SourceDesktop=org.manjaro.pamac.manager.desktop
X-SteamOS-Pamac-SourcePackage=pamac-aur
DESKTOP_EOF
chmod +x "$exported_desktop"

echo "Desktop file written: $exported_desktop"
grep -E '^(Exec|X-SteamOS|DBusActivatable)' "$exported_desktop"

update-desktop-database "$desktop_dir" 2>/dev/null || true
echo "Done."
