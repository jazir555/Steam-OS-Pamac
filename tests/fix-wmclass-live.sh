#!/bin/bash
sed -i 's|StartupWMClass=pamac-manager|StartupWMClass=org.manjaro.pamac.manager|' /home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop
echo "Updated:"
grep StartupWMClass /home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop