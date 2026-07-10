#!/bin/bash
set +e
echo "=== Orphaned Package Cleanup ==="
orphans=$(pacman -Qtdq 2>/dev/null)
if [[ -z "$orphans" ]]; then
    echo "No orphaned packages found."
    exit 0
fi
echo "The following packages are orphaned (no longer required by any installed package):"
echo "$orphans" | while read -r pkg; do
    echo "  - $pkg"
done
echo ""
read -rp "Remove these packages? [y/N] " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    pacman -Rns --noconfirm $orphans 2>&1
    echo "Orphaned packages removed."
else
    echo "Skipped."
fi
