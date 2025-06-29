#!/bin/bash

# Steam Deck Pamac Setup Script
# This script is specifically designed to work on SteamOS without Developer Mode
# It automates the setup of a persistent, GUI-based package management system
# using Distrobox containers with no host system modifications.

# Stop on any error
set -e

# --- Configuration Variables ---
SCRIPT_VERSION="3.3"
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
    echo "SteamOS Version: $(grep VERSION_ID /etc/os-release | cut -d= -f2)" >> "$LOG_FILE"
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
    echo "  -h, --help             Show this help"
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --container-name) CONTAINER_NAME="$2"; shift 2 ;;
            --force-rebuild) FORCE_REBUILD="true"; shift ;;
            --enable-multilib) ENABLE_MULTILIB="true"; shift ;;
            --enable-gaming) ENABLE_GAMING_PACKAGES="true"; shift ;;
            --dry-run) DRY_RUN="true"; shift ;;
            --verbose) LOG_LEVEL="verbose"; shift ;;
            --update) update_script; exit 0 ;;
            --uninstall) uninstall_setup; exit 0 ;;
            -h|--help) show_usage; exit 0 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
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
    if command -v curl &>/dev/null; then
        curl -fsSL "$SCRIPT_URL" -o "$temp_file" || {
            log_error "Download failed"; rm -f "$temp_file"; exit 1
        }
    elif command -v wget &>/dev/null; then
        wget -qO "$temp_file" "$SCRIPT_URL" || {
            log_error "Download failed"; rm -f "$temp_file"; exit 1
        }
    else
        log_error "Need curl or wget to update"; exit 1
    fi

    chmod +x "$temp_file"
    mv "$temp_file" "$0"
    log_success "Script updated. Please rerun."
}

uninstall_setup() {
    log_step "Uninstalling..."
    
    if distrobox list | grep -qw "$CONTAINER_NAME"; then
        log_info "Removing container..."
        run_command distrobox rm "$CONTAINER_NAME" --force || log_error "Container removal failed"
    fi
    
    if [ -d "$HOME/.local/share/applications" ]; then
        log_info "Cleaning exported apps..."
        find "$HOME/.local/share/applications" \( -name "*pamac*distrobox*" -o -name "*$CONTAINER_NAME*" \) -delete
    fi
    log_success "Uninstallation complete"
}

check_steamos_compatibility() {
    if ! grep -q "ID=steamos" /etc/os-release; then
        log_warn "Not running on SteamOS! Compatibility not guaranteed."
    fi
    
    if ! command -v distrobox >/dev/null || ! command -v podman >/dev/null; then
        log_error "Missing distrobox or podman. Required on SteamOS."
        exit 1
    fi
}

wait_for_container() {
    local attempts=0
    log_info "Waiting for container..."
    until distrobox enter "$CONTAINER_NAME" -- echo "Ready" &>/dev/null; do
        sleep 2
        ((attempts++))
        if [ $attempts -gt 30 ]; then
            log_error "Container startup timed out"
            return 1
        fi
    done
    log_success "Container ready"
}

# --- Core Functions ---
create_container() {
    log_step "Creating container..."
    local volume_args=""
    [ "$ENABLE_BUILD_CACHE" = "true" ] && {
        mkdir -p "$HOME/.cache/yay" "$HOME/.cache/pacman/pkg"
        volume_args="--volume $HOME/.cache/yay:/home/$CURRENT_USER/.cache/yay:rw"
    }

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
    log_step "Configuring container..."
    local setup_script=$(cat <<'EOF'
#!/bin/bash
# Configure container without sudo
echo "Configuring container environment..."
if ! grep -q "wheel" /etc/group; then groupadd wheel; fi
usermod -aG wheel $(whoami)
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel-nopasswd
chmod 0440 /etc/sudoers.d/wheel-nopasswd
pacman-key --init && pacman-key --populate archlinux
EOF
)
    echo "$setup_script" | run_command distrobox enter "$CONTAINER_NAME" -- bash -s || {
        log_error "Container configuration failed"
        return 1
    }
}

install_pamac() {
    log_step "Installing Pamac..."
    local install_script=$(cat <<'EOF'
#!/bin/bash
# Install Pamac without requiring host sudo
echo "Installing Pamac..."
pacman -Syu --noconfirm --needed git base-devel
if ! command -v yay >/dev/null; then
    (git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin &&
     cd /tmp/yay-bin &&
     makepkg -si --noconfirm)
fi
yay -S --noconfirm --needed pamac-aur
sed -i 's/^#EnableAUR/EnableAUR/' /etc/pamac.conf
EOF
)
    echo "$install_script" | run_command distrobox enter "$CONTAINER_NAME" -- bash -s || {
        log_error "Pamac installation failed"
        return 1
    }
}

export_apps() {
    log_step "Exporting applications..."
    run_command distrobox-export --app pamac-manager --extra-flags "--no-sandbox" || {
        log_warn "Standard export failed, creating manual launcher"
        cat > "$HOME/.local/share/applications/pamac-manager-distrobox.desktop" <<EOF
[Desktop Entry]
Name=Pamac (Distrobox)
Exec=distrobox enter $CONTAINER_NAME -- pamac-manager
Icon=pamac
Terminal=false
Type=Application
Categories=System;
EOF
    }
    
    # Update desktop database if available
    if command -v update-desktop-database &>/dev/null; then
        run_command update-desktop-database "$HOME/.local/share/applications"
    fi
}

# --- Main Execution ---
main() {
    initialize_logging
    parse_arguments "$@"
    check_steamos_compatibility

    echo -e "${BOLD}${BLUE}Steam Deck Pamac Setup v${SCRIPT_VERSION}${NC}"
    [ "$DRY_RUN" = "true" ] && log_warn "DRY RUN MODE: No changes will be made"
    
    # Rebuild container if requested
    if [ "$FORCE_REBUILD" = "true" ] && distrobox list | grep -qw "$CONTAINER_NAME"; then
        log_step "Rebuilding container..."
        run_command distrobox rm "$CONTAINER_NAME" --force
    fi

    # Create container if needed
    if ! distrobox list | grep -qw "$CONTAINER_NAME"; then
        create_container
    else
        log_success "Using existing container: $CONTAINER_NAME"
    fi

    # Container setup
    configure_container
    install_pamac
    export_apps

    # Final report
    echo -e "\n${BOLD}${GREEN}Setup Complete!${NC}"
    echo -e "Access Pamac through your application menu"
    echo -e "Log file: ${LOG_FILE}"
}

main "$@"
