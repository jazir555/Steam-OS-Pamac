#!/bin/bash

# Steam Deck Pamac Setup Script - Improved Version
# This script sets up a persistent, GUI-based package management system
# using Distrobox containers on SteamOS without Developer Mode

set -euo pipefail  # Stricter error handling

# --- Configuration Variables ---
readonly SCRIPT_VERSION="4.2" # Version incremented
readonly SCRIPT_URL="https://raw.githubusercontent.com/user/repo/main/setup-pamac.sh"
readonly REQUIRED_TOOLS=("distrobox" "podman")
readonly DEFAULT_CONTAINER_NAME="arch-pamac"
readonly LOG_FILE="$HOME/distrobox-pamac-setup.log"

# User-configurable variables
CONTAINER_NAME="${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}"
CURRENT_USER=$(whoami)

# Feature flags with improved defaults
ENABLE_MULTILIB="${ENABLE_MULTILIB:-true}"
ENABLE_BUILD_CACHE="${ENABLE_BUILD_CACHE:-true}"
ENABLE_GAMING_PACKAGES="${ENABLE_GAMING_PACKAGES:-false}"
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
    
    # Overwrite log file at the start of a new run
    {
        echo "=== Steam Deck Pamac Setup v${SCRIPT_VERSION} - $(date) ==="
        echo "User: $CURRENT_USER"
        echo "SteamOS Version: $steamos_version"
        echo "Container: $CONTAINER_NAME"
        echo "Features: MULTILIB=$ENABLE_MULTILIB GAMING=$ENABLE_GAMING_PACKAGES BUILD_CACHE=$ENABLE_BUILD_CACHE"
        echo "=========================================="
    } > "$LOG_FILE"
    
    # Append footer on exit
    trap 'echo "=== Run finished: $(date) - Exit: $? ===" >> "$LOG_FILE"' EXIT
}

_log() {
    local level="$1" color="$2" message="$3"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
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
        # The trailing '|| true' prevents the script from exiting if the pipe fails (e.g., on tee error)
        # while still capturing the correct exit code with PIPESTATUS.
        "$@" 2>&1 | tee -a "$LOG_FILE" || true
        return "${PIPESTATUS[0]}"
    else
        "$@" >> "$LOG_FILE" 2>&1
    fi
}

# --- Validation Functions ---
validate_container_name() {
    if [[ ! "$CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        log_error "Invalid container name: $CONTAINER_NAME"
        log_info "Container names must start with an alphanumeric character and contain only letters, numbers, hyphens, and underscores."
        exit 1
    fi
    
    if [[ ${#CONTAINER_NAME} -gt 63 ]]; then
        log_error "Container name too long (max 63 characters): $CONTAINER_NAME"
        exit 1
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
        exit 1
    fi
    
    # Check disk space (need at least 2GB)
    local available_space
    available_space=$(df --output=avail -k "$HOME" | awk 'NR==2')
    if [[ $available_space -lt 2097152 ]]; then  # 2GB in KB
        log_warn "Low disk space detected. At least 2GB is recommended."
    fi
    
    # Verify SteamOS compatibility
    if ! grep -q "ID=steamos" /etc/os-release 2>/dev/null; then
        log_warn "Not running on SteamOS. Compatibility is not guaranteed."
    fi
}

# --- Argument Parsing ---
show_usage() {
    cat << EOF
${BOLD}Steam Deck Pamac Setup v${SCRIPT_VERSION}${NC}

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --container-name NAME    Set container name (default: ${DEFAULT_CONTAINER_NAME})
    --force-rebuild          Rebuild existing container if it exists
    --enable-multilib        Enable 32-bit package support (default: on)
    --enable-gaming          Install gaming packages (Steam, Lutris, etc.)
    --disable-build-cache    Disable persistent build cache for yay
    --update                 Update this script to the latest version
    --uninstall              Remove container and all related files
    --dry-run                Show what would be done without making changes
    --verbose                Show detailed output, including command logs
    --quiet                  Only show errors
    --version                Show version information
    -h, --help               Show this help message

EXAMPLES:
    $0                                    # Basic setup
    $0 --enable-gaming --enable-multilib  # Gaming-focused setup
    $0 --container-name my-arch           # Use a custom container name
    $0 --uninstall                        # Remove everything created by this script

ENVIRONMENT VARIABLES:
    CONTAINER_NAME          Overrides the default container name
    ENABLE_MULTILIB         Set to 'true' or 'false'
    ENABLE_GAMING_PACKAGES  Set to 'true' or 'false'
    ENABLE_BUILD_CACHE      Set to 'true' or 'false'
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
    # Use an EXIT trap to ensure cleanup even on script failure
    trap 'rm -f "$temp_file"' EXIT
    
    local download_cmd
    if command -v curl >/dev/null 2>&1; then
        # -f: fail silently on server errors, -s: silent, -S: show error, -L: follow redirects
        download_cmd="curl -fsSL"
    elif command -v wget >/dev/null 2>&1; then
        download_cmd="wget -qO-"
    else
        log_error "Neither curl nor wget is available for updating."
        exit 1
    fi
    
    if $download_cmd "$SCRIPT_URL" > "$temp_file"; then
        if [[ -s "$temp_file" ]] && head -1 "$temp_file" | grep -q "^#!/bin/bash"; then
            # The original script path is in $0
            chmod +x "$temp_file"
            mv -f "$temp_file" "$0"
            log_success "Script updated successfully. Please run the new version again."
            # The trap will clean up temp_file if mv fails
        else
            log_error "Downloaded file appears to be invalid or empty."
            exit 1
        fi
    else
        log_error "Failed to download update from the server."
        exit 1
    fi
}

uninstall_setup() {
    log_step "Uninstalling Pamac setup for container: $CONTAINER_NAME"
    
    # Stop and remove the container
    if distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        log_info "Stopping and removing container: $CONTAINER_NAME"
        if [[ "$DRY_RUN" != "true" ]]; then
            # Use --yes to avoid interactive prompts
            distrobox stop "$CONTAINER_NAME" --yes 2>/dev/null || true
            distrobox rm "$CONTAINER_NAME" --force || log_warn "Failed to remove container. It may have already been removed."
        fi
    else
        log_info "Container '$CONTAINER_NAME' not found, skipping."
    fi
    
    # Clean up exported applications
    local app_dir="$HOME/.local/share/applications"
    if [[ -d "$app_dir" ]]; then
        log_info "Cleaning up exported application launchers (.desktop files)"
        if [[ "$DRY_RUN" != "true" ]]; then
            # Reliably find files created by `distrobox-export` or our manual fallback,
            # which consistently append `-${CONTAINER_NAME}` to the filename.
            find "$app_dir" -type f -name "*-${CONTAINER_NAME}.desktop" -delete 2>/dev/null || true
            
            # As a safety net, also find any files that explicitly execute this container
            # The `|| true` prevents errors if no files are found by grep
            grep -l "distrobox enter ${CONTAINER_NAME}" "$app_dir"/*.desktop 2>/dev/null | xargs -r rm -f 2>/dev/null || true
            
            # Update desktop database
            if command -v update-desktop-database >/dev/null 2>&1; then
                update-desktop-database "$app_dir" 2>/dev/null || true
            fi
        else
             log_warn "[DRY RUN] Would search for and delete .desktop files in $app_dir"
        fi
    fi
    
    # Clean up build cache if it exists
    local cache_dir="$HOME/.cache/yay-${CONTAINER_NAME}"
    if [[ -d "$cache_dir" ]]; then
        log_info "Removing build cache at $cache_dir"
        [[ "$DRY_RUN" != "true" ]] && rm -rf "$cache_dir"
    fi

    # Clean up CLI wrapper
    local bin_file="$HOME/.local/bin/pamac-${CONTAINER_NAME}"
    if [[ -f "$bin_file" ]]; then
        log_info "Removing CLI wrapper at $bin_file"
        [[ "$DRY_RUN" != "true" ]] && rm -f "$bin_file"
    fi
    
    log_success "Uninstallation completed."
}

wait_for_container() {
    local max_attempts=60
    local attempt=0
    
    log_info "Waiting for container '$CONTAINER_NAME' to become ready..."
    
    while ! distrobox enter "$CONTAINER_NAME" -- true >/dev/null 2>&1; do
        if [[ $((++attempt)) -gt $max_attempts ]]; then
            log_error "Container failed to become ready after $((max_attempts * 2)) seconds."
            log_info "Check container logs with: podman logs $CONTAINER_NAME"
            return 1
        fi
        
        sleep 2
        if [[ $((attempt % 10)) -eq 0 ]]; then
            log_info "Still waiting... (${attempt}/${max_attempts})"
        fi
    done
    
    log_success "Container is ready."
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
        log_info "Enabled persistent build cache: $cache_dir"
    fi
    
    if ! run_command distrobox create "${create_args[@]}"; then
        log_error "Failed to create Distrobox container."
        return 1
    fi
    
    CONTAINER_WAS_CREATED_BY_SCRIPT="true"
    wait_for_container || return 1
}

configure_container_base() {
    log_step "Configuring container base environment (sudo, keyring)"
    
    local setup_script
    # Quoted 'EOF' prevents variable expansion on the host
    read -r -d '' setup_script << 'EOF' || true
set -euo pipefail

echo "Setting up base environment inside container..."

# Create wheel group if it doesn't exist
if ! getent group wheel >/dev/null 2>&1; then
    groupadd wheel
    echo "Created 'wheel' group."
fi

# Add current user to wheel group to allow sudo. Sudo is installed by distrobox by default.
current_user="${SUDO_USER:-${USER:-$(whoami)}}"
if id "$current_user" >/dev/null 2>&1; then
    usermod -aG wheel "$current_user"
    echo "Added user '$current_user' to 'wheel' group."
else
    echo "Warning: Could not determine current user to add to wheel group."
fi

# Configure passwordless sudo for the wheel group
echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-wheel-nopasswd
chmod 0440 /etc/sudoers.d/99-wheel-nopasswd
echo "Configured passwordless sudo for 'wheel' group."

# Initialize pacman keyring with timeout protection to prevent hangs
echo "Initializing pacman keyring..."
timeout 300 pacman-key --init || {
    echo "Warning: 'pacman-key --init' timed out or failed. This can happen due to low entropy. Trying to continue."
}

timeout 300 pacman-key --populate archlinux || {
    echo "Warning: 'pacman-key --populate' timed out or failed. Package signature checks might fail."
}

echo "Base environment setup complete."
EOF
    
    if ! echo "$setup_script" | run_command distrobox enter --root "$CONTAINER_NAME" -- bash; then
        log_error "Failed to configure container base environment."
        return 1
    fi
}

configure_multilib() {
    if [[ "$ENABLE_MULTILIB" == "true" ]]; then
        log_step "Enabling multilib (32-bit) support"
        
        local multilib_script
        read -r -d '' multilib_script << 'EOF' || true
set -euo pipefail

if ! grep -q "^\s*\[multilib\]" /etc/pacman.conf; then
    echo "Enabling multilib repository in /etc/pacman.conf..."
    # Using tee for privilege escalation within the script
    echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" | tee -a /etc/pacman.conf > /dev/null
    echo "Multilib repository enabled."
else
    echo "Multilib repository is already enabled."
fi

# Update package database to include multilib
echo "Updating package database..."
pacman -Sy --noconfirm
EOF
        
        if ! echo "$multilib_script" | run_command distrobox enter --root "$CONTAINER_NAME" -- bash; then
            log_warn "Failed to enable multilib support. 32-bit packages may not install."
        fi
    fi
}

install_aur_helper() {
    log_step "Installing AUR helper (yay)"
    
    local yay_script
    read -r -d '' yay_script << 'EOF' || true
set -euo pipefail

# Added 'sudo' to pacman commands, as this script runs as the user.
# The user was previously added to the wheel group with passwordless sudo.
echo "Updating system and installing build tools..."
sudo pacman -Syu --noconfirm --needed git base-devel

# Check if yay is already installed
if command -v yay >/dev/null 2>&1; then
    echo "yay is already installed."
    yay --version
    exit 0
fi

# Build and install yay as the regular user
echo "Cloning and building 'yay-bin' AUR helper..."
cd /tmp
rm -rf yay-bin
git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin

# Build and install. makepkg will use sudo internally to install the package.
makepkg -si --noconfirm --clean
echo "'yay' installation completed."
yay --version
EOF
    
    if ! run_command distrobox enter "$CONTAINER_NAME" -- bash -c "$yay_script"; then
        log_error "Failed to install AUR helper (yay)."
        return 1
    fi
}

install_pamac() {
    log_step "Installing Pamac package manager"
    
    local pamac_script
    read -r -d '' pamac_script << 'EOF' || true
set -euo pipefail

echo "Installing 'pamac-aur' using yay..."
# --answeredit n allows skipping interactive questions
yay -S --noconfirm --needed --answeredit n pamac-aur

# Configure Pamac to enable AUR support by default
if [[ -f /etc/pamac.conf ]]; then
    echo "Enabling AUR support in Pamac config..."
    sudo sed -i 's/^#EnableAUR/EnableAUR/' /etc/pamac.conf
    sudo sed -i 's/^#CheckAURUpdates/CheckAURUpdates/' /etc/pamac.conf
    sudo sed -i 's/^#CheckAURVCSUpdates/CheckAURVCSUpdates/' /etc/pamac.conf
    echo "Pamac configuration updated."
else
    echo "Warning: /etc/pamac.conf not found. Cannot auto-enable AUR."
fi

# Verify installation
if command -v pamac-manager >/dev/null 2>&1; then
    echo "Pamac installed successfully."
    pamac --version || true
else
    echo "Error: Pamac installation could not be verified."
    exit 1
fi
EOF
    
    if ! run_command distrobox enter "$CONTAINER_NAME" -- bash -c "$pamac_script"; then
        log_error "Failed to install Pamac."
        return 1
    fi
}

setup_cleanup_hooks() {
    log_step "Setting up cleanup hooks (experimental)"
    
    local hook_script
    # Unquoted EOF allows host variable expansion for ${CONTAINER_NAME}
    # while internal variables are escaped with \$.
    read -r -d '' hook_script << EOF || true
set -euo pipefail
# This hook attempts to clean up exported .desktop files when a package is removed via pacman.
# NOTE: This is a best-effort approach and may not cover all edge cases.

echo "Setting up pacman hooks for desktop entry cleanup..."
mkdir -p /etc/pacman.d/hooks

# Create the script that the hook will call
cat > /usr/local/bin/cleanup-exported-desktop-entries.sh << 'CLEANUP_SCRIPT'
#!/bin/bash
set -euo pipefail

# This script is run by pacman inside the container. It needs to find the user's
# home directory on the HOST, which is mounted inside the container.
USER_HOME=""
# On Steam Deck, the user is 'deck'
for user in deck "\$SUDO_USER" "\$USER" "\$(logname 2>/dev/null || true)"; do
    if [[ -n "\$user" ]]; then
        user_home_candidate=\$(getent passwd "\$user" | cut -d: -f6)
        if [[ -d "\$user_home_candidate" ]]; then
            USER_HOME="\$user_home_candidate"
            break
        fi
    fi
done

if [[ -z "\$USER_HOME" ]]; then
    echo "Hook Warning: Could not determine user home directory. Cannot clean up desktop files." >&2
    exit 0
fi

HOST_APP_DIR="\$USER_HOME/.local/share/applications"
if [[ ! -d "\$HOST_APP_DIR" ]]; then
    exit 0
fi

# The container name is passed as the first argument to the script
CONTAINER_NAME="\${1:-}"
if [[ -z "\$CONTAINER_NAME" ]]; then
    echo "Hook Warning: Container name not provided. Cannot clean up desktop files." >&2
    exit 0
fi

# Read removed package names from stdin
while IFS= read -r pkg_name; do
    if [[ -z "\$pkg_name" ]]; then continue; fi

    # Find .desktop files installed by this package
    pkg_desktop_files=\$(pacman -Ql "\$pkg_name" | awk '/\\/usr\\/share\\/applications\\/.*\\.desktop\$/ {print \$2}')

    for desktop_file in \$pkg_desktop_files; do
        app_name=\$(basename "\$desktop_file" .desktop)
        # The exported file is typically named app-name-container-name.desktop
        exported_file="\${HOST_APP_DIR}/\${app_name}-\${CONTAINER_NAME}.desktop"
        if [[ -f "\$exported_file" ]]; then
            echo "Hook: Removing exported launcher: \$exported_file"
            rm -f "\$exported_file"
        fi
    done
done

# Update the host's desktop database if the command exists
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "\$HOST_APP_DIR" 2>/dev/null || true
fi
CLEANUP_SCRIPT

chmod +x /usr/local/bin/cleanup-exported-desktop-entries.sh

# Create pacman hook to trigger the script
cat > /etc/pacman.d/hooks/99-distrobox-cleanup.hook << HOOK_CONFIG
[Trigger]
Operation = Remove
Type = Package
Target = *

[Action]
Description = Cleaning up exported desktop entries...
When = PostTransaction
Exec = /usr/local/bin/cleanup-exported-desktop-entries.sh ${CONTAINER_NAME}
NeedsTargets
HOOK_CONFIG

echo "Cleanup hooks configured."
EOF
    
    if ! echo "$hook_script" | run_command distrobox enter --root "$CONTAINER_NAME" -- bash; then
        log_warn "Failed to set up cleanup hooks (non-critical)."
    fi
}

install_gaming_packages() {
    if [[ "$ENABLE_GAMING_PACKAGES" == "true" ]]; then
        log_step "Installing optional gaming packages"
        
        local gaming_script
        # Unquoted EOF allows host-side expansion of ${ENABLE_MULTILIB}
        # while internal variables for the container shell are escaped with \$.
        read -r -d '' gaming_script << EOF || true
set -euo pipefail

echo "Installing gaming-related packages..."

gaming_packages=(
    "steam"
    "lutris"
    "wine-staging"
    "winetricks"
    "gamemode"
    "mangohud"
)

# Conditionally add 32-bit packages only if multilib is enabled
if [[ "${ENABLE_MULTILIB}" == "true" ]]; then
    echo "Multilib is enabled, adding 32-bit gaming libraries..."
    gaming_packages+=(
        "lib32-gamemode"
        "lib32-mangohud"
    )
fi

failed_packages=()
for package in "\${gaming_packages[@]}"; do
    echo "Installing \$package..."
    if ! yay -S --noconfirm --needed --answeredit n "\$package"; then
        echo "Warning: Failed to install \$package"
        failed_packages+=("\$package")
    fi
done

if [[ \${#failed_packages[@]} -gt 0 ]]; then
    echo "Warning: Failed to install one or more packages: \${failed_packages[*]}"
else
    echo "All selected gaming packages installed successfully."
fi
EOF
        
        if ! run_command distrobox enter "$CONTAINER_NAME" -- bash -c "$gaming_script"; then
            log_warn "Some gaming packages may have failed to install."
        fi
    fi
}

export_pamac_to_host() {
    log_step "Exporting Pamac to the host application menu"
    
    # Correctly run `distrobox-export` from *inside* the container, which is its intended usage.
    log_info "Attempting to export using 'distrobox-export'..."
    if run_command distrobox enter "$CONTAINER_NAME" -- distrobox-export --app pamac-manager --extra-flags "--no-sandbox"; then
        log_success "Pamac exported successfully to the application menu."
    else
        log_warn "'distrobox-export' failed. Creating a manual launcher as a fallback."
        
        # Create a manual .desktop file if the primary method fails
        local desktop_dir="$HOME/.local/share/applications"
        mkdir -p "$desktop_dir"
        
        local desktop_file="$desktop_dir/pamac-manager-${CONTAINER_NAME}.desktop"
        cat > "$desktop_file" << EOF
[Desktop Entry]
Name=Pamac Manager (${CONTAINER_NAME})
Comment=Add/Remove Software from the Arch container
Exec=distrobox enter ${CONTAINER_NAME} -- /usr/bin/pamac-manager --no-sandbox
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;Settings;PackageManager;
Keywords=package;manager;install;remove;update;software;arch;
StartupNotify=true
X-Distrobox-App=pamac-manager
X-Distrobox-Container=${CONTAINER_NAME}
EOF
        
        chmod +x "$desktop_file"
        log_success "Created manual desktop launcher: $desktop_file"
    fi
    
    # Update the host's desktop database to make the new icon appear
    if command -v update-desktop-database >/dev/null 2>&1; then
        run_command update-desktop-database "$HOME/.local/share/applications"
    fi
    
    # Also create a convenient command-line shortcut
    local bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"
    local cli_wrapper="$bin_dir/pamac-${CONTAINER_NAME}"
    
    cat > "$cli_wrapper" << EOF
#!/bin/bash
# Pamac CLI wrapper for the '${CONTAINER_NAME}' container
# Usage: pamac-${CONTAINER_NAME} [search|install|remove|update] <args>
exec distrobox enter "${CONTAINER_NAME}" -- pamac "\$@"
EOF
    
    chmod +x "$cli_wrapper"
    log_info "Created a command-line wrapper: $cli_wrapper"
    log_info "Ensure '$bin_dir' is in your PATH to use it directly."
}

show_completion_message() {
    echo
    log_success "Steam Deck Pamac Setup completed!"
    echo
    echo -e "${BOLD}${BLUE}--- Summary ---${NC}"
    echo "  • Arch Linux container created: ${BOLD}$CONTAINER_NAME${NC}"
    echo "  • Pamac GUI package manager installed and configured."
    echo "  • 'yay' command-line AUR helper is available inside the container."
    [[ "$ENABLE_MULTILIB" == "true" ]] && echo "  • 32-bit (multilib) support is ${BOLD}enabled${NC}."
    [[ "$ENABLE_GAMING_PACKAGES" == "true" ]] && echo "  • Gaming packages (Steam, Lutris, etc.) are ${BOLD}installed${NC}."
    [[ "$ENABLE_BUILD_CACHE" == "true" ]] && echo "  • Persistent build cache is ${BOLD}enabled${NC} at ~/.cache/yay-${CONTAINER_NAME}"
    echo
    echo -e "${BOLD}${GREEN}--- How to Use ---${NC}"
    echo "  • Find '${BOLD}Pamac Manager (${CONTAINER_NAME})${NC}' in your SteamOS application menu (under 'All Apps')."
    echo "  • To use the command line, run: ${BOLD}distrobox enter $CONTAINER_NAME${NC}"
    echo "  • A CLI shortcut is also available: ${BOLD}pamac-${CONTAINER_NAME} <command>${NC} (e.g., 'pamac-${CONTAINER_NAME} search firefox')"
    echo
    echo -e "${BOLD}${YELLOW}--- Important Notes ---${NC}"
    echo "  • Your container and installed applications will persist across reboots."
    echo "  • To uninstall everything, run this script with the ${BOLD}--uninstall${NC} flag."
    echo "  • A detailed log of this installation is saved at: ${BOLD}$LOG_FILE${NC}"
    echo
}

# --- Main Function ---
main() {
    setup_colors
    
    # Moved argument parsing to the beginning so that user-provided flags
    # (like --container-name or --quiet) are processed before any setup steps.
    parse_arguments "$@"
    
    # Initialize logging after parsing args to respect --quiet/--verbose
    initialize_logging

    # Validate inputs after they have been parsed
    validate_container_name || exit 1
    check_system_requirements || exit 1
    
    echo -e "${BOLD}${BLUE}Starting Steam Deck Pamac Setup v${SCRIPT_VERSION}${NC}"
    [[ "$DRY_RUN" == "true" ]] && echo -e "${BOLD}${YELLOW}DRY RUN MODE: No changes will be made.${NC}"
    echo
    
    # Handle force rebuild
    if [[ "$FORCE_REBUILD" == "true" ]] && distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        log_step "Force-rebuild is enabled. Removing existing container first."
        # Use the dedicated uninstall function to ensure a clean removal
        uninstall_setup
    fi
    
    # Create or verify container
    if ! distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        create_container || exit 1
    else
        log_success "Using existing container: $CONTAINER_NAME"
        wait_for_container || exit 1
    fi
    
    # Configure container environment
    configure_container_base || exit 1
    configure_multilib
    
    # Install core software
    install_aur_helper || exit 1
    install_pamac || exit 1
    
    # Install optional software and configurations
    install_gaming_packages
    setup_cleanup_hooks
    
    # Integrate with host system
    export_pamac_to_host
    
    # Show completion message
    show_completion_message
}

# Script entry point: ensures the script is not executed when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Pass all script arguments to the main function
    main "$@"
fi
