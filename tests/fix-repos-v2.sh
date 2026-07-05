#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Writing proper chaotic-mirrorlist ==="
podman exec arch-pamac bash -c "printf '%s\n%s\n%s\n' '## Chaotic-AUR mirrorlist' 'Server = https://cdn-mirror.chaotic.cx/chaotic-aur/\$arch' 'Server = https://geo-mirror.chaotic.cx/chaotic-aur/\$arch' > /etc/pacman.d/chaotic-mirrorlist"
echo "Mirrorlist content:"
podman exec arch-pamac cat /etc/pacman.d/chaotic-mirrorlist

echo ""
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
  echo "archlinuxcn key signed"
'

echo ""
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
  echo "endeavouros key signed"
'

echo ""
echo "=== Testing each repo individually ==="
podman exec arch-pamac pacman -Sy --noconfirm core 2>&1 | tail -3
podman exec arch-pamac pacman -Sy --noconfirm extra 2>&1 | tail -3
podman exec arch-pamac pacman -Sy --noconfirm chaotic-aur 2>&1 | tail -3
podman exec arch-pamac pacman -Sy --noconfirm archlinuxcn 2>&1 | tail -3
podman exec arch-pamac pacman -Sy --noconfirm endeavouros 2>&1 | tail -3

echo ""
echo "=== Full sync ==="
podman exec arch-pamac pacman -Sy 2>&1 | tail -20

echo ""
echo "DONE"