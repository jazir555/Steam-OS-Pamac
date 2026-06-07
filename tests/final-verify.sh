#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Desktop file ==="
grep -E '^(Name|NoDisplay|Categories)=' /home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop

echo ""
echo "=== XDG drop-in ==="
cat /home/deck/.config/systemd/user/plasma-plasmashell.service.d/override-xdg-data-dirs.conf

echo ""
echo "=== Pamac CLI version ==="
podman exec arch-pamac pamac --version 2>&1 | head -1

echo ""
echo "=== Checking plasmashell XDG env ==="
ps -o pid= -C plasmashell | head -1 | while read p; do
  tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep XDG_DATA_DIRS
done

echo ""
echo "DONE"