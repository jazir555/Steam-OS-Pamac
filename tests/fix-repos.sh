#!/bin/bash
set -euo pipefail
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

_import_key_multi_server() {
    local key_id="$1"
    local keyservers=("hkps://keyserver.ubuntu.com" "hkps://keys.openpgp.org" "hkps://pgp.mit.edu")
    for server in "${keyservers[@]}"; do
        if timeout 30 pacman-key --recv-key --keyserver "$server" "$key_id" 2>/dev/null; then
            timeout 30 pacman-key --lsign-key "$key_id" 2>/dev/null && return 0
        fi
    done
    echo "Warning: Could not import key $key_id from any keyserver."
    return 1
}

echo "=== Fixing chaotic-mirrorlist ==="
podman exec arch-pamac bash -c 'cat > /etc/pacman.d/chaotic-mirrorlist' << 'MIRROREOF'
## Chaotic-AUR mirrorlist
Server = https://cdn-mirror.chaotic.cx/chaotic-aur/$arch
Server = https://geo-mirror.chaotic.cx/chaotic-aur/$arch
MIRROREOF
echo "chaotic-mirrorlist fixed"

echo "=== Fixing archlinuxcn keyring ==="
podman exec arch-pamac bash -c '
  _import_key_multi_server() {
      local key_id="$1"
      local keyservers=("hkps://keyserver.ubuntu.com" "hkps://keys.openpgp.org" "hkps://pgp.mit.edu")
      for server in "${keyservers[@]}"; do
          if timeout 30 pacman-key --recv-key --keyserver "$server" "$key_id" 2>/dev/null; then
              timeout 30 pacman-key --lsign-key "$key_id" 2>/dev/null && return 0
          fi
      done
      echo "Warning: Could not import key $key_id from any keyserver."
      return 1
  }
  _import_key_multi_server 11C2E2D1D43CF75C || true
'
echo "archlinuxcn key fixed"

echo "=== Fixing endeavouros keyring ==="
podman exec arch-pamac bash -c '
  _import_key_multi_server() {
      local key_id="$1"
      local keyservers=("hkps://keyserver.ubuntu.com" "hkps://keys.openpgp.org" "hkps://pgp.mit.edu")
      for server in "${keyservers[@]}"; do
          if timeout 30 pacman-key --recv-key --keyserver "$server" "$key_id" 2>/dev/null; then
              timeout 30 pacman-key --lsign-key "$key_id" 2>/dev/null && return 0
          fi
      done
      echo "Warning: Could not import key $key_id from any keyserver."
      return 1
  }
  _import_key_multi_server F52611D11AFD4556 || true
'
echo "endeavouros key fixed"

echo "=== Retry pacman sync ==="
podman exec arch-pamac pacman -Sy 2>&1 | tail -25

echo ""
echo "DONE"