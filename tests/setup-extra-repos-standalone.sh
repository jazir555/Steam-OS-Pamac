#!/bin/bash
set -euo pipefail

rm -f /var/lib/pacman/db.lck

_repo_already_enabled() {
    grep -q "^\[$1\]" /etc/pacman.conf
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
        pacman-key --recv-key 30565AC3868033CA 2>/dev/null || true
        pacman-key --lsign-key 30565AC3868033CA 2>/dev/null || true
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
            pacman-key --recv-key 11C2E2D1D43CF75C 2>/dev/null || true
            pacman-key --lsign-key 11C2E2D1D43CF75C 2>/dev/null || true
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
            pacman-key --recv-key F52611D11AFD4556 2>/dev/null || true
            pacman-key --lsign-key F52611D11AFD4556 2>/dev/null || true
        fi
    fi
else
    echo "endeavouros already enabled."
fi

echo "=== Configuring blackarch repository ==="
if ! _repo_already_enabled "blackarch"; then
    echo "Adding repository [blackarch]..."
    printf '\n[blackarch]\nSigLevel = TrustedOnly\nServer = https://blackarch.org/blackarch/$repo/os/$arch\n' >> /etc/pacman.conf
    pacman -Sy --noconfirm 2>/dev/null || true
    echo "Installing blackarch-keyring..."
    if pacman -S --noconfirm --needed blackarch-keyring 2>/dev/null; then
        echo "blackarch keyring installed."
        if command -v pacman-key >/dev/null 2>&1; then
            pacman-key --lsign-key 4345771566D76038C2C3A6AB9E8275C9E4D56107 2>/dev/null || true
        fi
    else
        echo "Warning: blackarch-keyring install failed. Trying alternate method..."
        if command -v curl >/dev/null 2>&1; then
            strap_tmp="$(mktemp -d)"
            if curl -sL "https://blackarch.org/strap.sh" -o "$strap_tmp/strap.sh" 2>/dev/null && \
               [[ -s "$strap_tmp/strap.sh" ]]; then
                chmod +x "$strap_tmp/strap.sh"
                "$strap_tmp/strap.sh" 2>/dev/null || echo "Warning: blackarch strap.sh failed."
            fi
            rm -rf "$strap_tmp"
        fi
    fi
else
    echo "blackarch already enabled."
fi

echo "=== Syncing package databases with new repositories ==="
pacman -Sy --noconfirm 2>/dev/null || echo "Warning: database sync with new repos had issues."

echo "Third-party repository configuration complete."
echo "Available additional repos: chaotic-aur, archlinuxcn, endeavouros, blackarch"

echo "=== Verifying repos in pacman.conf ==="
grep '^\[' /etc/pacman.conf
