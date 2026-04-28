#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

MIMEAPPS="$HOME/.config/mimeapps.list"

# Fix corrupted mimeapps.list - remove the broken ppstream/d lines
cat > "$MIMEAPPS" << 'EOF'
[Default Applications]
x-scheme-handler/discord-712465656758665259=discord-712465656758665259.desktop
x-scheme-handler/hydralauncher=hydralauncher.desktop
[Added Associations]
x-scheme-handler/hydralauncher=hydralauncher.desktop;
EOF

echo "Fixed mimeapps.list:"
cat "$MIMEAPPS"
