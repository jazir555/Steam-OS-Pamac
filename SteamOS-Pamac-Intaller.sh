#!/bin/bash

# Steam Deck Pamac Setup Script - Improved Version
# This script sets up a persistent, GUI-based package management system
# using Distrobox containers on SteamOS without Developer Mode

set -euo pipefail  # Stricter error handling

# --- Configuration Variables ---
readonly SCRIPT_VERSION="4.3.1" # Version incremented
readonly SCRIPT_URL="https://raw.githubusercontent.com/user/repo/main/setup-pamac.sh" # Assumed URL
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
OPTIMIZE_MIRRORS="${OPTIMIZE_MIRRORS:-true}"

# Operation mode flags
DRY_RUN="${DRY_RUN:-false}"
CHECK_ONLY="${CHECK_ONLY:-false}"
LOG_LEVEL="${LOG_LEVEL:-normal}"

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

    local dry_run_header=""
    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run_header=" (DRY RUN MODE)"
    fi

    # Overwrite log file at the start of a new run
    {
        echo "=== Steam Deck Pamac Setup v${SCRIPT_VERSION}${dry_run_header} - $(date) ==="
        echo "User: $CURRENT_USER"
        echo "SteamOS Version: $steamos_version"
        echo "Container: $CONTAINER_NAME"
        echo "Features: MULTILIB=$ENABLE_MULTILIB GAMING=$ENABLE_GAMING_PACKAGES BUILD_CACHE=$ENABLE_BUILD_CACHE OPTIMIZE_MIRRORS=$OPTIMIZE_MIRRORS"
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

# FIX: The original run_command function did not correctly handle exit codes in
# non-verbose mode when 'set -e' was active. This version reliably captures
# the exit code of the executed command in all modes.
run_command() {
    log_debug "Executing: $*"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY RUN] Would execute: $*"
        return 0
    fi

    local status=0
    if [[ "$LOG_LEVEL" == "verbose" ]]; then
        # When 'set -e' is active, a failing command in a pipeline would exit the script.
        # The '|| true' prevents this line from triggering an exit. We then capture the
        # true exit code from the executed command (the first in the pipeline) using PIPESTATUS.
        "$@" 2>&1 | tee -a "$LOG_FILE" || true
        status="${PIPESTATUS[0]}"
    else
        # In non-verbose mode, we also need to prevent 'set -e' from exiting on failure
        # so that the calling function can handle the error. The '|| status=$?' idiom
        # captures the exit code without terminating the script.
        "$@" >> "$LOG_FILE" 2>&1 || status=$?
    fi
    return "$status"
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
    log_step "Checking system requirements..."
    local missing_tools=()
    local all_ok=true

    # Check for required tools
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
            all_ok=false
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "On SteamOS, install distrobox with:"
        log_info "  curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix ~/.local"
    else
        log_success "All required tools are present: ${REQUIRED_TOOLS[*]}"
    fi

    # Check disk space (need at least 2GB)
    local available_space
    available_space=$(df --output=avail -k "$HOME" | awk 'NR==2')
    if [[ $available_space -lt 2097152 ]]; then  # 2GB in KB
        log_warn "Low disk space detected. At least 2GB is recommended."
        all_ok=false
    else
        log_success "Sufficient disk space available."
    fi

    # Verify SteamOS compatibility
    if ! grep -q "ID=steamos" /etc/os-release 2>/dev/null; then
        log_warn "Not running on SteamOS. Compatibility is not guaranteed."
    else
        log_success "SteamOS detected."
    fi

    if [[ "$all_ok" == "false" ]]; then
        return 1
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
    --enable-multilib        Enable 32-bit package support (default)
    --disable-multilib       Explicitly disable 32-bit package support
    --enable-gaming          Install extra gaming packages (Steam, Lutris, etc.)
    --disable-gaming         Do not install gaming packages (default)
    --enable-build-cache     Enable persistent build cache for yay (default)
    --disable-build-cache    Disable persistent build cache for yay
    --optimize-mirrors       Select fastest Pacman mirrors (default)
    --no-optimize-mirrors    Do not change default Pacman mirrors
    --update                 Update this script to the latest version.
                             (Requires write access to the script file)
    --uninstall              Remove container and all related files
    --check                  Perform system checks and exit without installing
    --dry-run                Show what would be done without making changes
    --verbose                Show detailed output, including command logs
    --quiet                  Only show errors
    --version                Show version information
    -h, --help               Show this help message

EXAMPLES:
    $0                                    # Basic setup
    $0 --enable-gaming --no-optimize-mirrors # Gaming setup, skipping mirror optimization
    $0 --container-name my-arch           # Use a custom container name
    $0 --check                            # Verify system is ready for installation
    $0 --uninstall                        # Remove everything created by this script

ENVIRONMENT VARIABLES:
    CONTAINER_NAME          Overrides the default container name
    ENABLE_MULTILIB         Set to 'true' or 'false'
    ENABLE_GAMING_PACKAGES  Set to 'true' or 'false'
    ENABLE_BUILD_CACHE      Set to 'true' or 'false'
    OPTIMIZE_MIRRORS        Set to 'true' or 'false'
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
            --disable-multilib)
                ENABLE_MULTILIB="false"
                shift
                ;;
            --enable-gaming)
                ENABLE_GAMING_PACKAGES="true"
                shift
                ;;
            --disable-gaming)
                ENABLE_GAMING_PACKAGES="false"
                shift
                ;;
            --enable-build-cache)
                ENABLE_BUILD_CACHE="true"
                shift
                ;;
            --disable-build-cache)
                ENABLE_BUILD_CACHE="false"
                shift
                ;;
            --optimize-mirrors)
                OPTIMIZE_MIRRORS="true"
                shift
                ;;
            --no-optimize-mirrors)
                OPTIMIZE_MIRRORS="false"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --check)
                CHECK_ONLY="true"
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

    if [[ ! -w "$0" ]]; then
        log_error "Cannot update: The script location '$0' is not writable."
        log_info "Please download the script to a writable location and run it from there."
        exit 1
    fi

    local temp_file
    temp_file=$(mktemp) || { log_error "Could not create temporary file."; exit 1; }
    trap 'rm -f "$temp_file"' EXIT

    local download_cmd
    if command -v curl >/dev/null 2>&1; then
        download_cmd="curl -fsSL"
    elif command -v wget >/dev/null 2>&1; then
        download_cmd="wget -qO-"
    else
        log_error "Neither curl nor wget is available for updating."
        exit 1
    fi

    if $download_cmd "$SCRIPT_URL" > "$temp_file"; then
        if [[ -s "$temp_file" ]] && head -1 "$temp_file" | grep -q "^#!/bin/bash"; then
            chmod +x "$temp_file"
            if mv -f "$temp_file" "$0"; then
                trap - EXIT # Success, so disable the cleanup trap.
                log_success "Script updated successfully. Please run the new version again."
            else
                log_error "Failed to replace the script file at '$0'. Update aborted."
                exit 1
            fi
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

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY RUN] Uninstall simulation started."
    fi

    # Stop and remove the container
    if distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        log_info "Stopping and removing container: $CONTAINER_NAME"
        run_command distrobox stop "$CONTAINER_NAME" --yes || true
        run_command distrobox rm "$CONTAINER_NAME" --force || true
    else
        log_info "Container '$CONTAINER_NAME' not found, skipping."
    fi

    # Clean up exported applications
    local app_dir="$HOME/.local/share/applications"
    if [[ -d "$app_dir" ]]; then
        log_info "Cleaning up exported application launchers (.desktop files)"
        if [[ "$DRY_RUN" != "true" ]]; then
            # Reliably find files created by `distrobox-export` or our manual fallback
            find "$app_dir" -type f -name "*-${CONTAINER_NAME}.desktop" -delete 2>/dev/null || true
            # Safety net using a robust find/grep/xargs pipeline instead of a fragile glob
            find "$app_dir" -maxdepth 1 -type f -name "*.desktop" -exec grep -lq "distrobox enter ${CONTAINER_NAME}" {} + | xargs -r rm -f 2>/dev/null || true
            if command -v update-desktop-database >/dev/null 2>&1; then
                update-desktop-database "$app_dir" 2>/dev/null || true
            fi
        else
             log_warn "[DRY RUN] Would search for and delete .desktop files in $app_dir"
        fi
    fi

    local cache_dir="$HOME/.cache/yay-${CONTAINER_NAME}"
    if [[ -d "$cache_dir" ]]; then
        log_info "Removing build cache at $cache_dir"
        [[ "$DRY_RUN" != "true" ]] && rm -rf "$cache_dir"
    fi

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
    local create_args=( --name "$CONTAINER_NAME" --image "archlinux:latest" --yes )
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
    wait_for_container || return 1
}

configure_container_base() {
    log_step "Configuring container base environment (sudo, keyring)"

    local setup_script
    read -r -d '' setup_script << 'EOF' || true
set -euo pipefail

echo "Setting up base environment inside container..."
readonly current_user="$1"
if [[ -z "$current_user" ]]; then
    echo "Error: Host username was not provided to the setup script." >&2
    exit 1
fi

if ! getent group wheel >/dev/null 2>&1; then
    groupadd wheel
    echo "Created 'wheel' group."
fi
if id "$current_user" >/dev/null 2>&1; then
    usermod -aG wheel "$current_user"
    echo "Added user '$current_user' to 'wheel' group."
else
    echo "Error: User '$current_user' not found inside the container." >&2
    exit 1
fi
echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-wheel-nopasswd
chmod 0440 /etc/sudoers.d/99-wheel-nopasswd
echo "Configured passwordless sudo for 'wheel' group."

# Boost entropy for keyring generation
echo "Installing rng-tools to speed up keyring generation..."
pacman -S --noconfirm --needed rng-tools
echo "Running rngd to gather entropy..."
# Fork rngd to the background
rngd -r /dev/urandom &
RNGD_PID=$!
# Give it a moment to start feeding entropy
sleep 2

# Initialize pacman keyring with timeout protection
echo "Initializing pacman keyring..."
if ! timeout 300 pacman-key --init; then
    echo "Warning: 'pacman-key --init' timed out or failed. This can happen on low-entropy systems."
fi

echo "Populating archlinux keyring..."
if ! timeout 300 pacman-key --populate archlinux; then
    echo "Warning: 'pacman-key --populate' timed out or failed. Package signature checks might fail."
fi

# Clean up the rngd process
echo "Stopping rngd..."
kill "$RNGD_PID" 2>/dev/null || echo "rngd process not found, may have already exited."

echo "Base environment setup complete."
EOF

    if ! echo "$setup_script" | run_command distrobox enter --root "$CONTAINER_NAME" -- bash -s "$CURRENT_USER"; then
        log_error "Failed to configure container base environment."
        return 1
    fi
}

optimize_pacman_mirrors() {
    if [[ "$OPTIMIZE_MIRRORS" == "false" ]]; then
        log_info "Skipping Pacman mirror optimization as requested."
        return
    fi

    log_step "Optimizing Pacman mirrors with reflector"

    local mirror_script
    read -r -d '' mirror_script << 'EOF'
set -euo pipefail
echo "Installing reflector..."
pacman -S --noconfirm --needed reflector

echo "Backing up current mirrorlist..."
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

echo "Generating new mirrorlist (this may take a minute)..."
# Select the 20 most recently synchronized HTTPS mirrors and sort them by download speed.
# Using a timeout to prevent indefinite hangs.
if timeout 300 reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist; then
    echo "Successfully updated mirrorlist."
else
    echo "Warning: Reflector failed or timed out. Restoring original mirrorlist."
    cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
    # This is a non-fatal warning.
    exit 0
fi
EOF

    if ! echo "$mirror_script" | run_command distrobox enter --root "$CONTAINER_NAME" -- bash; then
        log_warn "Failed to optimize mirrors. The script will continue with default mirrors."
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
    echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" | tee -a /etc/pacman.conf > /dev/null
    echo "Multilib repository enabled."
else
    echo "Multilib repository is already enabled."
fi
echo "Updating package database..."
pacman -Sy --noconfirm
EOF
        if ! echo "$multilib_script" | run_command distrobox enter --root "$CONTAINER_NAME" -- bash; then
            log_warn "Failed to enable multilib support. Installation of 32-bit packages will likely fail."
        fi
    fi
}

install_aur_helper() {
    log_step "Installing AUR helper (yay)"

    if distrobox enter "$CONTAINER_NAME" -- command -v yay >/dev/null 2>&1; then
        log_info "AUR helper 'yay' is already installed. Skipping."
        return 0
    fi

    local yay_script
    read -r -d '' yay_script << 'EOF' || true
set -euo pipefail
echo "Updating system and installing build tools..."
sudo pacman -Syu --noconfirm --needed git base-devel

# Switched from yay-bin to the upstream yay source.
# This requires a compile step but is the more standard approach.
echo "Cloning and building 'yay' AUR helper from source..."
cd /tmp
if [[ -d yay ]]; then rm -rf yay; fi
git clone https://aur.archlinux.org/yay.git
cd yay

# Build and install as a regular user.
# makepkg will use sudo internally to install the final package.
makepkg -si --noconfirm --clean
echo "'yay' installation completed."
yay --version
EOF

    if ! run_command distrobox enter "$CONTAINER_NAME" -- bash -c "$yay_script"; then
        log_error "Failed to install AUR helper (yay). Pamac installation will be skipped."
        return 1
    fi
}

install_pamac() {
    log_step "Installing Pamac package manager"
    
    if distrobox enter "$CONTAINER_NAME" -- command -v pamac-manager >/dev/null 2>&1; then
        log_info "Pamac is already installed. Skipping."
        return 0
    fi

    local pamac_script
    read -r -d '' pamac_script << 'EOF' || true
set -euo pipefail

echo "Installing 'pamac-aur' using yay..."
yay -S --noconfirm --needed --answeredit n --noprogressbar pamac-aur

# Configure Pamac to enable AUR support by default
if [[ -f /etc/pamac.conf ]]; then
    echo "Enabling AUR support in Pamac config..."
    sudo sed -i 's/^#EnableAUR/EnableAUR/' /etc/pamac.conf
    sudo sed -i 's/^#CheckAURUpdates/CheckAURUpdates/' /etc/pamac.conf
    # This option may not exist in all versions, so we check for it.
    if grep -q "#CheckAURVCSUpdates" /etc/pamac.conf; then
        sudo sed -i 's/^#CheckAURVCSUpdates/CheckAURVCSUpdates/' /etc/pamac.conf
    fi
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
    read -r -d '' hook_script << EOF || true
set -euo pipefail
# This hook attempts to clean up exported .desktop files when a package is removed via pacman.
# NOTE: This is a best-effort approach. It relies on the host user's home directory
# being mounted at the same path inside the container (standard distrobox behavior).

echo "Setting up pacman hooks for desktop entry cleanup..."
mkdir -p /etc/pacman.d/hooks

# Create the script that the hook will call
cat > /usr/local/bin/cleanup-exported-desktop-entries.sh << 'CLEANUP_SCRIPT'
#!/bin/bash
set -euo pipefail

# This script is run by pacman inside the container.
# $1: The name of the container (e.g., 'arch-pamac')
# $2: The path to the host user's home directory AS MOUNTED inside the container (e.g., '/home/deck')
if [[ -z "\${1:-}" || -z "\${2:-}" ]]; then exit 0; fi

readonly CONTAINER_NAME="\$1"
readonly HOST_HOME_IN_CONTAINER="\$2"
readonly HOST_APP_DIR="\$HOST_HOME_IN_CONTAINER/.local/share/applications"

if [[ ! -d "\$HOST_APP_DIR" ]]; then exit 0; fi

# Read removed package names from stdin
while IFS= read -r pkg_name; do
    if [[ -z "\$pkg_name" ]]; then continue; fi
    # Find .desktop files installed by this package.
    pkg_desktop_files=\$(pacman -Ql "\$pkg_name" | awk '/\\/usr\\/share\\/applications\\/.*\\.desktop\$/ {print \$2}' || true)
    for desktop_file in \$pkg_desktop_files; do
        app_name=\$(basename "\$desktop_file" .desktop)
        exported_file="\${HOST_APP_DIR}/\${app_name}-\${CONTAINER_NAME}.desktop"
        if [[ -f "\$exported_file" ]]; then
            echo "Hook: Removing exported launcher: \$exported_file"
            rm -f "\$exported_file"
        fi
    done
done

# This path is inside the container, but points to the host's directory structure.
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "\$HOST_APP_DIR" 2>/dev/null || true
fi
CLEANUP_SCRIPT
chmod +x /usr/local/bin/cleanup-exported-desktop-entries.sh

# Create pacman hook to trigger the script.
# We expand variables from the host script to bake in the container name and host home path.
cat > /etc/pacman.d/hooks/99-distrobox-cleanup.hook << HOOK_CONFIG
[Trigger]
Operation = Remove
Type = Package
Target = *

[Action]
Description = Cleaning up exported desktop entries...
When = PostTransaction
# The hook runs inside the container, so we must provide paths that are valid
# inside it. Distrobox mounts the host's home directory (e.g., /home/deck) at
# the same path inside the container. We bake this path into the hook for robustness.
Exec = /usr/local/bin/cleanup-exported-desktop-entries.sh "${CONTAINER_NAME}" "/home/${CURRENT_USER}"
NeedsTargets
HOOK_CONFIG
echo "Cleanup hooks configured."
EOF

    if ! echo "$hook_script" | run_command distrobox enter --root "$CONTAINER_NAME" -- bash; then
        log_warn "Failed to set up cleanup hooks. Uninstalled packages may leave behind menu entries."
    fi
}

install_gaming_packages() {
    if [[ "$ENABLE_GAMING_PACKAGES" == "true" ]]; then
        log_step "Installing optional gaming packages"
        local gaming_script
        read -r -d '' gaming_script << 'EOF' || true
set -euo pipefail
# The first argument ($1) is the ENABLE_MULTILIB flag from the host script.
readonly IS_MULTILIB_ENABLED="$1"

echo "Installing gaming-related packages..."
# Define packages to install.
gaming_packages=( "steam" "lutris" "wine-staging" "winetricks" "gamemode" "mangohud" )

# Add 32-bit packages if multilib is enabled.
if [[ "$IS_MULTILIB_ENABLED" == "true" ]]; then
    echo "Multilib is enabled, adding 32-bit gaming libraries..."
    gaming_packages+=( "lib32-gamemode" "lib32-mangohud" )
fi

failed_packages=()
for package in "${gaming_packages[@]}"; do
    echo "Installing ${package}..."
    if ! yay -S --noconfirm --needed --answeredit n --noprogressbar "${package}"; then
        echo "Warning: Failed to install ${package}"
        failed_packages+=("${package}")
    fi
done

# Signal failure if any packages failed to install.
if [[ ${#failed_packages[@]} -gt 0 ]]; then
    echo "Error: The following packages failed to install: ${failed_packages[*]}" >&2
    exit 1
fi

echo "All selected gaming packages installed successfully."
EOF
        if ! echo "$gaming_script" | run_command distrobox enter "$CONTAINER_NAME" -- bash -s "$ENABLE_MULTILIB"; then
            log_warn "One or more gaming packages failed to install. Check the log for details."
        fi
    fi
}

export_pamac_to_host() {
    log_step "Exporting Pamac to the host application menu"

    log_info "Attempting to export using 'distrobox-export'..."
    local export_cmd="distrobox enter $CONTAINER_NAME -- distrobox-export --app pamac-manager --extra-flags '--no-sandbox'"
    
    if run_command sh -c "$export_cmd"; then
        log_success "Pamac exported successfully to the application menu."
    else
        log_warn "'distrobox-export' failed. The error has been logged. Creating a manual launcher as a fallback."

        local desktop_dir="$HOME/.local/share/applications"
        mkdir -p "$desktop_dir"

        local desktop_file="$desktop_dir/pamac-manager-${CONTAINER_NAME}.desktop"
        cat > "$desktop_file" << EOF
[Desktop Entry]
Name=Pamac Manager (${CONTAINER_NAME})
Comment=Add/Remove Software from the Arch container
Exec=distrobox enter ${CONTAINER_NAME} -- /usr/bin/pamac-manager --no-sandbox
Icon=pamac-manager
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

    if command -v update-desktop-database >/dev/null 2>&1; then
        run_command update-desktop-database "$HOME/.local/share/applications"
    fi

    local bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"
    local cli_wrapper="$bin_dir/pamac-${CONTAINER_NAME}"

    cat > "$cli_wrapper" << EOF
#!/bin/bash
# Pamac CLI wrapper for the '${CONTAINER_NAME}' container
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
    [[ "$OPTIMIZE_MIRRORS" == "true" ]] && echo "  • Pacman mirrors have been ${BOLD}optimized for speed${NC}."
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

run_pre_flight_checks() {
    log_step "Performing pre-flight system checks..."
    if check_system_requirements; then
        log_success "All system checks passed. The system is ready for installation."
    else
        log_error "One or more system checks failed. Please review the errors above."
        exit 1
    fi
}

# --- Main Function ---
main() {
    setup_colors
    
    if [[ "$EUID" -eq 0 ]]; then
        # Logging isn't initialized yet, so use direct echo with color codes.
        echo -e "\e[91m❌ This script should not be run as root. Please run as the 'deck' user.\e[0m" >&2
        exit 1
    fi
    
    parse_arguments "$@"

    # Must initialize after parsing to respect --quiet etc.
    initialize_logging

    if [[ "$CHECK_ONLY" == "true" ]]; then
        run_pre_flight_checks
        exit 0
    fi

    validate_container_name || exit 1
    run_pre_flight_checks # Also run checks before a full install

    echo -e "${BOLD}${BLUE}Starting Steam Deck Pamac Setup v${SCRIPT_VERSION}${NC}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${BOLD}${YELLOW}DRY RUN MODE: No changes will be made.${NC}"
    fi
    echo

    if [[ "$FORCE_REBUILD" == "true" ]] && distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        log_step "Force-rebuild is enabled. Removing existing container first."
        uninstall_setup
    fi

    if ! distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        create_container || exit 1
    else
        log_success "Using existing container: $CONTAINER_NAME"
        wait_for_container || exit 1
    fi

    configure_container_base || exit 1
    optimize_pacman_mirrors
    configure_multilib

    install_aur_helper || exit 1
    install_pamac || exit 1

    install_gaming_packages
    setup_cleanup_hooks

    export_pamac_to_host

    show_completion_message
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
