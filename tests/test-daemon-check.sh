#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

CONTAINER_NAME="arch-pamac"

pamac_cli() {
    podman exec -u 0 "$CONTAINER_NAME" pamac "$@" </dev/null 2>/dev/null || true
}

echo "Testing pamac_cli --version with head -1..."
pamac_ver=$(pamac_cli --version | head -1 || true)
echo "pamac_ver=[$pamac_ver]"
echo "Length: ${#pamac_ver}"

if [[ -n "$pamac_ver" ]]; then
    echo "Daemon OK ($pamac_ver)"
else
    echo "Daemon FAILED - empty version"
fi
