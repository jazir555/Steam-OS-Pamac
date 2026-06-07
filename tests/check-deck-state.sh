#!/bin/bash
export HOME=/home/deck

echo "=== Host-side wrapper ==="
head -30 /home/deck/.local/bin/pamac-manager-wrapper-host 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== Desktop file Exec ==="
grep '^Exec=' /home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop

echo ""
echo "=== Desktop file Startup ==="
grep -E '^(Startup|NoDisplay|Name=)' /home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop

echo ""
echo "DONE"