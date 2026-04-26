#!/bin/bash
echo "=== All exported desktop files ==="
for f in /home/deck/.local/share/applications/arch-pamac-*.desktop; do
  echo "---"
  basename "$f"
  grep -E 'Name=|X-SteamOS-Pamac-Managed|X-SteamOS-Pamac-SourcePackage|Actions=' "$f" 2>/dev/null | head -5
done
echo ""
echo "=== Container package check ==="
podman exec -i -u 0 arch-pamac bash -c 'for pkg in librewolf-bin heroic-games-launcher-bin fd; do pacman -Q "$pkg" 2>/dev/null && echo "OK: $pkg" || echo "MISSING: $pkg"; done'
echo ""
echo "=== Critical helpers ==="
podman exec -i -u 0 arch-pamac bash -c 'test -x /usr/local/sbin/systemd-run && echo "systemd-run: OK" || echo "systemd-run: MISSING"'
podman exec -i -u 0 arch-pamac bash -c 'test -f /usr/share/dbus-1/system.d/org.manjaro.pamac.daemon.conf && echo "dbus-daemon.conf: OK" || echo "dbus-daemon.conf: MISSING"'
podman exec -i -u 0 arch-pamac bash -c 'test -x /usr/local/bin/pamac-session-bootstrap.sh && echo "bootstrap: OK" || echo "bootstrap: MISSING"'
