#!/bin/bash

# Steam Deck Pamac Setup Script - Fixed Version
# This script sets up a persistent, GUI-based package management system
# using Distrobox containers on SteamOS without Developer Mode

set -euo pipefail

# --- Configuration Variables ---
readonly SCRIPT_VERSION="4.3.3"
readonly SCRIPT_URL="https://raw.githubusercontent.com/user/repo/main/setup-pamac.sh"
readonly REQUIRED_TOOLS=("distrobox")
readonly DEFAULT_CONTAINER_NAME="arch-pamac"
readonly LOG_FILE="$HOME/distrobox-pamac-setup.log"

# User-configurable variables
CONTAINER_NAME="${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}"
# Derive the real calling user, even when run with sudo -E
if [[ -n "${SUDO_USER:-}" ]]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER=$(whoami)
fi

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
    
    # Strip ANSI escape codes for the log file
    local plain_message
    plain_message=$(echo "$message" | sed 's/\x1B\[[0-9;]*[A-Za-z]//g')
    
    echo "[$timestamp] $level: $plain_message" >> "$LOG_FILE"
    
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

# Improved command execution with better error handling
run_command() {
    log_debug "Executing: $*"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY RUN] Would execute: $*"
        return 0
    fi

    local status=0
    if [[ "$LOG_LEVEL" == "verbose" ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE" || true
        status="${PIPESTATUS[0]}"
    else
        "$@" >> "$LOG_FILE" 2>&1 || status=$?
    fi
    
    if [[ $status -ne 0 ]]; then
        log_debug "Command failed with exit code: $status"
    fi
    
    return "$status"
}

# --- Validation Functions ---
validate_container_name() {
    if [[ ! "$CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        log_error "Invalid container name: $CONTAINER_NAME"
        log_info "Container names must start with an alphanumeric character and contain only letters, numbers, hyphens, and underscores."
        return 1
    fi

    if [[ ${#CONTAINER_NAME} -gt 63 ]]; then
        log_error "Container name too long (max 63 characters): $CONTAINER_NAME"
        return 1
    fi
}

check_system_requirements() {
    log_step "Checking system requirements..."
    local missing_tools=()
    local all_ok=true

    # Check distrobox
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
            all_ok=false
        fi
    done

    # Check for a supported runtime: podman OR docker
    local have_runtime=false
    if command -v podman >/dev/null 2>&1; then
        have_runtime=true
        log_debug "Found container runtime: podman"
    elif command -v docker >/dev/null 2>&1; then
        have_runtime=true
        log_debug "Found container runtime: docker"
    fi
    
    if [[ "$have_runtime" == "false" ]]; then
        missing_tools+=("podman or docker")
        all_ok=false
    fi

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "On SteamOS, install distrobox with:"
        log_info "  curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix ~/.local"
        log_info "Then restart your terminal or run: source ~/.bashrc"
    else
        log_success "All required tools are present."
    fi

    # Check disk space (need at least 2GB)
    local available_space
    if available_space=$(df --output=avail -k "$HOME" 2>/dev/null | tail -n1); then
        if [[ $available_space -lt 2097152 ]]; then  # 2GB in KB
            log_warn "Low disk space detected. At least 2GB is recommended."
            log_info "Available space: $(( available_space / 1024 ))MB"
            all_ok=false
        else
            log_success "Sufficient disk space available: $(( available_space / 1024 / 1024 ))GB"
        fi
    else
        log_warn "Could not check disk space."
    fi

    # Verify SteamOS compatibility
    if ! grep -q "ID=steamos" /etc/os-release 2>/dev/null; then
        log_warn "Not running on SteamOS. Compatibility is not guaranteed."
    else
        log_success "SteamOS detected."
    fi

    return $([[ "$all_ok" == "true" ]] && echo 0 || echo 1)
}

# ----------  SteamOS podman-on-demand installer  ----------
# ----------  SteamOS podman-on-demand installer  ----------
ensure_podman() {
  # 1. Fast exit if we already have a working runtime
  if command -v podman >/dev/null 2>&1 && \
     podman system info >/dev/null 2>&1; then
    log_debug "Podman already usable – nothing to install"
    export DISTROBOX_CONTAINER_MANAGER=podman
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    log_debug "Docker found – using it"
    export DISTROBOX_CONTAINER_MANAGER=docker
    return 0
  fi

  log_step "No container runtime found – attempting to let Distrobox handle setup (SteamOS)"

  # Instead of trying to install podman manually, we set the environment variable
  # and let Distrobox's 'create' command handle the podman setup automatically.
  # Modern Distrobox versions can install podman-static automatically on SteamOS.
  export DISTROBOX_CONTAINER_MANAGER=podman

  # Inform the user that Distrobox will handle the installation
  log_info "Distrobox will automatically install podman when creating the container."
  log_info "This may take a few minutes on first run."

  # No need to manually install or start podman.
  # The 'distrobox create' command will trigger the automatic setup.
  # We'll verify it works after container creation in the main flow.

  log_success "Podman setup will be handled automatically by Distrobox."
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
    --update                 Update this script to the latest version
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
            --force-rebuild)        FORCE_REBUILD="true"; shift ;;
            --enable-multilib)      ENABLE_MULTILIB="true"; shift ;;
            --disable-multilib)     ENABLE_MULTILIB="false"; shift ;;
            --enable-gaming)        ENABLE_GAMING_PACKAGES="true"; shift ;;
            --disable-gaming)       ENABLE_GAMING_PACKAGES="false"; shift ;;
            --enable-build-cache)   ENABLE_BUILD_CACHE="true"; shift ;;
            --disable-build-cache)  ENABLE_BUILD_CACHE="false"; shift ;;
            --optimize-mirrors)     OPTIMIZE_MIRRORS="true"; shift ;;
            --no-optimize-mirrors)  OPTIMIZE_MIRRORS="false"; shift ;;
            --dry-run)              DRY_RUN="true"; shift ;;
            --check)                CHECK_ONLY="true"; shift ;;
            --verbose)              LOG_LEVEL="verbose"; shift ;;
            --quiet)                LOG_LEVEL="quiet"; shift ;;
            --update)               update_script; exit 0 ;;
            --uninstall)            uninstall_setup; exit 0 ;;
            --version)              echo "Steam Deck Pamac Setup v${SCRIPT_VERSION}"; exit 0 ;;
            -h|--help)              show_usage; exit 0 ;;
            *)                      log_error "Unknown option: $1"; show_usage; exit 1 ;;
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
        return 1
    fi

    local temp_file
    temp_file=$(mktemp) || { log_error "Could not create temporary file."; return 1; }
    trap 'rm -f "$temp_file"' RETURN

    local download_cmd
    if command -v curl >/dev/null 2>&1; then
        download_cmd="curl -fsSL"
    elif command -v wget >/dev/null 2>&1; then
        download_cmd="wget -qO-"
    else
        log_error "Neither curl nor wget is available for updating."
        return 1
    fi

    if $download_cmd "$SCRIPT_URL" > "$temp_file"; then
        if [[ -s "$temp_file" ]] && head -1 "$temp_file" | grep -q "^#!/bin/bash"; then
            chmod +x "$temp_file"
            if cp "$temp_file" "$0"; then
                log_success "Script updated successfully. Please run the new version again."
            else
                log_error "Failed to replace the script file at '$0'. Update aborted."
                return 1
            fi
        else
            log_error "Downloaded file appears to be invalid or empty."
            return 1
        fi
    else
        log_error "Failed to download update from the server."
        return 1
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
        run_command distrobox stop "$CONTAINER_NAME" || true
        run_command distrobox rm "$CONTAINER_NAME" --force || true
    else
        log_info "Container '$CONTAINER_NAME' not found, skipping removal."
    fi

    # Clean up exported applications
    local app_dir="$HOME/.local/share/applications"
    if [[ -d "$app_dir" ]]; then
        log_info "Cleaning up exported application launchers"
        if [[ "$DRY_RUN" != "true" ]]; then
            # Remove files created by distrobox-export
            find "$app_dir" -type f -name "*-${CONTAINER_NAME}.desktop" -delete 2>/dev/null || true
            # Remove manual desktop files that reference our container
            find "$app_dir" -maxdepth 1 -type f -name "*.desktop" -exec grep -l "distrobox enter ${CONTAINER_NAME}" {} \; 2>/dev/null | xargs -r rm -f 2>/dev/null || true
            if command -v update-desktop-database >/dev/null 2>&1; then
                update-desktop-database "$app_dir" 2>/dev/null || true
            fi
        else
            log_warn "[DRY RUN] Would search for and delete .desktop files in $app_dir"
        fi
    fi

    # Clean up build cache
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
            log_info "Try checking container status with: distrobox list"
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

  local -a create_args=(
    --name "$CONTAINER_NAME"
    --image "archlinux:latest"
    --yes                 # <-- non-interactive
  )

  [[ "$ENABLE_BUILD_CACHE" == "true" ]] && {
    local cache_dir="$HOME/.cache/yay-${CONTAINER_NAME}"
    mkdir -p "$cache_dir"
    create_args+=(--volume "${cache_dir}:/home/${CURRENT_USER}/.cache/yay:rw")
    log_info "Enabled persistent build cache: $cache_dir"
  }

  # quote the array properly
  if ! run_command distrobox create "${create_args[@]}"; then
    log_error "Failed to create Distrobox container."
    return 1
  fi

  wait_for_container || return 1
}

configure_container_base() {
    log_step "Configuring container base environment (more robust)"

    local setup_script
    read -r -d '' setup_script <<'EOF' || true
set -euo pipefail

# This script runs inside the container as root.
current_user="$1"
if [[ -z "$current_user" ]]; then
    echo "ERROR: Host username not supplied to container setup." >&2
    exit 1
fi

echo "Container: configuring base environment for user='$current_user'"

# Basic network check
if ! ping -c1 8.8.8.8 >/dev/null 2>&1; then
    echo "WARNING: No network (ping to 8.8.8.8 failed). Pacman operations may fail." >&2
fi

# Ensure pacman DB exists and mirrors are reachable before heavy ops
if ! pacman -Sy --noconfirm >/dev/null 2>&1; then
    echo "WARNING: 'pacman -Sy' failed. Will continue but package installs may fail." >&2
fi

# Install minimal tooling if missing (sudo, shadow for usermod/groupadd, gnupg for pacman-key)
need_pkgs=()
for pkg in sudo shadow gpg pacman-key; do
    if ! command -v "$pkg" >/dev/null 2>&1 && ! pacman -Qi "$pkg" >/dev/null 2>&1; then
        need_pkgs+=("$pkg")
    fi
done
if [[ ${#need_pkgs[@]} -gt 0 ]]; then
    echo "Installing helper packages: ${need_pkgs[*]}"
    pacman -S --noconfirm --needed "${need_pkgs[@]}" || echo "Warning: could not install helper packages: ${need_pkgs[*]}"
fi

# Ensure user exists; if not, create a matching user (no password) with home dir
if id "$current_user" >/dev/null 2>&1; then
    echo "User '$current_user' exists inside container."
else
    echo "User '$current_user' not found. Creating user with same name."
    # Pick a high UID that avoids collision if necessary; prefer to mirror host UID if provided via env
    useradd -m -G wheel -s /bin/bash "$current_user" || { echo "Error: failed to create user '$current_user'"; exit 1; }
    echo "Created user '$current_user' and added to wheel group."
fi

# Ensure wheel group exists
if ! getent group wheel >/dev/null 2>&1; then
    echo "Creating wheel group..."
    groupadd wheel || echo "Warning: groupadd wheel failed (may already exist)"
fi

# Configure passwordless sudo for wheel
if [[ ! -f /etc/sudoers.d/99-wheel-nopasswd ]]; then
    echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-wheel-nopasswd
    chmod 0440 /etc/sudoers.d/99-wheel-nopasswd || echo "Warning: chmod on sudoers file failed"
    echo "Configured passwordless sudo for wheel."
else
    echo "Passwordless sudo for wheel already configured."
fi

# Try to initialize pacman keyring; tolerate failure but report it
echo "Initializing pacman keyring..."
if pacman-key --init >/dev/null 2>&1; then
    echo "pacman-key --init OK"
else
    echo "Warning: pacman-key --init failed; continuing (signing may fail)."
fi

if pacman-key --populate archlinux >/dev/null 2>&1; then
    echo "pacman-key --populate OK"
else
    echo "Warning: pacman-key --populate failed."
fi

# Update system packages (best-effort)
echo "Updating system packages (best-effort)..."
if ! pacman -Syu --noconfirm; then
    echo "Warning: pacman -Syu failed. You may need to run this manually inside the container."
fi

echo "Container base setup finished."
EOF

    # Execute inside the container as root and make sure we capture stdout/stderr in the log
    if ! echo "$setup_script" | run_command distrobox enter --root "$CONTAINER_NAME" -- bash -s "$CURRENT_USER"; then
        log_error "Failed to configure container base environment (see container output in log)."
        return 1
    fi
}

optimize_pacman_mirrors() {
    if [[ "$OPTIMIZE_MIRRORS" == "false" ]]; then
        log_info "Skipping Pacman mirror optimization as requested."
        return
    fi

    log_step "Optimizing Pacman mirrors"

    local mirror_script
    read -r -d '' mirror_script << 'EOF'
set -euo pipefail

echo "Installing reflector..."
if ! pacman -S --noconfirm --needed reflector; then
    echo "Failed to install reflector. Skipping mirror optimization."
    exit 0
fi

echo "Backing up current mirrorlist..."
[[ -f /etc/pacman.d/mirrorlist ]] && cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

echo "Generating optimized mirrorlist..."
if reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist; then
    echo "Successfully updated mirrorlist."
else
    echo "Reflector failed. Restoring backup if available."
    [[ -f /etc/pacman.d/mirrorlist.backup ]] && cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
    exit 0
fi
EOF

    if ! echo "$mirror_script" | run_command distrobox enter --root "$CONTAINER_NAME" -- bash; then
        log_warn "Failed to optimize mirrors. Continuing with default mirrors."
    fi
}

configure_multilib() {
    if [[ "$ENABLE_MULTILIB" == "true" ]]; then
        log_step "Enabling multilib (32-bit) support"
        
        local multilib_script
        read -r -d '' multilib_script << 'EOF'
set -euo pipefail

if ! grep -q "^\s*\[multilib\]" /etc/pacman.conf; then
    echo "Enabling multilib repository..."
    echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
    echo "Multilib repository enabled."
else
    echo "Multilib repository is already enabled."
fi

echo "Updating package database..."
pacman -Sy --noconfirm
EOF
        
        if ! echo "$multilib_script" | run_command distrobox enter --root "$CONTAINER_NAME" -- bash; then
            log_warn "Failed to enable multilib support. 32-bit packages may not be available."
        fi
    fi
}

install_aur_helper() {
    log_step "Installing AUR helper (yay)"

    if distrobox enter "$CONTAINER_NAME" -- command -v yay >/dev/null 2>&1; then
        log_info "AUR helper 'yay' is already installed."
        return 0
    fi

    local yay_script
    read -r -d '' yay_script << 'EOF'
set -euo pipefail
echo "Installing build dependencies..."
sudo pacman -S --noconfirm --needed git base-devel
echo "Cloning and building yay from AUR..."
cd /tmp
# FIX: Ensure git clone is called correctly and directory is clean
rm -rf yay
git clone "https://aur.archlinux.org/yay.git" yay
cd yay
makepkg -si --noconfirm --clean
EOF

    if ! run_command distrobox enter "$CONTAINER_NAME" -- bash -c "$yay_script"; then
        log_error "Failed to install AUR helper (yay)."
        return 1
    fi
}

install_pamac() {
    log_step "Installing Pamac package manager"
    
    # Check if pamac is already installed
    if distrobox enter "$CONTAINER_NAME" -- command -v pamac-manager >/dev/null 2>&1; then
        log_info "Pamac is already installed."
        return 0
    fi

    local pamac_script
    read -r -d '' pamac_script << 'EOF'
set -euo pipefail

echo "Installing pamac-aur from AUR..."
yay -S --noconfirm --needed --answeredit n --noprogressbar pamac-aur

# Configure Pamac for AUR support
if [[ -f /etc/pamac.conf ]]; then
    echo "Configuring Pamac for AUR support..."
    sudo sed -i 's/^#EnableAUR/EnableAUR/' /etc/pamac.conf
    sudo sed -i 's/^#CheckAURUpdates/CheckAURUpdates/' /etc/pamac.conf
    if grep -q "#CheckAURVCSUpdates" /etc/pamac.conf; then
        sudo sed -i 's/^#CheckAURVCSUpdates/CheckAURVCSUpdates/' /etc/pamac.conf
    fi
    echo "Pamac configuration updated for AUR support."
else
    echo "Warning: /etc/pamac.conf not found. Cannot enable AUR support automatically."
fi

# Verify installation
if command -v pamac-manager >/dev/null 2>&1; then
    echo "Pamac installed successfully."
    pamac --version 2>/dev/null || echo "Pamac version info not available"
else
    echo "Error: Pamac installation verification failed."
    exit 1
fi
EOF

    if ! run_command distrobox enter "$CONTAINER_NAME" -- bash -c "$pamac_script"; then
        log_error "Failed to install Pamac."
        return 1
    fi
}

install_gaming_packages() {
    if [[ "$ENABLE_GAMING_PACKAGES" != "true" ]]; then
        return
    fi

    log_step "Installing gaming packages"
    
    local gaming_script
    read -r -d '' gaming_script << 'EOF'
set -euo pipefail

readonly IS_MULTILIB_ENABLED="$1"
gaming_packages=( "lutris" "wine-staging" "winetricks" "gamemode" "mangohud" )

if [[ "$IS_MULTILIB_ENABLED" == "true" ]]; then
    echo "Adding 32-bit gaming libraries..."
    gaming_packages+=( "lib32-gamemode" "lib32-mangohud" )
fi

echo "Installing gaming packages: ${gaming_packages[*]}"
failed_packages=()

for package in "${gaming_packages[@]}"; do
    echo "Installing ${package}..."
    if ! yay -S --noconfirm --needed --answeredit n --noprogressbar "${package}"; then
        echo "Warning: Failed to install ${package}"
        failed_packages+=("${package}")
    fi
done

if [[ ${#failed_packages[@]} -gt 0 ]]; then
    echo "Warning: Some packages failed to install: ${failed_packages[*]}"
    echo "Gaming setup partially completed."
else
    echo "All gaming packages installed successfully."
fi
EOF

    if ! echo "$gaming_script" | run_command distrobox enter "$CONTAINER_NAME" -- bash -s "$ENABLE_MULTILIB"; then
        log_warn "Gaming package installation encountered errors. Check the log for details."
    fi
}

export_pamac_to_host() {
    log_step "Exporting Pamac to host system"

    # Try using distrobox-export first
    log_info "Attempting to export Pamac using distrobox-export..."
    if run_command distrobox-export --app pamac-manager --extra-flags --no-sandbox --container "$CONTAINER_NAME"; then
        log_success "Pamac exported successfully using distrobox-export."
    else
        log_warn "distrobox-export failed. Creating manual desktop entry..."

        # Create manual desktop entry
        local desktop_dir="$HOME/.local/share/applications"
        mkdir -p "$desktop_dir"

        local desktop_file="$desktop_dir/pamac-manager-${CONTAINER_NAME}.desktop"
        cat > "$desktop_file" << EOF
[Desktop Entry]
Name=Pamac Manager (${CONTAINER_NAME})
Comment=Package Manager for Arch Linux Container
Exec=distrobox enter ${CONTAINER_NAME} -- pamac-manager --no-sandbox
Icon=pamac-manager
Terminal=false
Type=Application
Categories=System;Settings;PackageManager;
Keywords=package;manager;software;arch;aur;
StartupNotify=true
X-Distrobox-App=pamac-manager
X-Distrobox-Container=${CONTAINER_NAME}
EOF
        chmod +x "$desktop_file"
        log_success "Created manual desktop entry: $desktop_file"
    fi

    # Update desktop database
    if command -v update-desktop-database >/dev/null 2>&1; then
        run_command update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    fi

    # Create CLI wrapper
    local bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"
    local cli_wrapper="$bin_dir/pamac-${CONTAINER_NAME}"

    cat > "$cli_wrapper" << EOF
#!/bin/bash
# Pamac CLI wrapper for container: ${CONTAINER_NAME}
exec distrobox enter "${CONTAINER_NAME}" -- pamac "\$@"
EOF
    chmod +x "$cli_wrapper"
    log_info "Created CLI wrapper: $cli_wrapper"
    
    if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
        log_info "Add '$bin_dir' to your PATH to use the CLI wrapper directly."
    fi
}

show_completion_message() {
    echo
    log_success "Steam Deck Pamac Setup completed successfully!"
    echo
    echo -e "${BOLD}${BLUE}--- Installation Summary ---${NC}"
    echo "  • Container: ${BOLD}$CONTAINER_NAME${NC}"
    echo "  • Pamac GUI package manager installed and configured"
    echo "  • AUR helper 'yay' available for command-line package management"
    [[ "$OPTIMIZE_MIRRORS" == "true" ]] && echo "  • Pacman mirrors optimized for performance"
    [[ "$ENABLE_MULTILIB" == "true" ]] && echo "  • 32-bit package support enabled"
    [[ "$ENABLE_GAMING_PACKAGES" == "true" ]] && echo "  • Gaming packages installed (Steam, Lutris, etc.)"
    [[ "$ENABLE_BUILD_CACHE" == "true" ]] && echo "  • Persistent build cache enabled"
    echo
    echo -e "${BOLD}${GREEN}--- How to Use ---${NC}"
    echo "  • Find 'Pamac Manager ($CONTAINER_NAME)' in your application menu"
    echo "  • Command line access: ${BOLD}distrobox enter $CONTAINER_NAME${NC}"
    echo "  • CLI shortcut: ${BOLD}pamac-${CONTAINER_NAME} <command>${NC}"
    echo
    echo -e "${BOLD}${YELLOW}--- Important Notes ---${NC}"
    echo "  • Container persists across reboots"
    echo "  • To uninstall: run this script with ${BOLD}--uninstall${NC}"
    echo "  • Installation log saved to: ${BOLD}$LOG_FILE${NC}"
    echo
}

run_pre_flight_checks() {
    log_step "Running pre-flight system checks..."
    if check_system_requirements; then
        log_success "All system checks passed."
        return 0
    else
        log_error "System requirements not met. Please address the issues above."
        return 1
    fi
}

# --- Main Function ---
main() {
    setup_colors
    
    # Security check: don't run as root
    if [[ "$EUID" -eq 0 ]]; then
        echo -e "\e[91m❌ This script should not be run as root.\e[0m" >&2
        echo -e "\e[91mPlease run as the regular user (e.g., 'deck' on Steam Deck).\e[0m" >&2
        exit 1
    fi
    
    # Parse command line arguments
    parse_arguments "$@"

    # Initialize logging (must be after argument parsing to respect --quiet etc.)
    initialize_logging
    

    # Handle check-only mode
    if [[ "$CHECK_ONLY" == "true" ]]; then
        ensure_podman
        run_pre_flight_checks
        exit $?
    fi

    # Validate configuration
    validate_container_name || exit 1
    export PODMAN_ASSUME_YES=1            # ← silence podman pull prompts
    export DISTROBOX_ENTER_FLAGS="--yes"  # ← silence any future enter prompts
    
    # Run system checks
    run_pre_flight_checks || exit 1
    ensure_podman

    # Show startup banner
    echo -e "${BOLD}${BLUE}Steam Deck Pamac Setup v${SCRIPT_VERSION}${NC}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${BOLD}${YELLOW}DRY RUN MODE - No actual changes will be made${NC}"
    fi
    echo

    # Handle force rebuild
    if [[ "$FORCE_REBUILD" == "true" ]] && distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        log_step "Force rebuild requested - removing existing container"
        uninstall_setup
    fi

    # Create or verify container exists
    if ! distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        create_container || exit 1
    else
        log_success "Using existing container: $CONTAINER_NAME"
        wait_for_container || exit 1
    fi

    # Configure the container
    configure_container_base || exit 1
    optimize_pacman_mirrors
    configure_multilib

    # Install package management tools
    install_aur_helper || exit 1
    install_pamac || exit 1

    # Install optional packages
    install_gaming_packages

    # Export to host system
    export_pamac_to_host

    # Show completion summary
    show_completion_message
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
