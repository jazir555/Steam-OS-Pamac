#!/bin/bash

# Steam Deck Pamac Setup Script - Improved Version
# This script sets up a persistent, GUI-based package management system
# using Distrobox containers on SteamOS without Developer Mode

set -euo pipefail  # Stricter error handling

# --- Configuration Variables ---
readonly SCRIPT_VERSION="4.0"
readonly DEFAULT_CONTAINER_NAME="arch-pamac"
readonly LOG_FILE="$HOME/distrobox-pamac-setup.log"
readonly SCRIPT_URL="https://raw.githubusercontent.com/user/repo/main/setup-pamac.sh"
readonly REQUIRED_TOOLS=("distrobox" "podman")

# User-configurable variables
CONTAINER_NAME="${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}"
CURRENT_USER=$(whoami)

# Feature flags with improved defaults
ENABLE_MULTILIB="${ENABLE_MULTILIB:-true}"
ENABLE_BUILD_CACHE="${ENABLE_BUILD_CACHE:-true}"
CONFIGURE_MIRRORS="${CONFIGURE_MIRRORS:-true}"
AUTO_EXPORT_APPS="${AUTO_EXPORT_APPS:-true}"
ENABLE_GAMING_PACKAGES="${ENABLE_GAMING_PACKAGES:-false}"
CONFIGURE_LOCALE="${CONFIGURE_LOCALE:-false}"
TARGET_LOCALE="${TARGET_LOCALE:-en_US.UTF-8}"
MIRROR_COUNTRIES="${MIRROR_COUNTRIES:-US,Canada}"
FORCE_REBUILD="${FORCE_REBUILD:-false}"

# Operation mode flags
DRY_RUN="${DRY_RUN:-false}"
LOG_LEVEL="${LOG_LEVEL:-normal}"
CONTAINER_WAS_CREATED_BY_SCRIPT="false"

# --- Color Codes ---
setup_colors() {
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        readonly GREEN=$(tput setaf 2)
        readonly YELLOW=$(tput setaf 3)
        readonly BLUE=$(tput setaf 4)
        readonly RED=$(tput setaf 1)
        readonly BOLD=$(tput bold)
        readonly NC=$(tput sgr0)
    else
        readonly GREEN='' YELLOW='' BLUE='' RED='' BOLD='' NC=''
    fi
}

# --- Logging and Output Functions ---
initialize_logging() {
    local steamos_version
    steamos_version=$(grep VERSION_ID /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Unknown')
    
    {
        echo "=== Steam Deck Pamac Setup v${SCRIPT_VERSION} - $(date) ==="
        echo "User: $CURRENT_USER"
        echo "SteamOS Version: $steamos_version"
        echo "Container: $CONTAINER_NAME"
        echo "Features: MULTILIB=$ENABLE_MULTILIB GAMING=$ENABLE_GAMING_PACKAGES BUILD_CACHE=$ENABLE_BUILD_CACHE"
        echo "=========================================="
    } > "$LOG_FILE"
    
    trap 'echo "=== Run finished: $(date) - Exit: $? ===" >> "$LOG_FILE"' EXIT
}

_log() {
    local level="$1" color="$2" message="$3"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] $level: $message" >> "$LOG_FILE"
    
    case "$LOG_LEVEL" in
        "quiet") [[ "$level" == "ERROR" ]] && echo -e "${color}${message}${NC}" ;;
        "normal") [[ "$level" != "DEBUG" ]] && echo -e "${color}${message}${NC}" ;;
        "verbose") echo -e "${color}${message}${NC}" ;;
    esac
}

log_step() { _log "STEP" "$BLUE" "\n${BOLD}==> $1${NC}"; }
log_info() { _log "INFO" "" "$1"; }
log_success() { _log "SUCCESS" "$GREEN" "✓ $1"; }
log_warn() { _log "WARN" "$YELLOW" "⚠️  $1"; }
log_error() { _log "ERROR" "$RED" "❌ $1"; }
log_debug() { _log "DEBUG" "" "$1"; }

run_command() {
    log_debug "Executing: $*"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY RUN] Would execute: $*"
        return 0
    fi
    
    if [[ "$LOG_LEVEL" == "verbose" ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
        return "${PIPESTATUS[0]}"
    else
        "$@" >> "$LOG_FILE" 2>&1
    fi
}

# --- Validation Functions ---
validate_container_name() {
    if [[ ! "$CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        log_error "Invalid container name: $CONTAINER_NAME"
        log_info "Container names must start with alphanumeric and contain only letters, numbers, hyphens, and underscores"
        return 1
    fi
    
    if [[ ${#CONTAINER_NAME} -gt 63 ]]; then
        log_error "Container name too long (max 63 characters): $CONTAINER_NAME"
        return 1
    fi
}

check_system_requirements() {
    local missing_tools=()
    
    # Check for required tools
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "On SteamOS, install distrobox with:"
        log_info "  curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix ~/.local"
        return 1
    fi
    
    # Check disk space (need at least 2GB)
    local available_space
    available_space=$(df "$HOME" | awk 'NR==2 {print $4}')
    if [[ $available_space -lt 2097152 ]]; then  # 2GB in KB
        log_warn "Low disk space detected. At least 2GB recommended."
    fi
    
    # Verify SteamOS compatibility
    if ! grep -q "ID=steamos" /etc/os-release 2>/dev/null; then
        log_warn "Not running on SteamOS. Compatibility not guaranteed."
    fi
}

# --- Argument Parsing ---
show_usage() {
    cat << EOF
${BOLD}Steam Deck Pamac Setup v${SCRIPT_VERSION}${NC}

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --container-name NAME    Set container name (default: arch-pamac)
    --force-rebuild         Rebuild existing container
    --enable-multilib       Enable 32-bit package support
    --enable-gaming         Install gaming packages (Steam, Lutris, etc.)
    --disable-build-cache   Disable build cache volume
    --update                Update this script
    --uninstall             Remove container and exported apps
    --dry-run               Show what would be done without making changes
    --verbose               Show detailed output
    --quiet                 Only show errors and warnings
    --version               Show version information
    -h, --help              Show this help

EXAMPLES:
    $0                                    # Basic setup
    $0 --enable-gaming --enable-multilib # Gaming-focused setup
    $0 --container-name my-arch          # Custom container name
    $0 --uninstall                       # Remove everything

ENVIRONMENT VARIABLES:
    CONTAINER_NAME          Override default container name
    ENABLE_MULTILIB         Set to 'true' to enable 32-bit support
    ENABLE_GAMING_PACKAGES  Set to 'true' to install gaming packages
    ENABLE_BUILD_CACHE      Set to 'false' to disable build cache
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --container-name)
                [[ -z "${2:-}" ]] && { log_error "Container name cannot be empty"; exit 1; }
                CONTAINER_NAME="$2"
                shift 2
                ;;
            --force-rebuild)
                FORCE_REBUILD="true"
                shift
                ;;
            --enable-multilib)
                ENABLE_MULTILIB="true"
                shift
                ;;
            --enable-gaming)
                ENABLE_GAMING_PACKAGES="true"
                shift
                ;;
            --disable-build-cache)
                ENABLE_BUILD_CACHE="false"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --verbose)
                LOG_LEVEL="verbose"
                shift
                ;;
            --quiet)
                LOG_LEVEL="quiet"
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
            --version)
                echo "Steam Deck Pamac Setup v${SCRIPT_VERSION}"
                exit 0
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# --- Utility Functions ---
update_script() {
    log_step "Updating script from $SCRIPT_URL"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY RUN] Would download update"
        return
    fi
    
    local temp_file
    temp_file=$(mktemp)
    trap "rm -f '$temp_file'" RETURN
    
    local download_cmd
    if command -v curl >/dev/null 2>&1; then
        download_cmd="curl -fsSL"
    elif command -v wget >/dev/null 2>&1; then
        download_cmd="wget -qO-"
    else
        log_error "Neither curl nor wget available for update"
        return 1
    fi
    
    if $download_cmd "$SCRIPT_URL" > "$temp_file"; then
        if [[ -s "$temp_file" ]] && head -1 "$temp_file" | grep -q "^#!/bin/bash"; then
            chmod +x "$temp_file"
            mv "$temp_file" "$0"
            log_success "Script updated successfully. Please rerun."
        else
            log_error "Downloaded file appears invalid"
            return 1
        fi
    else
        log_error "Failed to download update"
        return 1
    fi
}

uninstall_setup() {
    log_step "Uninstalling Pamac setup"
    
    # Stop container if running
    if distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        log_info "Stopping and removing container: $CONTAINER_NAME"
        if [[ "$DRY_RUN" != "true" ]]; then
            distrobox stop "$CONTAINER_NAME" 2>/dev/null || true
            distrobox rm "$CONTAINER_NAME" --force || log_warn "Failed to remove container"
        fi
    else
        log_info "Container '$CONTAINER_NAME' not found"
    fi
    
    # Clean up exported applications
    if [[ -d "$HOME/.local/share/applications" ]]; then
        log_info "Cleaning up exported applications"
        if [[ "$DRY_RUN" != "true" ]]; then
            find "$HOME/.local/share/applications" -type f \
                \( -name "*pamac*${CONTAINER_NAME}*" -o \
                   -name "*${CONTAINER_NAME}*pamac*" -o \
                   -name "*distrobox*${CONTAINER_NAME}*" \) \
                -delete 2>/dev/null || true
            
            # Update desktop database
            if command -v update-desktop-database >/dev/null 2>&1; then
                update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
            fi
        fi
    fi
    
    # Clean up build cache if it exists
    if [[ -d "$HOME/.cache/yay-${CONTAINER_NAME}" ]]; then
        log_info "Removing build cache"
        [[ "$DRY_RUN" != "true" ]] && rm -rf "$HOME/.cache/yay-${CONTAINER_NAME}"
    fi
    
    log_success "Uninstallation completed"
}

wait_for_container() {
    local max_attempts=60
    local attempt=0
    
    log_info "Waiting for container to become ready..."
    
    while ! distrobox enter "$CONTAINER_NAME" -- echo "Container ready" >/dev/null 2>&1; do
        if [[ $((++attempt)) -gt $max_attempts ]]; then
            log_error "Container failed to become ready after $((max_attempts * 2)) seconds"
            return 1
        fi
        
        sleep 2
        if [[ $((attempt % 10)) -eq 0 ]]; then
            log_info "Still waiting... (${attempt}/${max_attempts})"
        fi
    done
    
    log_success "Container is ready"
}

# --- Core Setup Functions ---
create_container() {
    log_step "Creating Arch Linux container: $CONTAINER_NAME"
    
    local create_args=(
        --name "$CONTAINER_NAME"
        --image "archlinux:latest"
        --yes
    )
    
    # Add build cache volume if enabled
    if [[ "$ENABLE_BUILD_CACHE" == "true" ]]; then
        local cache_dir="$HOME/.cache/yay-${CONTAINER_NAME}"
        mkdir -p "$cache_dir"
        create_args+=(--volume "$cache_dir:/home/$CURRENT_USER/.cache/yay:rw")
        log_info "Enabled build cache: $cache_dir"
    fi
    
    if ! run_command distrobox create "${create_args[@]}"; then
        log_error "Failed to create container"
        return 1
    fi
    
    CONTAINER_WAS_CREATED_BY_SCRIPT="true"
    wait_for_container
}

configure_container_base() {
    log_step "Configuring container base environment"
    
    local setup_script
    read -r -d '' setup_script << 'EOF' || true
set -euo pipefail

echo "Setting up base environment..."

# Create wheel group if it doesn't exist
if ! getent group wheel >/dev/null 2>&1; then
    groupadd wheel
    echo "Created wheel group"
fi

# Add current user to wheel group
current_user="${SUDO_USER:-${USER:-$(whoami)}}"
if id "$current_user" >/dev/null 2>&1; then
    usermod -aG wheel "$current_user"
    echo "Added $current_user to wheel group"
else
    echo "Warning: Could not determine current user"
fi

# Configure passwordless sudo for wheel group
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel-nopasswd
chmod 0440 /etc/sudoers.d/wheel-nopasswd
echo "Configured passwordless sudo"

# Initialize pacman keyring with timeout protection
timeout 300 pacman-key --init || {
    echo "Warning: pacman-key --init timed out or failed"
}

timeout 300 pacman-key --populate archlinux || {
    echo "Warning: pacman-key --populate timed out or failed"
}

echo "Base environment setup completed"
EOF
    
    if ! echo "$setup_script" | run_command distrobox enter --root "$CONTAINER_NAME" -- bash; then
        log_error "Failed to configure container base environment"
        return 1
    fi
}

configure_multilib() {
    if [[ "$ENABLE_MULTILIB" == "true" ]]; then
        log_step "Enabling multilib support"
        
        local multilib_script
        read -r -d '' multilib_script << 'EOF' || true
set -euo pipefail

if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    echo "" >> /etc/pacman.conf
    echo "[multilib]" >> /etc/pacman.conf
    echo "Include = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
    echo "Multilib repository enabled"
else
    echo "Multilib repository already enabled"
fi

# Update package database
pacman -Sy --noconfirm
EOF
        
        if ! echo "$multilib_script" | run_command distrobox enter --root "$CONTAINER_NAME" -- bash; then
            log_warn "Failed to enable multilib support"
        fi
    fi
}

install_aur_helper() {
    log_step "Installing AUR helper (yay)"
    
    local yay_script
    read -r -d '' yay_script << 'EOF' || true
set -euo pipefail

# Update system and install base development tools
pacman -Syu --noconfirm
pacman -S --needed --noconfirm git base-devel

# Check if yay is already installed
if command -v yay >/dev/null 2>&1; then
    echo "yay is already installed"
    yay --version
    exit 0
fi

# Build and install yay as regular user
echo "Building yay AUR helper..."
cd /tmp
rm -rf yay-bin

# Clone and build yay
git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin

# Build as regular user
makepkg -si --noconfirm --clean

echo "yay installation completed"
yay --version
EOF
    
    if ! run_command distrobox enter "$CONTAINER_NAME" -- bash -c "$yay_script"; then
        log_error "Failed to install AUR helper"
        return 1
    fi
}

install_pamac() {
    log_step "Installing Pamac package manager"
    
    local pamac_script
    read -r -d '' pamac_script << 'EOF' || true
set -euo pipefail

echo "Installing pamac-aur..."
yay -S --noconfirm --needed pamac-aur

# Configure Pamac
if [[ -f /etc/pamac.conf ]]; then
    sudo sed -i 's/^#EnableAUR/EnableAUR/' /etc/pamac.conf
    sudo sed -i 's/^#CheckAURUpdates/CheckAURUpdates/' /etc/pamac.conf
    sudo sed -i 's/^#CheckAURVCSUpdates/CheckAURVCSUpdates/' /etc/pamac.conf
    echo "Pamac AUR support enabled"
else
    echo "Warning: /etc/pamac.conf not found"
fi

# Verify installation
if command -v pamac-manager >/dev/null 2>&1; then
    echo "Pamac installed successfully"
    pamac --version || true
else
    echo "Error: Pamac installation verification failed"
    exit 1
fi
EOF
    
    if ! run_command distrobox enter "$CONTAINER_NAME" -- bash -c "$pamac_script"; then
        log_error "Failed to install Pamac"
        return 1
    fi
}

setup_cleanup_hooks() {
    log_step "Setting up cleanup hooks"
    
    local hook_script
    read -r -d '' hook_script << 'EOF' || true
set -euo pipefail

echo "Setting up pacman hooks for desktop entry cleanup..."

# Create hooks directory
mkdir -p /etc/pacman.d/hooks

# Create cleanup script
cat > /usr/local/bin/cleanup-desktop-entries.sh << 'CLEANUP_SCRIPT'
#!/bin/bash
# Cleanup exported desktop entries when packages are removed

set -euo pipefail

# Determine user home directory
USER_HOME=""
for user in deck "$SUDO_USER" "$USER" "$(logname 2>/dev/null || true)"; do
    if [[ -n "$user" ]] && id "$user" >/dev/null 2>&1; then
        USER_HOME="$(getent passwd "$user" | cut -d: -f6)"
        break
    fi
done

if [[ -z "$USER_HOME" ]] || [[ ! -d "$USER_HOME" ]]; then
    echo "Warning: Could not determine user home directory"
    exit 0
fi

# Process removed packages
while IFS= read -r pkg_name; do
    if [[ -n "$pkg_name" ]]; then
        echo "Cleaning up desktop entries for: $pkg_name"
        
        # Find and remove related desktop files
        find "$USER_HOME/.local/share/applications" -type f -name "*.desktop" \
            -exec grep -l "$pkg_name" {} \; 2>/dev/null | \
            xargs rm -f 2>/dev/null || true
    fi
done

# Update desktop database
if [[ -d "$USER_HOME/.local/share/applications" ]] && command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$USER_HOME/.local/share/applications" 2>/dev/null || true
fi
CLEANUP_SCRIPT

chmod +x /usr/local/bin/cleanup-desktop-entries.sh

# Create pacman hook
cat > /etc/pacman.d/hooks/cleanup-desktop-entries.hook << 'HOOK_CONFIG'
[Trigger]
Operation = Remove
Type = Package
Target = *

[Action]
Description = Cleaning up exported desktop entries
When = PostTransaction
Exec = /usr/local/bin/cleanup-desktop-entries.sh
NeedsTargets
HOOK_CONFIG

echo "Cleanup hooks configured successfully"
EOF
    
    if ! echo "$hook_script" | run_command distrobox enter --root "$CONTAINER_NAME" -- bash; then
        log_warn "Failed to setup cleanup hooks (non-critical)"
    fi
}

install_gaming_packages() {
    if [[ "$ENABLE_GAMING_PACKAGES" == "true" ]]; then
        log_step "Installing gaming packages"
        
        local gaming_script
        read -r -d '' gaming_script << 'EOF' || true
set -euo pipefail

echo "Installing gaming-related packages..."

# Core gaming packages
gaming_packages=(
    "steam"
    "lutris"
    "wine-staging"
    "winetricks"
    "gamemode"
    "lib32-gamemode"
    "mangohud"
    "lib32-mangohud"
)

# Install packages one by one to handle failures gracefully
failed_packages=()
for package in "${gaming_packages[@]}"; do
    echo "Installing $package..."
    if ! yay -S --noconfirm --needed "$package"; then
        echo "Failed to install $package"
        failed_packages+=("$package")
    fi
done

if [[ ${#failed_packages[@]} -gt 0 ]]; then
    echo "Warning: Failed to install some packages: ${failed_packages[*]}"
else
    echo "All gaming packages installed successfully"
fi
EOF
        
        if ! run_command distrobox enter "$CONTAINER_NAME" -- bash -c "$gaming_script"; then
            log_warn "Some gaming packages may have failed to install"
        fi
    fi
}

export_pamac_to_host() {
    log_step "Exporting Pamac to host system"
    
    # Try distrobox-export first
    if run_command distrobox-export --app pamac-manager --extra-flags "--no-sandbox" from "$CONTAINER_NAME" ; then
        log_success "Pamac exported successfully via distrobox-export"
    else
        log_warn "Standard export failed, creating manual launcher"
        
        # Create manual desktop entry
        local desktop_dir="$HOME/.local/share/applications"
        mkdir -p "$desktop_dir"
        
        local desktop_file="$desktop_dir/pamac-manager-${CONTAINER_NAME}.desktop"
        cat > "$desktop_file" << EOF
[Desktop Entry]
Name=Pamac Manager (${CONTAINER_NAME})
Comment=Add or remove software packages
Exec=distrobox enter ${CONTAINER_NAME} -- pamac-manager --no-sandbox
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;Settings;PackageManager;
Keywords=package;manager;install;remove;update;software;
StartupNotify=true
X-Distrobox-App=true
EOF
        
        chmod +x "$desktop_file"
        log_success "Created manual desktop launcher: $desktop_file"
    fi
    
    # Update desktop database
    if command -v update-desktop-database >/dev/null 2>&1; then
        run_command update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    fi
    
    # Also create a command-line shortcut
    local bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"
    
    cat > "$bin_dir/pamac-${CONTAINER_NAME}" << EOF
#!/bin/bash
# Pamac CLI wrapper for ${CONTAINER_NAME} container
exec distrobox enter ${CONTAINER_NAME} -- pamac "\$@"
EOF
    
    chmod +x "$bin_dir/pamac-${CONTAINER_NAME}"
    log_info "Created CLI wrapper: $bin_dir/pamac-${CONTAINER_NAME}"
}

show_completion_message() {
    echo
    log_success "Steam Deck Pamac Setup completed successfully!"
    echo
    echo -e "${BOLD}${BLUE}What's installed:${NC}"
    echo "  • Arch Linux container: $CONTAINER_NAME"
    echo "  • Pamac package manager with AUR support"
    echo "  • yay AUR helper"
    [[ "$ENABLE_MULTILIB" == "true" ]] && echo "  • 32-bit package support (multilib)"
    [[ "$ENABLE_GAMING_PACKAGES" == "true" ]] && echo "  • Gaming packages (Steam, Lutris, Wine, etc.)"
    [[ "$ENABLE_BUILD_CACHE" == "true" ]] && echo "  • Persistent build cache"
    echo
    echo -e "${BOLD}${GREEN}How to use:${NC}"
    echo "  • Find 'Pamac Manager' in your application menu"
    echo "  • Or run: distrobox enter $CONTAINER_NAME"
    echo "  • Command line: pamac-${CONTAINER_NAME} [options]"
    echo
    echo -e "${BOLD}${YELLOW}Additional info:${NC}"
    echo "  • Container persists across reboots"
    echo "  • Installed apps will appear in your menu"
    echo "  • To uninstall: $0 --uninstall"
    echo "  • Detailed logs: $LOG_FILE"
    echo
}

# --- Main Function ---
main() {
    setup_colors
    initialize_logging
    parse_arguments "$@"
    
    # Validate inputs
    validate_container_name
    check_system_requirements
    
    # Show configuration
    echo -e "${BOLD}${BLUE}Steam Deck Pamac Setup v${SCRIPT_VERSION}${NC}"
    [[ "$DRY_RUN" == "true" ]] && echo -e "${YELLOW}DRY RUN MODE: No changes will be made${NC}"
    echo
    
    # Handle force rebuild
    if [[ "$FORCE_REBUILD" == "true" ]] && distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        log_step "Force rebuilding container"
        if [[ "$DRY_RUN" != "true" ]]; then
            distrobox stop "$CONTAINER_NAME" 2>/dev/null || true
            distrobox rm "$CONTAINER_NAME" --force
        fi
    fi
    
    # Create or verify container
    if ! distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        create_container
    else
        log_success "Using existing container: $CONTAINER_NAME"
        wait_for_container
    fi
    
    # Configure container
    configure_container_base
    configure_multilib
    
    # Install software
    install_aur_helper
    install_pamac
    setup_cleanup_hooks
    install_gaming_packages
    
    # Export to host
    export_pamac_to_host
    
    # Show completion message
    show_completion_message
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
