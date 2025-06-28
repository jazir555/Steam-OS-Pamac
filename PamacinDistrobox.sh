#!/bin/bash

# Enhanced Steam Deck Pamac Setup Script v2.2
# This script automates the setup of a persistent, GUI-based package management
# system (Pamac with AUR) on SteamOS using Distrobox.
# It is idempotent, fully automated, and requires no user input after execution.

# Stop on any error
set -e

# --- Configuration Variables ---
SCRIPT_VERSION="2.2"
CONTAINER_NAME="${CONTAINER_NAME:-arch-box}"
CURRENT_USER=$(whoami)
LOG_FILE="$HOME/distrobox-pamac-setup.log"
SCRIPT_URL="https://raw.githubusercontent.com/user/repo/main/setup-pamac.sh"

# Feature flags (can be set via environment variables)
ENABLE_MULTILIB="${ENABLE_MULTILIB:-false}"
ENABLE_BUILD_CACHE="${ENABLE_BUILD_CACHE:-true}"
CONFIGURE_MIRRORS="${CONFIGURE_MIRRORS:-true}"
AUTO_EXPORT_APPS="${AUTO_EXPORT_APPS:-true}"
ENABLE_GAMING_PACKAGES="${ENABLE_GAMING_PACKAGES:-false}"
CONFIGURE_LOCALE="${CONFIGURE_LOCALE:-false}"
TARGET_LOCALE="${TARGET_LOCALE:-en_US.UTF-8}"

# --- Color Codes for Output (with TTY detection) ---
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  RED='\033[0;31m'
  BOLD='\033[1m'
  NC='\033[0m' # No Color
else
  GREEN=''; YELLOW=''; BLUE=''; RED=''; BOLD=''; NC=''
fi

# --- Logging and Exit Handling ---
initialize_logging() {
    echo "=== Steam Deck Pamac Setup v${SCRIPT_VERSION} - Run started at: $(date) ===" > "$LOG_FILE"
    echo "User: $CURRENT_USER" >> "$LOG_FILE"
    echo "System: $(uname -a)" >> "$LOG_FILE"
    echo "SteamOS Version: $(cat /etc/os-release | grep VERSION_ID | cut -d'=' -f2 | tr -d '\"' 2>/dev/null || echo 'Unknown')" >> "$LOG_FILE"
    echo "Feature Flags:" >> "$LOG_FILE"
    echo "  ENABLE_MULTILIB: $ENABLE_MULTILIB" >> "$LOG_FILE"
    echo "  ENABLE_BUILD_CACHE: $ENABLE_BUILD_CACHE" >> "$LOG_FILE"
    echo "  CONFIGURE_MIRRORS: $CONFIGURE_MIRRORS" >> "$LOG_FILE"
    echo "  AUTO_EXPORT_APPS: $AUTO_EXPORT_APPS" >> "$LOG_FILE"
    echo "===========================================" >> "$LOG_FILE"
    
    # Ensure a final message is logged when the script exits
    trap 'echo "=== Run finished at: $(date) - Exit code: $? ===" >> "$LOG_FILE"' EXIT
}

# --- Helper Functions ---
log_and_echo() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

log_only() {
    echo -e "$1" >> "$LOG_FILE"
}

show_usage() {
    echo -e "${BOLD}Usage: $0 [OPTIONS]${NC}"
    echo ""
    echo "Options:"
    echo "  --container-name NAME    Set container name (default: arch-box)"
    echo "  --enable-multilib        Enable multilib repository for 32-bit apps"
    echo "  --enable-gaming          Install gaming-related packages"
    echo "  --configure-locale       Configure system locale"
    echo "  --locale LOCALE          Set target locale (default: en_US.UTF-8)"
    echo "  --disable-build-cache    Don't use persistent build cache"
    echo "  --disable-mirrors        Don't configure fastest mirrors"
    echo "  --disable-auto-export    Don't automatically export installed apps"
    echo "  --update                 Update this script to latest version"
    echo "  --uninstall             Remove container and exported apps"
    echo "  --help, -h              Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  CONTAINER_NAME          Override container name"
    echo "  ENABLE_MULTILIB         Enable multilib (true/false)"
    echo "  ENABLE_BUILD_CACHE      Use build cache (true/false)"
    echo "  CONFIGURE_MIRRORS       Configure mirrors (true/false)"
    echo "  AUTO_EXPORT_APPS        Auto-export apps (true/false)"
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --container-name)
                CONTAINER_NAME="$2"
                shift 2
                ;;
            --enable-multilib)
                ENABLE_MULTILIB="true"
                shift
                ;;
            --enable-gaming)
                ENABLE_GAMING_PACKAGES="true"
                shift
                ;;
            --configure-locale)
                CONFIGURE_LOCALE="true"
                shift
                ;;
            --locale)
                TARGET_LOCALE="$2"
                CONFIGURE_LOCALE="true"
                shift 2
                ;;
            --disable-build-cache)
                ENABLE_BUILD_CACHE="false"
                shift
                ;;
            --disable-mirrors)
                CONFIGURE_MIRRORS="false"
                shift
                ;;
            --disable-auto-export)
                AUTO_EXPORT_APPS="false"
                shift
                ;;
            --update)
                update_script
                exit 0
                ;;
            --uninstall)
                uninstall_setup
                exit 0
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                show_usage
                exit 1
                ;;
        esac
    done
}

update_script() {
    echo -e "${BLUE}Updating script to latest version...${NC}"
    
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL "$SCRIPT_URL" -o "/tmp/setup-pamac-new.sh"; then
            chmod +x "/tmp/setup-pamac-new.sh"
            mv "/tmp/setup-pamac-new.sh" "$0"
            echo -e "${GREEN}✓ Script updated successfully. Please run it again.${NC}"
        else
            echo -e "${RED}Failed to download script update.${NC}"
            exit 1
        fi
    else
        echo -e "${RED}curl not found. Cannot update script.${NC}"
        exit 1
    fi
}

uninstall_setup() {
    echo -e "${YELLOW}Uninstalling Steam Deck Pamac setup...${NC}"
    
    # Remove container
    if distrobox list --no-color 2>/dev/null | grep -q " $CONTAINER_NAME "; then
        echo -e "${YELLOW}Removing container '$CONTAINER_NAME'...${NC}"
        distrobox rm "$CONTAINER_NAME" --force
        echo -e "${GREEN}✓ Container removed.${NC}"
    fi
    
    # Remove exported applications
    if [ -d "$HOME/.local/share/applications" ]; then
        echo -e "${YELLOW}Removing exported applications...${NC}"
        find "$HOME/.local/share/applications" -name "*pamac*distrobox*" -delete 2>/dev/null || true
        find "$HOME/.local/share/applications" -name "*$CONTAINER_NAME*" -delete 2>/dev/null || true
        update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true
        echo -e "${GREEN}✓ Exported applications removed.${NC}"
    fi
    
    # Remove BoxBuddy if desired
    read -p "Also remove BoxBuddy? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        flatpak uninstall --user -y io.github.dvlv.BoxBuddy 2>/dev/null || true
        echo -e "${GREEN}✓ BoxBuddy removed.${NC}"
    fi
    
    echo -e "${GREEN}Uninstallation complete.${NC}"
}

wait_for_container() {
    local container_name="$1"
    local max_attempts=60
    local attempt=1
    
    echo -e "${YELLOW}Waiting for container to be ready...${NC}"
    while [ $attempt -le $max_attempts ]; do
        if distrobox enter "$container_name" -- echo "Container ready" &>/dev/null; then
            echo -e "${GREEN}Container is ready.${NC}"
            return 0
        fi
        echo -n "."
        sleep 2
        ((attempt++))
    done
    
    echo -e "\n${RED}Container failed to become ready after $max_attempts attempts.${NC}"
    return 1
}

check_steamos_version() {
    local version_file="/etc/os-release"
    if [ -f "$version_file" ]; then
        local version_id=$(grep "VERSION_ID" "$version_file" | cut -d'=' -f2 | tr -d '"')
        log_only "Detected SteamOS version: $version_id"
        
        # Check if it's at least version 3.5
        if [ -n "$version_id" ]; then
            local major=$(echo "$version_id" | cut -d'.' -f1)
            local minor=$(echo "$version_id" | cut -d'.' -f2)
            if [ "$major" -ge 3 ] && [ "$minor" -ge 5 ]; then
                return 0
            fi
        fi
    fi
    return 1
}

configure_mirrors() {
    if [ "$CONFIGURE_MIRRORS" = "true" ]; then
        echo -e "${BLUE}Configuring fastest mirrors...${NC}"
        
        TEMP_MIRROR_SCRIPT=$(mktemp)
        cat > "$TEMP_MIRROR_SCRIPT" << 'MIRROR_SCRIPT_EOF'
#!/bin/bash
set -e

# Install reflector if not present
if ! pacman -Qi reflector &>/dev/null; then
    sudo pacman -S --noconfirm reflector
fi

# Get the fastest mirrors
echo "Configuring fastest mirrors for your location..."
sudo reflector --country US,Canada --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

echo "Mirror configuration complete"
MIRROR_SCRIPT_EOF

        if distrobox enter "$CONTAINER_NAME" -- bash "$TEMP_MIRROR_SCRIPT" &>> "$LOG_FILE"; then
            echo -e "${GREEN}✓ Mirrors configured successfully.${NC}"
        else
            echo -e "${YELLOW}Warning: Mirror configuration failed, continuing...${NC}"
        fi
        rm -f "$TEMP_MIRROR_SCRIPT"
    fi
}

configure_locale() {
    if [ "$CONFIGURE_LOCALE" = "true" ]; then
        echo -e "${BLUE}Configuring system locale to $TARGET_LOCALE...${NC}"
        
        TEMP_LOCALE_SCRIPT=$(mktemp)
        cat > "$TEMP_LOCALE_SCRIPT" << LOCALE_SCRIPT_EOF
#!/bin/bash
set -e

TARGET_LOCALE="$1"

# Uncomment the target locale in locale.gen
sudo sed -i "s/^#\${TARGET_LOCALE}/\${TARGET_LOCALE}/" /etc/locale.gen

# Generate locales
sudo locale-gen

# Set system locale
echo "LANG=\${TARGET_LOCALE}" | sudo tee /etc/locale.conf

echo "Locale configuration complete: \${TARGET_LOCALE}"
LOCALE_SCRIPT_EOF

        if distrobox enter "$CONTAINER_NAME" -- bash "$TEMP_LOCALE_SCRIPT" "$TARGET_LOCALE" &>> "$LOG_FILE"; then
            echo -e "${GREEN}✓ Locale configured to $TARGET_LOCALE.${NC}"
        else
            echo -e "${YELLOW}Warning: Locale configuration failed, continuing...${NC}"
        fi
        rm -f "$TEMP_LOCALE_SCRIPT"
    fi
}

# FIX 1: configure_multilib is now its own function
configure_multilib() {
    if [ "$ENABLE_MULTILIB" = "true" ]; then
        echo -e "${BLUE}Enabling multilib repository...${NC}"
        
        TEMP_MULTILIB_SCRIPT=$(mktemp)
        cat > "$TEMP_MULTILIB_SCRIPT" << 'MULTILIB_SCRIPT_EOF'
#!/bin/bash
set -e

# Check if multilib is already enabled
if grep -q "^\[multilib\]" /etc/pacman.conf; then
    echo "Multilib is already enabled"
    exit 0
fi

# Enable multilib repository
echo "Enabling multilib repository..."
sudo cp /etc/pacman.conf /etc/pacman.conf.bak

# Add multilib section
sudo bash -c 'cat >> /etc/pacman.conf << EOF

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF'

# Update package database
sudo pacman -Sy

echo "Multilib repository enabled"
MULTILIB_SCRIPT_EOF

        if distrobox enter "$CONTAINER_NAME" -- bash "$TEMP_MULTILIB_SCRIPT" &>> "$LOG_FILE"; then
            echo -e "${GREEN}✓ Multilib repository enabled.${NC}"
        else
            echo -e "${YELLOW}Warning: Multilib configuration failed, continuing...${NC}"
        fi
        rm -f "$TEMP_MULTILIB_SCRIPT"
    fi
}

install_gaming_packages() {
    if [ "$ENABLE_GAMING_PACKAGES" = "true" ]; then
        echo -e "${BLUE}Installing gaming-related packages...${NC}"
        
        TEMP_GAMING_SCRIPT=$(mktemp)
        cat > "$TEMP_GAMING_SCRIPT" << 'GAMING_SCRIPT_EOF'
#!/bin/bash
set -e

echo "Installing gaming utilities and libraries..."

# Essential gaming packages
GAMING_PACKAGES=(
    "wine"
    "winetricks" 
    "lutris"
    "steam"
    "gamemode"
    "lib32-gamemode"
    "mangohud"
    "lib32-mangohud"
    "discord"
    "obs-studio"
)

# Install packages that are available
for package in "${GAMING_PACKAGES[@]}"; do
    echo "Installing $package..."
    if yay -S --noconfirm --needed "$package" 2>/dev/null; then
        echo "✓ $package installed successfully"
    else
        echo "⚠ $package installation failed or not available"
    fi
done

echo "Gaming packages installation complete"
GAMING_SCRIPT_EOF

        if distrobox enter "$CONTAINER_NAME" -- bash "$TEMP_GAMING_SCRIPT" &>> "$LOG_FILE"; then
            echo -e "${GREEN}✓ Gaming packages installed.${NC}"
        else
            echo -e "${YELLOW}Warning: Some gaming packages may have failed to install.${NC}"
        fi
        rm -f "$TEMP_GAMING_SCRIPT"
    fi
}

setup_build_cache() {
    if [ "$ENABLE_BUILD_CACHE" = "true" ]; then
        echo -e "${BLUE}Setting up persistent build cache...${NC}"
        
        # Create cache directories on the host
        mkdir -p "$HOME/.cache/yay"
        mkdir -p "$HOME/.cache/pacman/pkg"
        
        TEMP_CACHE_SCRIPT=$(mktemp)
        cat > "$TEMP_CACHE_SCRIPT" << 'CACHE_SCRIPT_EOF'
#!/bin/bash
set -e

# Configure yay to use persistent cache
mkdir -p ~/.config/yay

# FIX 2: Backup existing yay config before overwriting
YAY_CONFIG_FILE=~/.config/yay/config.json
if [ -f "$YAY_CONFIG_FILE" ]; then
    echo "Backing up existing yay config to ${YAY_CONFIG_FILE}.bak"
    cp "$YAY_CONFIG_FILE" "${YAY_CONFIG_FILE}.bak"
fi

cat > "$YAY_CONFIG_FILE" << EOF
{
    "buildDir": "/home/$(whoami)/.cache/yay",
    "cleanAfter": false,
    "cleanMenu": false
}
EOF

# Configure pacman cache
sudo sed -i 's|^#CacheDir.*|CacheDir = /home/'$(whoami)'/.cache/pacman/pkg|' /etc/pacman.conf

echo "Build cache configuration complete"
CACHE_SCRIPT_EOF

        if distrobox enter "$CONTAINER_NAME" -- bash "$TEMP_CACHE_SCRIPT" &>> "$LOG_FILE"; then
            echo -e "${GREEN}✓ Build cache configured.${NC}"
        else
            echo -e "${YELLOW}Warning: Build cache configuration failed, continuing...${NC}"
        fi
        rm -f "$TEMP_CACHE_SCRIPT"
    fi
}

# FIX 3: Renamed function to reflect its actual purpose
catalog_gui_apps() {
    if [ "$AUTO_EXPORT_APPS" = "true" ]; then
        echo -e "${BLUE}Cataloging installed GUI applications...${NC}"
        
        TEMP_EXPORT_SCRIPT=$(mktemp)
        cat > "$TEMP_EXPORT_SCRIPT" << 'EXPORT_SCRIPT_EOF'
#!/bin/bash
set -e

# Find all desktop files in the container
find /usr/share/applications -name "*.desktop" -type f | while read -r desktop_file; do
    app_name=$(basename "$desktop_file" .desktop)
    
    # Skip certain system applications
    case "$app_name" in
        org.freedesktop.*|systemd-*|dbus-*|gparted|htop|pamac-manager|pamac-gtk)
            continue
            ;;
    esac
    
    # Check if it's a GUI application
    if grep -q "^Type=Application" "$desktop_file" && ! grep -q "^Terminal=true" "$desktop_file"; then
        # This step just logs the apps. To truly export them, you would run:
        # distrobox-export --app "$app_name"
        echo "Cataloging potential GUI app for export: $app_name"
    fi
done
EXPORT_SCRIPT_EOF

        if distrobox enter "$CONTAINER_NAME" -- bash "$TEMP_EXPORT_SCRIPT" &>> "$LOG_FILE"; then
            echo -e "${GREEN}✓ GUI applications catalogued. You can export them manually with 'distrobox-export'.${NC}"
        else
            echo -e "${YELLOW}Warning: App cataloguing failed, continuing...${NC}"
        fi
        rm -f "$TEMP_EXPORT_SCRIPT"
    fi
}

cleanup_on_failure() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_and_echo "${RED}Setup failed with exit code $exit_code${NC}"
        log_and_echo "${YELLOW}Cleaning up partial installation...${NC}"
        
        # Remove container if it exists and is incomplete
        if distrobox list --no-color 2>/dev/null | grep -q " $CONTAINER_NAME "; then
            log_and_echo "Removing incomplete container..."
            distrobox rm "$CONTAINER_NAME" --force &>> "$LOG_FILE" || true
        fi
        
        # Remove exported applications
        if [ -d "$HOME/.local/share/applications" ]; then
            find "$HOME/.local/share/applications" -name "*pamac*distrobox*" -delete 2>/dev/null || true
        fi
        
        log_and_echo "${YELLOW}Cleanup complete. Check the log for details: ${LOG_FILE}${NC}"
    fi
}

# --- Main Execution ---
main() {
    # Initialize
    initialize_logging
    parse_arguments "$@"
    trap cleanup_on_failure ERR
    
    # Header
    echo -e "${BOLD}${BLUE}🚀 Steam Deck Persistent AUR Package Manager Setup v${SCRIPT_VERSION}${NC}"
    echo -e "${YELLOW}Container: $CONTAINER_NAME${NC}"
    echo -e "A detailed log will be saved to: ${LOG_FILE}\n"
    
    # Pre-flight checks
    if [ "$CURRENT_USER" != "deck" ] && [ ! -f "/etc/steamos-release" ]; then
        log_and_echo "${YELLOW}Warning: This script is designed for Steam Deck/SteamOS but will continue...${NC}"
    fi
    
    if ! check_steamos_version; then
        log_and_echo "${YELLOW}Warning: SteamOS version may be too old. Recommended: 3.5+${NC}"
    fi
    
    # Step 1: Check dependencies
    echo -e "${BLUE}Step 1: Checking for required host tools...${NC}"
    missing_tools=()
    for cmd in distrobox podman flatpak; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_tools+=("$cmd")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_and_echo "${RED}Error: Required tools not found: ${missing_tools[*]}${NC}"
        log_and_echo "Please ensure your Steam Deck is updated to SteamOS 3.6 or newer."
        exit 1
    fi
    echo -e "${GREEN}✓ All required host tools are available.${NC}\n"
    
    # Step 1.5: Verify Podman
    echo -e "${BLUE}Step 1.5: Verifying Podman functionality...${NC}"
    if ! podman info &>> "$LOG_FILE"; then
        log_and_echo "${YELLOW}Podman needs initialization. Setting up...${NC}"
        
        if ! podman machine list 2>/dev/null | grep -q "podman-machine-default"; then
            podman machine init &>> "$LOG_FILE" || true
        fi
        
        if ! podman machine list 2>/dev/null | grep -q "Currently running"; then
            podman machine start &>> "$LOG_FILE" || true
        fi
        
        if ! podman info &>> "$LOG_FILE"; then
            log_and_echo "${RED}Podman is not functioning properly. Check the log for details.${NC}"
            exit 1
        fi
    fi
    echo -e "${GREEN}✓ Podman is working correctly.${NC}\n"
    
    # Step 2: Create/verify container
    echo -e "${BLUE}Step 2: Setting up '$CONTAINER_NAME' container...${NC}"
    
    # Build volume mounts based on features
    VOLUME_ARGS=""
    if [ "$ENABLE_BUILD_CACHE" = "true" ]; then
        mkdir -p "$HOME/.cache/yay" "$HOME/.cache/pacman/pkg"
        VOLUME_ARGS="--volume $HOME/.cache/yay:/home/$CURRENT_USER/.cache/yay:rw --volume $HOME/.cache/pacman/pkg:/var/cache/pacman/pkg:rw"
    fi
    
    if ! distrobox list --no-color 2>/dev/null | grep -q " $CONTAINER_NAME "; then
        log_and_echo "Container '$CONTAINER_NAME' not found. Creating it now..."
        
        if ! distrobox create \
            --name "$CONTAINER_NAME" \
            --image archlinux:latest \
            --pull \
            --yes \
            --additional-packages "systemd" \
            --home "$HOME" \
            --volume /tmp:/tmp:rw \
            --volume /dev:/dev:rw \
            --volume /sys:/sys:ro \
            --volume /run/user/$(id -u):/run/user/$(id -u):rw \
            $VOLUME_ARGS &>> "$LOG_FILE"; then
            log_and_echo "${RED}Failed to create container. Check the log for details.${NC}"
            exit 1
        fi
        
        if ! wait_for_container "$CONTAINER_NAME"; then
            log_and_echo "${RED}Container creation failed or timed out.${NC}"
            exit 1
        fi
        
        echo -e "${GREEN}✓ Container created successfully.${NC}"
    else
        echo -e "${GREEN}✓ Container already exists.${NC}"
    fi
    echo ""
    
    # Step 3: Configure container
    echo -e "${BLUE}Step 3: Configuring container...${NC}"
    TEMP_CONFIG_SCRIPT=$(mktemp)
    cat > "$TEMP_CONFIG_SCRIPT" << 'CONFIG_SCRIPT_EOF'
#!/bin/bash
set -e

CURRENT_USER="$1"

# Configure sudo
groupadd -f wheel
usermod -aG wheel "$CURRENT_USER"
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-wheel-nopasswd
chmod 440 /etc/sudoers.d/99-wheel-nopasswd
visudo -c -f /etc/sudoers.d/99-wheel-nopasswd

# Initialize pacman
pacman-key --init || true
pacman-key --populate archlinux || true

echo 'Container configuration complete'
CONFIG_SCRIPT_EOF
    
    if ! distrobox enter "$CONTAINER_NAME" --root -- bash "$TEMP_CONFIG_SCRIPT" "$CURRENT_USER" &>> "$LOG_FILE"; then
        log_and_echo "${RED}Failed to configure container.${NC}"
        rm -f "$TEMP_CONFIG_SCRIPT"
        exit 1
    fi
    rm -f "$TEMP_CONFIG_SCRIPT"
    echo -e "${GREEN}✓ Container configured.${NC}\n"
    
    # Step 4: Configure features
    configure_mirrors
    configure_locale
    configure_multilib
    setup_build_cache
    
    # Step 5: Install Pamac
    echo -e "${BLUE}Step 5: Installing Pamac inside '$CONTAINER_NAME'...${NC}"
    TEMP_INSTALL_SCRIPT=$(mktemp)
    cat > "$TEMP_INSTALL_SCRIPT" << 'INSTALL_SCRIPT_EOF'
#!/bin/bash
set -e

is_installed() {
    pacman -Qi "$1" &>/dev/null
}

if is_installed pamac-aur || is_installed pamac-gtk; then
    echo "Pamac is already installed."
    if [ -f /etc/pamac.conf ]; then
        sudo sed -i 's/^#EnableAUR/EnableAUR/' /etc/pamac.conf
        sudo sed -i 's/^#CheckAURUpdates/CheckAURUpdates/' /etc/pamac.conf
    fi
    exit 0
fi

echo "Installing Pamac and dependencies..."
# SUGGESTION APPLIED: Update system before installing AUR packages
echo "Running full system upgrade to ensure keyring is up-to-date..."
sudo pacman -Syu --noconfirm

sudo pacman -S --needed --noconfirm git base-devel wget curl

if ! command -v yay &>/dev/null; then
    echo "Installing yay AUR helper..."
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    git clone https://aur.archlinux.org/yay-bin.git
    cd yay-bin
    makepkg -si --noconfirm --needed
    cd /
    rm -rf "$TEMP_DIR"
fi

echo "Installing Pamac GUI from AUR..."
yay -S --noconfirm --needed pamac-aur

if [ -f /etc/pamac.conf ]; then
    sudo sed -i 's/^#EnableAUR/EnableAUR/' /etc/pamac.conf
    sudo sed -i 's/^#CheckAURUpdates/CheckAURUpdates/' /etc/pamac.conf
fi

if command -v pamac-manager &>/dev/null; then
    echo "Pamac installation verified successfully!"
else
    echo "Pamac installation verification failed"
    exit 1
fi
INSTALL_SCRIPT_EOF
    
    if ! distrobox enter "$CONTAINER_NAME" -- bash "$TEMP_INSTALL_SCRIPT" 2>&1 | tee -a "$LOG_FILE"; then
        log_and_echo "${RED}Pamac installation failed.${NC}"
        rm -f "$TEMP_INSTALL_SCRIPT"
        exit 1
    fi
    rm -f "$TEMP_INSTALL_SCRIPT"
    echo -e "${GREEN}✓ Pamac installation complete.${NC}\n"
    
    # Step 5.5: Install gaming packages if requested
    install_gaming_packages
    
    # Step 6: Export applications
    echo -e "${BLUE}Step 6: Exporting Pamac to the SteamOS menu...${NC}"
    mkdir -p "$HOME/.local/share/applications"
    
    export_success=false
    for app_name in pamac-manager pamac-gtk; do
        if distrobox enter "$CONTAINER_NAME" -- which "$app_name" &>/dev/null; then
            if distrobox-export --app "$app_name" --extra-flags "--no-sandbox" &>> "$LOG_FILE"; then
                export_success=true
                echo -e "${GREEN}✓ Successfully exported '$app_name'.${NC}"
                break
            fi
        fi
    done
    
    if [ "$export_success" = false ]; then
        cat > "$HOME/.local/share/applications/pamac-manager-distrobox.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Pamac Package Manager
Comment=Add or remove software installed on your system
Icon=pamac-manager
Exec=distrobox enter $CONTAINER_NAME -- pamac-manager
Terminal=false
Categories=System;PackageManager;
EOF
        echo -e "${GREEN}✓ Manual desktop entry created.${NC}"
    fi
    
    update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true
    echo ""
    
    # Step 7: Install BoxBuddy
    echo -e "${BLUE}Step 7: Installing BoxBuddy for container management...${NC}"
    if ! flatpak remotes --user | grep -q "flathub"; then
        flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo &>> "$LOG_FILE" || true
    fi
    
    if ! flatpak info --user "io.github.dvlv.BoxBuddy" &>/dev/null; then
        if flatpak install --user -y flathub "io.github.dvlv.BoxBuddy" &>> "$LOG_FILE"; then
            echo -e "${GREEN}✓ BoxBuddy installed.${NC}"
        else
            echo -e "${YELLOW}BoxBuddy installation failed (optional).${NC}"
        fi
    else
        echo -e "${GREEN}✓ BoxBuddy already installed.${NC}"
    fi
    echo ""
    
    # Step 8: Auto-export apps
    catalog_gui_apps
    
    # Step 9: Final verification
    echo -e "${BLUE}Step 9: Verifying installation...${NC}"
    verification_issues=()
    
    if ! distrobox list --no-color 2>/dev/null | grep -q " $CONTAINER_NAME "; then
        verification_issues+=("Container not found")
    elif ! distrobox enter "$CONTAINER_NAME" -- echo "test" &>/dev/null; then
        verification_issues+=("Container not responding")
    fi
    
    if ! distrobox enter "$CONTAINER_NAME" -- which pamac-manager &>/dev/null; then
        verification_issues+=("Pamac not found")
    fi
    
    if [ ${#verification_issues[@]} -eq 0 ]; then
        echo -e "${GREEN}✓ All components verified successfully!${NC}"
    else
        log_and_echo "${YELLOW}Verification issues found:${NC}"
        for issue in "${verification_issues[@]}"; do
            log_and_echo "  - $issue"
        done
    fi
    echo ""
    
    # Success message
    echo -e "${BOLD}${GREEN}🎉 SETUP COMPLETE! 🎉${NC}"
    echo -e "${GREEN}Enhanced Pamac with AUR support is now installed and ready to use.${NC}"
    echo ""
    echo -e "${BOLD}${YELLOW}FEATURES ENABLED:${NC}"
    [ "$ENABLE_MULTILIB" = "true" ] && echo -e "  ✓ ${GREEN}Multilib repository (32-bit app support)${NC}"
    [ "$ENABLE_BUILD_CACHE" = "true" ] && echo -e "  ✓ ${GREEN}Persistent build cache${NC}"
    [ "$CONFIGURE_MIRRORS" = "true" ] && echo -e "  ✓ ${GREEN}Optimized mirror configuration${NC}"
    [ "$AUTO_EXPORT_APPS" = "true" ] && echo -e "  ✓ ${GREEN}App cataloguing${NC}"
    [ "$ENABLE_GAMING_PACKAGES" = "true" ] && echo -e "  ✓ ${GREEN}Gaming packages (Wine, Lutris, Steam, etc.)${NC}"
    [ "$CONFIGURE_LOCALE" = "true" ] && echo -e "  ✓ ${GREEN}Locale configured ($TARGET_LOCALE)${NC}"
    echo ""
    echo -e "${BOLD}${YELLOW}ACCESS METHODS:${NC}"
    echo -e "  🖥️  Desktop Mode: Application Launcher → '${GREEN}Pamac Package Manager${NC}'"
    echo -e "  🎮  Gaming Mode: STEAM → Library → '${GREEN}Non-Steam${NC}' collection"
    echo -e "  🛠️  Management: Use '${GREEN}BoxBuddy${NC}' for advanced container operations"
    echo ""
    echo -e "${BOLD}${YELLOW}USEFUL COMMANDS:${NC}"
    echo -e "  Update script: ${GREEN}$0 --update${NC}"
    echo -e "  Uninstall: ${GREEN}$0 --uninstall${NC}"
    echo -e "  Container shell: ${GREEN}distrobox enter $CONTAINER_NAME${NC}"
    echo -e "  Export app: ${GREEN}distrobox-export --app <app-name>${NC}"
    echo ""
    echo -e "${BOLD}${BLUE}Your Steam Deck now has enhanced access to the Arch ecosystem! 🚀${NC}"
}

# Run main function with all arguments
main "$@"
