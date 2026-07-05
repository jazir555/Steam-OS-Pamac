#!/bin/bash
set -euo pipefail

rm -f /var/lib/pacman/db.lck

_repo_already_enabled() {
    grep -q "^\[$1\]" /etc/pacman.conf
}

_import_key_multi_server() {
    local key_id="$1"
    local keyservers=("hkps://keyserver.ubuntu.com" "hkps://keys.openpgp.org" "hkps://pgp.mit.edu")
    for server in "${keyservers[@]}"; do
        if timeout 30 pacman-key --recv-key --keyserver "$server" "$key_id" 2>/dev/null; then
            timeout 30 pacman-key --lsign-key "$key_id" 2>/dev/null && return 0
        fi
    done
    echo "Warning: Could not import key $key_id from any keyserver."
    echo "The key may have been rotated. Try updating the keyring package manually."
    return 1
}

echo "=== Configuring Chaotic-AUR repository ==="
if ! _repo_already_enabled "chaotic-aur"; then
    pacman -Sy --noconfirm 2>/dev/null || true
    echo "Installing chaotic-keyring..."
    if pacman -S --noconfirm --needed chaotic-keyring 2>/dev/null; then
        echo "Chaotic keyring installed successfully."
    else
        echo "Chaotic keyring not in default repos. Installing from mirror..."
        if command -v curl >/dev/null 2>&1; then
            keyring_tmp="$(mktemp -d)"
            if curl -sL "https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst" -o "$keyring_tmp/chaotic-keyring.pkg.tar.zst" 2>/dev/null && \
               [[ -s "$keyring_tmp/chaotic-keyring.pkg.tar.zst" ]]; then
                pacman -U --noconfirm "$keyring_tmp/chaotic-keyring.pkg.tar.zst" 2>/dev/null || echo "Warning: Chaotic keyring install from mirror failed."
            else
                echo "Warning: Could not download chaotic-keyring."
            fi
            rm -rf "$keyring_tmp"
        else
            echo "Warning: curl not available to download chaotic-keyring."
        fi
    fi
    echo "Adding repository [chaotic-aur]..."
    printf '\n[chaotic-aur]\nSigLevel = TrustedOnly\nInclude = /etc/pacman.d/chaotic-mirrorlist\n' >> /etc/pacman.conf
    mkdir -p /etc/pacman.d
    if ! [[ -f /etc/pacman.d/chaotic-mirrorlist ]] || ! grep -q '^Server' /etc/pacman.d/chaotic-mirrorlist 2>/dev/null; then
        if command -v curl >/dev/null 2>&1 && \
           curl -sL "https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist" -o /etc/pacman.d/chaotic-mirrorlist 2>/dev/null && \
           [[ -s /etc/pacman.d/chaotic-mirrorlist ]] && \
           ! grep -q '<html\|^<!DOCTYPE' /etc/pacman.d/chaotic-mirrorlist 2>/dev/null; then
            : # mirrorlist downloaded successfully
        else
            printf '%s\n' \
                '## Chaotic-AUR mirrorlist' \
                'Server = https://cdn-mirror.chaotic.cx/chaotic-aur/$arch' \
                'Server = https://geo-mirror.chaotic.cx/chaotic-aur/$arch' \
                > /etc/pacman.d/chaotic-mirrorlist
            echo "Warning: Using built-in chaotic-mirrorlist."
        fi
    fi
    if command -v pacman-key >/dev/null 2>&1; then
        _import_key_multi_server 30565AC3868033CA || true
    fi
else
    echo "Chaotic-AUR already enabled."
fi

echo "=== Configuring archlinuxcn repository ==="
if ! _repo_already_enabled "archlinuxcn"; then
    echo "Adding repository [archlinuxcn]..."
    printf '\n[archlinuxcn]\nSigLevel = TrustedOnly\nServer = https://repo.archlinuxcn.org/$arch\n' >> /etc/pacman.conf
    pacman -Sy --noconfirm 2>/dev/null || true
    if pacman -S --noconfirm --needed archlinuxcn-keyring 2>/dev/null; then
        echo "archlinuxcn-keyring installed."
    else
        echo "Warning: archlinuxcn-keyring install failed. Trying alternate method..."
        if command -v pacman-key >/dev/null 2>&1; then
            _import_key_multi_server 11C2E2D1D43CF75C || true
        fi
    fi
else
    echo "archlinuxcn already enabled."
fi

echo "=== Configuring endeavouros repository ==="
if ! _repo_already_enabled "endeavouros"; then
    echo "Adding repository [endeavouros]..."
    printf '\n[endeavouros]\nSigLevel = TrustedOnly\nServer = https://mirror.freedif.org/EndeavourOS/repo/$repo/$arch\n' >> /etc/pacman.conf
    pacman -Sy --noconfirm 2>/dev/null || true
    if pacman -S --noconfirm --needed endeavouros-keyring 2>/dev/null; then
        echo "endeavouros keyring installed."
    else
        echo "Warning: endeavouros keyring install failed. Trying alternate method..."
        if command -v pacman-key >/dev/null 2>&1; then
            _import_key_multi_server F52611D11AFD4556 || true
        fi
    fi
else
    echo "endeavouros already enabled."
fi

echo "=== Syncing package databases with new repositories ==="
pacman -Sy --noconfirm 2>/dev/null || echo "Warning: database sync with new repos had issues."

echo "Third-party repository configuration complete."
echo "Available additional repos: chaotic-aur, archlinuxcn, endeavouros"

echo "=== Verifying repos in pacman.conf ==="
grep '^\[' /etc/pacman.conf
