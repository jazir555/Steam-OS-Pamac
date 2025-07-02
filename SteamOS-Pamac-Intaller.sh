#!/bin/bash

# Steam Deck Pamac Setup Script
# This script is specifically designed to work on SteamOS without Developer Mode
# It automates the setup of a persistent, GUI-based package management system
# using Distrobox containers with no host system modifications.

# Stop on any error
set -e

# --- Configuration Variables ---
SCRIPT_VERSION="3.6"  # Fixed version
CONTAINER_NAME="${CONTAINER_NAME:-arch-box}"
CURRENT_USER=$(whoami)
LOG_FILE="$HOME/distrobox-pamac-setup.log"
SCRIPT_URL="https://raw.githubusercontent.com/user/repo/main/setup-pamac.sh"

# Feature flags
ENABLE_MULTILIB="false"
ENABLE_BUILD_CACHE="true"
CONFIGURE_MIRRORS="true"
AUTO_EXPORT_APPS="true"
AUTO_EXPORT_FLATPAKS="false"
ENABLE_GAMING_PACKAGES="false"
CONFIGURE_LOCALE="false"
TARGET_LOCALE="en_US.UTF-8"
MIRROR_COUNTRIES="US,Canada"
FORCE_REBUILD="false"

# Operation mode flags
DRY_RUN="false"
LOG_LEVEL="normal"
EXPORTED_APPS=()
CONTAINER_WAS_CREATED_BY_SCRIPT="false"

# --- Color Codes for Output ---
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  RED='\033[0;31m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  GREEN=''; YELLOW=''; BLUE=''; RED=''; BOLD=''; NC=''
fi

# --- Logging and Output Functions ---
initialize_logging() {
    echo "=== Steam Deck Pamac Setup v${SCRIPT_VERSION} - $(date) ===" > "$LOG_FILE"
    echo "User: $CURRENT_USER" >> "$LOG_FILE"
    echo "SteamOS Version: $(grep VERSION_ID /etc/os-release 2>/dev/null | cut -d= -f2 || echo 'N/A')" >> "$LOG_FILE"
    echo "Features: MULTILIB=$ENABLE_MULTILIB GAMING=$ENABLE_GAMING_PACKAGES" >> "$LOG_FILE"
    echo "===========================================" >> "$LOG_FILE"
    
    trap 'echo "=== Run finished: $(date) - Exit: $? ===" >> "$LOG_FILE"' EXIT
}

_log() {
    local level="$1"
    local color="$2"
    local message="$3"
    echo -e "$(date +'%Y-%m-%d %H:%M:%S') - $level - $message" >> "$LOG_FILE"
    case "$LOG_LEVEL" in
        "quiet") [ "$level" = "ERROR" ] && echo -e "${color}${message}${NC}" ;;
        "normal"|"verbose") echo -e "${color}${message}${NC}" ;;
    esac
}

log_step() { _log "INFO" "$BLUE" "\n${BOLD}==> $1${NC}"; }
log_info() { [ "$LOG_LEVEL" != "quiet" ] && _log "INFO" "" "$1"; }
log_success() { _log "SUCCESS" "$GREEN" "✓ $1"; }
log_warn() { _log "WARN" "$YELLOW" "⚠️ $1"; }
log_error() { _log "ERROR" "$RED" "❌ $1"; }

run_command() {
    log_info "Executing: $*"
    if [ "$DRY_RUN" = "true" ]; then
        log_warn "[DRY RUN] Would execute: $*"
        return 0
    fi
    if [ "$LOG_LEVEL" = "verbose" ]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
        return ${PIPESTATUS[0]}
    else
        "$@" &>> "$LOG_FILE"
        return $?
    fi
}

# --- Helper Functions ---
show_usage() {
    echo -e "${BOLD}Usage: $0 [OPTIONS]${NC}"
    echo "Options:"
    echo "  --container-name NAME  Set container name (default: arch-box)"
    echo "  --force-rebuild        Rebuild existing container"
    echo "  --update               Update this script"
    echo "  --uninstall            Remove container and apps"
    echo "  --enable-multilib      Enable 32-bit support"
    echo "  --enable-gaming        Install gaming packages"
    echo "  --dry-run              Simulate without changes"
    echo "  --verbose              Show detailed output"
    echo "  --quiet                Only show errors"
    echo "  -h, --help             Show this help"
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --container-name) 
                if [ -z "$2" ]; then
                    log_error "Container name cannot be empty"
                    exit 1
                fi
                CONTAINER_NAME="$2"; shift 2 ;;
            --force-rebuild) FORCE_REBUILD="true"; shift ;;
            --enable-multilib) ENABLE_MULTILIB="true"; shift ;;
            --enable-gaming) ENABLE_GAMING_PACKAGES="true"; shift ;;
            --dry-run) DRY_RUN="true"; shift ;;
            --verbose) LOG_LEVEL="verbose"; shift ;;
            --quiet) LOG_LEVEL="quiet"; shift ;;
            --update) update_script; exit 0 ;;
            --uninstall) uninstall_setup; exit 0 ;;
            -h|--help) show_usage; exit 0 ;;
            *) log_error "Unknown option: $1"; show_usage; exit 1 ;;
        esac
    done
}

update_script() {
    log_step "Updating script..."
    if [ "$DRY_RUN" = "true" ]; then
        log_warn "[DRY RUN] Would download update from $SCRIPT_URL"
        return
    fi
    
    local temp_file=$(mktemp)
    trap "rm -f '$temp_file'" EXIT
    
    if command -v curl &>/dev/null; then
        curl -fsSL "$SCRIPT_URL" -o "$temp_file" || {
            log_error "Download failed with curl"; exit 1
        }
    elif command -v wget &>/dev/null; then
        wget -qO "$temp_file" "$SCRIPT_URL" || {
            log_error "Download failed with wget"; exit 1
        }
    else
        log_error "Need curl or wget to update"; exit 1
    fi

    # Verify the downloaded file is not empty
    if [ ! -s "$temp_file" ]; then
        log_error "Downloaded file is empty"; exit 1
    fi

    chmod +x "$temp_file"
    mv "$temp_file" "$0"
    log_success "Script updated. Please rerun."
}

uninstall_setup() {
    log_step "Uninstalling..."
    
    if distrobox list | grep -qw "$CONTAINER_NAME"; then
        log_info "Removing container..."
        run_command distrobox rm "$CONTAINER_NAME" --force || log_warn "Container removal may have failed."
    else
        log_info "Container '$CONTAINER_NAME' not found"
    fi
    
    if [ -d "$HOME/.local/share/applications" ]; then
        log_info "Cleaning exported apps..."
        # Use find with proper escaping
        find "$HOME/.local/share/applications" -type f \( -name "*pamac*distrobox*" -o -name "*${CONTAINER_NAME}*" \) -delete 2>/dev/null || true
    fi
    
    if command -v update-desktop-database &>/dev/null; then
        run_command update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    fi
    
    log_success "Uninstallation complete"
}

check_steamos_compatibility() {
    if ! grep -q "ID=steamos" /etc/os-release 2>/dev/null; then
        log_warn "Not running on SteamOS! Compatibility not guaranteed."
    fi
    
    if ! command -v distrobox >/dev/null; then
        log_error "Missing distrobox. Required on SteamOS."
        log_info "Install with: curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix ~/.local"
        exit 1
    fi
    
    if ! command -v podman >/dev/null; then
        log_error "Missing podman. Required on SteamOS."
        exit 1
    fi
}

wait_for_container() {
    local attempts=0
    local max_attempts=30
    log_info "Waiting for container to become ready..."
    
    until distrobox enter "$CONTAINER_NAME" -- echo "Ready" &>/dev/null; do
        sleep 2
        ((attempts++))
        if [ $attempts -gt $max_attempts ]; then
            log_error "Container startup timed out after $((max_attempts * 2)) seconds"
            return 1
        fi
        [ $((attempts % 5)) -eq 0 ] && log_info "Still waiting... (${attempts}/${max_attempts})"
    done
    log_success "Container is ready"
}

# --- Core Functions ---
create_container() {
    log_step "Creating container: $CONTAINER_NAME"
    local volume_args=""
    
    if [ "$ENABLE_BUILD_CACHE" = "true" ]; then
        mkdir -p "$HOME/.cache/yay"
        volume_args="--volume $HOME/.cache/yay:/home/$CURRENT_USER/.cache/yay:rw"
        log_info "Enabled build cache volume"
    fi

    run_command distrobox create \
        --name "$CONTAINER_NAME" \
        --image archlinux:latest \
        --yes \
        $volume_args || {
        log_error "Container creation failed"
        return 1
    }
    
    CONTAINER_WAS_CREATED_BY_SCRIPT="true"
    wait_for_container
}

configure_container() {
    log_step "Configuring base container environment..."
    
    # Fixed setup script with proper error handling
    local setup_script=$(cat <<'EOF'
set -e
echo "Running as root to setup environment..."

# Ensure the wheel group exists and add the user to it
if ! getent group wheel >/dev/null 2>&1; then 
    groupadd wheel
    echo "Created wheel group"
fi

# Add user to wheel group (handle both 'deck' and current user)
for user in deck "$USER"; do
    if id "$user" >/dev/null 2>&1; then
        usermod -aG wheel "$user" 2>/dev/null || true
        echo "Added $user to wheel group"
        break
    fi
done

# Setup passwordless sudo for the wheel group
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel-nopasswd
chmod 0440 /etc/sudoers.d/wheel-nopasswd
echo "Configured passwordless sudo"

# Initialize pacman keyring with proper error handling
if ! pacman-key --init; then
    echo "Warning: pacman-key --init failed, continuing..."
fi

if ! pacman-key --populate archlinux; then
    echo "Warning: pacman-key --populate failed, continuing..."
fi

echo "Base environment configured successfully"
EOF
)
    
    # Execute setup script as root
    echo "$setup_script" | run_command distrobox enter --root "$CONTAINER_NAME" -- bash -s || {
        log_error "Container configuration failed"
        return 1
    }
}

install_pamac_and_hook() {
    log_step "Installing Pamac and system tools..."
    
    # Enhanced install script with better error handling
    local install_script=$(cat <<EOF
set -e
echo "Updating system and installing dependencies..."

# Update package database and install base tools
if ! pacman -Sy --noconfirm; then
    echo "Warning: Failed to update package database, continuing..."
fi

pacman -S --noconfirm --needed git base-devel || {
    echo "Error: Failed to install base dependencies"
    exit 1
}

echo "Checking for AUR helper (yay)..."
if ! command -v yay >/dev/null; then
    echo "Installing yay AUR helper..."
    # Determine the non-root user
    if id deck >/dev/null 2>&1; then
        BUILD_USER="deck"
    else
        BUILD_USER="\$(logname 2>/dev/null || echo \$SUDO_USER || echo \$USER)"
    fi
    
    sudo -u "\$BUILD_USER" bash <<'YAY_EOF'
set -e
echo "Building yay as user: \$(whoami)"
cd /tmp
rm -rf yay-bin
git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin
makepkg -si --noconfirm
cd /
rm -rf /tmp/yay-bin
echo "yay installation complete"
YAY_EOF
else
    echo "yay is already installed"
fi

echo "Installing pamac-aur..."
# Determine the non-root user for yay operations
if id deck >/dev/null 2>&1; then
    YAY_USER="deck"
else
    YAY_USER="\$(logname 2>/dev/null || echo \$SUDO_USER || echo \$USER)"
fi

sudo -u "\$YAY_USER" yay -S --noconfirm --needed pamac-aur || {
    echo "Error: Failed to install pamac-aur"
    exit 1
}

echo "Configuring Pamac..."
# Enable AUR in Pamac configuration
if [ -f /etc/pamac.conf ]; then
    sed -i 's/^#EnableAUR/EnableAUR/' /etc/pamac.conf
    sed -i 's/^#CheckAURUpdates/CheckAURUpdates/' /etc/pamac.conf
    echo "Pamac AUR support enabled"
else
    echo "Warning: /etc/pamac.conf not found"
fi

echo "Setting up desktop entry cleanup hook..."
mkdir -p /etc/pacman.d/hooks

# Create the cleanup script
cat > /usr/local/bin/cleanup-desktop-entries.sh <<'CLEANUP_EOF'
#!/bin/bash
set -e

# Find the user's home directory
if id deck >/dev/null 2>&1; then
    USER_HOME="/home/deck"
elif [ -n "\$SUDO_USER" ]; then
    USER_HOME="\$(getent passwd "\$SUDO_USER" | cut -d: -f6)"
else
    USER_HOME="\$(getent passwd \$(logname 2>/dev/null || echo \$USER) | cut -d: -f6)"
fi

if [ -z "\$USER_HOME" ] || [ ! -d "\$USER_HOME" ]; then
    echo "Warning: Could not determine user home directory"
    exit 0
fi

# Read package names from stdin (one per line)
while IFS= read -r pkg_name; do
    if [ -n "\$pkg_name" ]; then
        echo "Processing package: \$pkg_name"
        # Find desktop files provided by the package
        desktop_files=\$(pacman -Qlq "\$pkg_name" 2>/dev/null | grep -E '\.desktop$' || true)
        
        for desktop_file in \$desktop_files; do
            if [ -n "\$desktop_file" ]; then
                entry_name=\$(basename "\$desktop_file" .desktop)
                echo "Cleaning up exported entry for: \$entry_name"
                # Remove exported desktop entries
                find "\$USER_HOME/.local/share/applications" -type f -name "*\${entry_name}*${CONTAINER_NAME}*.desktop" -delete 2>/dev/null || true
            fi
        done
    fi
done

# Update desktop database
if [ -d "\$USER_HOME/.local/share/applications" ]; then
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "\$USER_HOME/.local/share/applications" 2>/dev/null || true
    fi
fi
CLEANUP_EOF

chmod +x /usr/local/bin/cleanup-desktop-entries.sh

# Create the pacman hook
cat > /etc/pacman.d/hooks/cleanup-desktop-entries.hook <<'HOOK_EOF'
[Trigger]
Operation = Remove
Type = Package
Target = *

[Action]
Description = Cleaning up exported desktop entries...
When = PostTransaction
Exec = /usr/local/bin/cleanup-desktop-entries.sh
NeedsTargets
HOOK_EOF

echo "Pamac installation and hook setup complete"
EOF
)
    
    # Execute install script with environment variables
    echo "$install_script" | run_command distrobox enter "$CONTAINER_NAME" -- sudo -E env CONTAINER_NAME="$CONTAINER_NAME" bash -s || {
        log_error "Pamac installation failed"
        return 1
    }
}

export_apps() {
    log_step "Exporting Pamac to the host system..."
    
    # Try standard export first
    if run_command distrobox-export --app pamac-manager --extra-flags "--no-sandbox" 2>/dev/null; then
        log_success "Pamac exported successfully via distrobox-export"
    else
        log_warn "Standard export failed. Creating manual launcher..."
        mkdir -p "$HOME/.local/share/applications"
        
        cat > "$HOME/.local/share/applications/pamac-manager-${CONTAINER_NAME}.desktop" <<EOF
[Desktop Entry]
Name=Pamac Manager ($CONTAINER_NAME)
Comment=Install and remove software
Exec=distrobox enter $CONTAINER_NAME -- pamac-manager --no-sandbox
Icon=pamac
Terminal=false
Type=Application
Categories=System;PackageManager;
StartupNotify=true
EOF
        log_success "Created manual desktop launcher"
    fi
    
    # Update desktop database
    if command -v update-desktop-database &>/dev/null; then
        run_command update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    fi
}

# Enhanced multilib support
configure_multilib() {
    if [ "$ENABLE_MULTILIB" = "true" ]; then
        log_step "Enabling multilib support..."
        local multilib_script=$(cat <<'EOF'
set -e
echo "Enabling multilib repository..."
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
    echo "Multilib repository added"
else
    echo "Multilib repository already enabled"
fi
pacman -Sy --noconfirm
EOF
)
        echo "$multilib_script" | run_command distrobox enter --root "$CONTAINER_NAME" -- bash -s
    fi
}

# Enhanced gaming packages installation
install_gaming_packages() {
    if [ "$ENABLE_GAMING_PACKAGES" = "true" ]; then
        log_step "Installing gaming packages..."
        local gaming_script=$(cat <<'EOF'
set -e
echo "Installing gaming-related packages..."
# Determine the non-root user
if id deck >/dev/null 2>&1; then
    YAY_USER="deck"
else
    YAY_USER="$(logname 2>/dev/null || echo $SUDO_USER || echo $USER)"
fi

# Install gaming packages via yay
sudo -u "$YAY_USER" yay -S --noconfirm --needed \
    steam \
    lutris \
    wine-staging \
    winetricks \
    gamemode \
    mangohud || echo "Some gaming packages may have failed to install"
EOF
)
        echo "$gaming_script" | run_command distrobox enter "$CONTAINER_NAME" -- sudo bash -s
    fi
}

# --- Main Execution ---
main() {
    initialize_logging
    parse_arguments "$@"
    check_steamos_compatibility

    echo -e "${BOLD}${BLUE}Steam Deck Pamac Setup v${SCRIPT_VERSION}${NC}"
    [ "$DRY_RUN" = "true" ] && log_warn "DRY RUN MODE: No changes will be made"
    
    # Handle force rebuild
    if [ "$FORCE_REBUILD" = "true" ] && distrobox list | grep -qw "$CONTAINER_NAME"; then
        log_step "Rebuilding container as requested..."
        run_command distrobox rm "$CONTAINER_NAME" --force
    fi

    # Create or use existing container
    if ! distrobox list | grep -qw "$CONTAINER_NAME"; then
        create_container
    else
        log_success "Using existing container: $CONTAINER_NAME"
        wait_for_container
    fi

    # Configure and install
    configure_container
    configure_multilib
    install_pamac_and_hook
    install_gaming_packages
    export_apps

    echo -e "\n${BOLD}${GREEN}Setup Complete!${NC}"
    echo -e "You can now find 'Pamac Manager' in your application menu."
    echo -e "Location: System → Pamac Manager ($CONTAINER_NAME)"
    echo -e "\nFeatures enabled:"
    echo -e "  • AUR support: Yes"
    echo -e "  • Multilib: $ENABLE_MULTILIB"
    echo -e "  • Gaming packages: $ENABLE_GAMING_PACKAGES"
    echo -e "  • Build cache: $ENABLE_BUILD_CACHE"
    echo -e "\nFor detailed logs, see: ${LOG_FILE}"
    echo -e "To uninstall: $0 --uninstall"
}

main "$@"
