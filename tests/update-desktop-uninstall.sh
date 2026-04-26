#!/bin/bash
# Update the pamac desktop file on the Deck host with uninstall action
DESKTOP_FILE="/home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop"

cat > "$DESKTOP_FILE" << 'EOF'
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
EOF

chmod +x "$DESKTOP_FILE"
echo "Desktop file updated with uninstall action"

update-desktop-database /home/deck/.local/share/applications 2>/dev/null || true
echo "Desktop database updated"
