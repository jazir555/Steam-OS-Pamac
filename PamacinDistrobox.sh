#!/bin/bash

# Enhanced Steam Deck Pamac Setup Script v3.2
# This script automates the setup of a persistent, GUI-based package management
# system (Pamac with AUR) on SteamOS using Distrobox.
# It is idempotent, fully automated, and requires no user input after execution.

# Stop on any error
set -e

# --- Configuration Variables ---
SCRIPT_VERSION="3.2"
CONTAINER_NAME="${CONTAINER_NAME:-arch-box}"
CURRENT_USER=$(whoami)
LOG_FILE="$HOME/distrobox-pamac-setup.log"
SCRIPT_URL="https://raw.githubusercontent.com/user/repo/main/setup-pamac.sh"

# Feature flags (can be set via environment variables)
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
LOG_LEVEL="normal" # quiet, normal, verbose
EXPORTED_APPS=()
CONTAINER_WAS_CREATED_BY_SCRIPT="false" # For trap cleanup

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

# --- Logging and Output Functions ---
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
    echo "  AUTO_EXPORT_FLATPAKS: $AUTO_EXPORT_FLATPAKS" >> "$LOG_FILE"
    echo "  ENABLE_GAMING_PACKAGES: $ENABLE_GAMING_PACKAGES" >> "$LOG_FILE"
    echo "  CONFIGURE_LOCALE: $CONFIGURE_LOCALE" >> "$LOG_FILE"
    echo "  FORCE_REBUILD: $FORCE_REBUILD" >> "$LOG_FILE"
    echo "===========================================" >> "$LOG_FILE"
    
    trap 'echo "=== Run finished at: $(date) - Exit code: $? ===" >> "$LOG_FILE"' EXIT
}

_log() {
    local level="$1"
    local color="$2"
    local message="$3"
    echo -e "$message" >> "$LOG_FILE"
    case "$LOG_LEVEL" in
        "quiet")
            [ "$level" = "ERROR" ] && echo -e "${color}${message}${NC}"
            ;;
        "normal"|"verbose")
            echo -e "${color}${message}${NC}"
            ;;
    esac
}

log_step() { _log "INFO" "$BLUE" "\n${BOLD}==> $1${NC}"; }
log_info() { [ "$LOG_LEVEL" != "quiet" ] && _log "INFO" "" "$1"; }
log_success() { _log "SUCCESS" "$GREEN" "✓ $1"; }
log_warn() { _log "WARN" "$YELLOW" "⚠️ $1"; }
log_error() { _log "ERROR" "$RED" "❌ $1"; }

run_command() {
    log_info "    Executing: $@" >> "$LOG_FILE"
    if [ "$DRY_RUN" = "true" ]; then
        log_warn "[DRY RUN] Would execute: $@"
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
    echo ""
    echo "Primary Options:"
    echo "  --container-name NAME    Set container name (default: arch-box)"
    echo "  --force-rebuild          If container exists, remove and rebuild it"
    echo "  --update                 Update this script to the latest version"
    echo "  --uninstall              Remove container and all related files"
    echo ""
    echo "Feature Toggles:"
    echo "  --enable-multilib        Enable multilib repository for 32-bit apps"
    echo "  --enable-gaming          Install common gaming packages (Wine, Lutris, etc.)"
    echo "  --enable-flatpak-export  Auto-export Flatpaks installed inside the container"
    echo "  --disable-build-cache    Do not use a persistent build cache; clean cache on exit"
    echo "  --disable-mirrors        Do not configure fastest mirrors"
    echo "  --disable-auto-export    Do not automatically export newly installed GUI apps"
    echo ""
    echo "Customization:"
    echo "  --locale LOCALE          Set target locale (e.g., 'de_DE.UTF-8'). Implies locale config."
    echo "  --mirror-countries CODE  Comma-separated country codes for mirrors (e.g., 'DE,FR')"
    echo ""
    echo "Execution Control:"
    echo "  --dry-run                Show what would be done without making changes"
    echo "  --verbose                Enable detailed command output"
    echo "  --quiet                  Suppress informational output (show only errors)"
    echo "  -h, --help               Show this help message"
}

parse_arguments() {
    local options
    options=$(getopt -o h --long help,container-name:,locale:,mirror-countries:,enable-multilib,enable-gaming,enable-flatpak-export,disable-build-cache,disable-mirrors,disable-auto-export,update,uninstall,dry-run,verbose,quiet,force-rebuild -n "$0" -- "$@")
    if [ $? -ne 0 ]; then
        show_usage
        exit 1
    fi
    eval set -- "$options"

    while true; do
        case "$1" in
            --container-name) CONTAINER_NAME="$2"; shift 2 ;;
            --locale) TARGET_LOCALE="$2"; CONFIGURE_LOCALE="true"; shift 2 ;;
            --mirror-countries) MIRROR_COUNTRIES="$2"; shift 2 ;;
            --enable-multilib) ENABLE_MULTILIB="true"; shift ;;
            --enable-gaming) ENABLE_GAMING_PACKAGES="true"; shift ;;
            --enable-flatpak-export) AUTO_EXPORT_FLATPAKS="true"; shift ;;
            --disable-build-cache) ENABLE_BUILD_CACHE="false"; shift ;;
            --disable-mirrors) CONFIGURE_MIRRORS="false"; shift ;;
            --disable-auto-export) AUTO_EXPORT_APPS="false"; shift ;;
            --force-rebuild) FORCE_REBUILD="true"; shift ;;
            --dry-run) DRY_RUN="true"; shift ;;
            --verbose) LOG_LEVEL="verbose"; shift ;;
            --quiet) LOG_LEVEL="quiet"; shift ;;
            --update) update_script; exit 0 ;;
            --uninstall) uninstall_setup; exit 0 ;;
            -h|--help) show_usage; exit 0 ;;
            --) shift; break ;;
            *) log_error "Internal error! Unrecognized option: $1"; exit 1 ;;
        esac
    done
}

update_script() {
    log_step "Updating script to latest version..."
    local temp_file
    temp_file=$(mktemp)

    log_info "Attempting to download with curl..."
    if command -v curl &>/dev/null; then
        if ! curl -fsSL "$SCRIPT_URL" -o "$temp_file"; then
            log_error "curl failed to download the script."
            rm -f "$temp_file"
            exit 1
        fi
    elif command -v wget &>/dev/null; then
        log_info "curl not found, falling back to wget..."
        if ! wget -qO "$temp_file" "$SCRIPT_URL"; then
            log_error "wget failed to download the script."
            rm -f "$temp_file"
            exit 1
        fi
    else
        log_error "Neither curl nor wget found. Cannot update script."
        exit 1
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log_warn "[DRY RUN] Would download from $SCRIPT_URL and replace $0"
        rm -f "$temp_file"
        exit 0
    fi

    local backup_file="$0.bak.$(date +%s)"
    cp "$0" "$backup_file"
    log_info "Backup of current script saved to: $backup_file"

    chmod +x "$temp_file"
    mv "$temp_file" "$0"
    log_success "Script updated successfully. Please run it again."
}

uninstall_setup() {
    log_step "Uninstalling Steam Deck Pamac setup..."
    
    if distrobox list --no-color 2>/dev/null | grep -q " $CONTAINER_NAME "; then
        log_info "Removing container '$CONTAINER_NAME'..."
        if run_command distrobox rm "$CONTAINER_NAME" --force; then
            log_success "Container removed."
        else
            log_error "Failed to remove container."
        fi
    fi
    
    if [ -d "$HOME/.local/share/applications" ]; then
        log_info "Removing exported applications..."
        if [ "$DRY_RUN" = "true" ]; then
            log_warn "[DRY RUN] Would find and delete *pamac*distrobox* and *$CONTAINER_NAME* .desktop files."
        else
            find "$HOME/.local/share/applications" -name "*pamac*distrobox*" -delete 2>/dev/null || true
            find "$HOME/.local/share/applications" -name "*$CONTAINER_NAME*" -delete 2>/dev/null || true
            update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true
            log_success "Exported applications removed."
        fi
    fi
    
    if [ "$DRY_RUN" != "true" ]; then
        read -p "Also remove BoxBuddy? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if flatpak info --user io.github.dvlv.BoxBuddy &>/dev/null; then
                 if run_command flatpak uninstall --user -y io.github.dvlv.BoxBuddy; then
                    log_success "BoxBuddy removed."
                 else
                    log_error "Failed to remove BoxBuddy."
                 fi
            fi
        fi
    else
        log_warn "[DRY RUN] Would prompt to remove BoxBuddy."
    fi
    
    log_success "Uninstallation complete."
}

cleanup_on_failure() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Setup failed with exit code $exit_code. An error occurred on line $BASH_LINENO."
        if [ "$CONTAINER_WAS_CREATED_BY_SCRIPT" = "true" ]; then
            log_warn "Cleaning up partially created container '$CONTAINER_NAME'..."
            run_command distrobox rm "$CONTAINER_NAME" --force
            log_success "Cleanup complete."
        else
            log_warn "An error occurred, but the container existed before this script ran, so it was not removed."
        fi
        log_info "Check the log for details: ${LOG_FILE}"
    fi
}

wait_for_container() {
    local container_name="$1"
    local max_attempts=60
    local attempt=1
    log_info "Waiting for container to be ready..."
    while [ $attempt -le $max_attempts ]; do
        if distrobox enter "$container_name" -- whoami &>/dev/null; then
            log_success "Container is ready."
            return 0
        fi
        [ "$LOG_LEVEL" != "quiet" ] && echo -n "."
        sleep 2
        ((attempt++))
    done
    echo ""
    log_error "Container failed to become ready after $max_attempts attempts."
    return 1
}

check_steamos_version() {
    if [ -f "/etc/os-release" ]; then
        if grep -q "VERSION_ID" "/etc/os-release" && grep -q "ID=steamos"; then
            local version_id
            version_id=$(grep "VERSION_ID" "/etc/os-release" | cut -d'=' -f2 | tr -d '"')
            local major minor
            major=$(echo "$version_id" | cut -d'.' -f1)
            minor=$(echo "$version_id" | cut -d'.' -f2)
            if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 5 ]; }; then
                log_warn "SteamOS version is older than 3.5. Some features may not work as expected."
            fi
        fi
    fi
}

# --- Core Logic Functions ---
# Note on Modularity: For larger projects, the 'cat <<EOF' sections below would be ideal candidates
# for refactoring into separate .sh files. For this self-contained script, keeping them inline
# ensures simplicity of distribution and execution without external dependencies.

configure_mirrors() {
    if [ "$CONFIGURE_MIRRORS" = "true" ]; then
        log_step "Configuring fastest mirrors for countries: $MIRROR_COUNTRIES..."
        local script_content
        script_content=$(cat <<'EOF'
#!/bin/bash
set -e
COUNTRIES="$1"
sudo pacman -S --noconfirm --needed reflector
sudo reflector --country "$COUNTRIES" --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
EOF
        )
        if echo "$script_content" | run_command distrobox enter "$CONTAINER_NAME" -- bash -s "$MIRROR_COUNTRIES"; then
            log_success "Mirrors configured."
        else
            log_warn "Mirror configuration failed, continuing..."
        fi
    fi
}

configure_locale() {
    if [ "$CONFIGURE_LOCALE" = "true" ]; then
        log_step "Configuring system locale to $TARGET_LOCALE..."
        export TARGET_LOCALE
        local script_content
        script_content=$(cat <<'EOF'
#!/bin/bash
set -e
sudo sed -i "s/^#\s*${TARGET_LOCALE}/${TARGET_LOCALE}/" /etc/locale.gen
sudo locale-gen
echo "LANG=${TARGET_LOCALE}" | sudo tee /etc/locale.conf
EOF
        )
        if echo "$script_content" | envsubst | run_command distrobox enter "$CONTAINER_NAME" -- bash -s; then
            log_success "Locale configured to $TARGET_LOCALE."
        else
            log_warn "Locale configuration failed, continuing..."
        fi
    fi
}

configure_multilib() {
    if [ "$ENABLE_MULTILIB" = "true" ]; then
        log_step "Enabling multilib repository..."
        local script_content
        script_content=$(cat <<'EOF'
#!/bin/bash
set -e
if grep -q "^\[multilib\]" /etc/pacman.conf; then
    echo "Multilib is already enabled."
    exit 0
fi
sudo bash -c 'printf "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" >> /etc/pacman.conf'
sudo pacman -Sy
EOF
        )
        if echo "$script_content" | run_command distrobox enter "$CONTAINER_NAME" -- bash -s; then
            log_success "Multilib repository enabled."
        else
            log_warn "Multilib configuration failed, continuing..."
        fi
    fi
}

setup_build_cache() {
    if [ "$ENABLE_BUILD_CACHE" = "true" ]; then
        log_step "Setting up persistent build cache..."
        run_command mkdir -p "$HOME/.cache/yay" "$HOME/.cache/pacman/pkg"
        
        local script_content
        script_content=$(cat <<'EOF'
#!/bin/bash
set -e
mkdir -p ~/.config/yay
cat > ~/.config/yay/config.json << YAY_EOF
{ "buildDir": "/home/$(whoami)/.cache/yay" }
YAY_EOF
sudo sed -i 's|^#CacheDir.*|CacheDir = /home/'$(whoami)'/.cache/pacman/pkg/|' /etc/pacman.conf
EOF
        )
        if echo "$script_content" | run_command distrobox enter "$CONTAINER_NAME" -- bash -s; then
            log_success "Build cache configured."
        else
            log_warn "Build cache configuration failed, continuing..."
        fi
    fi
}

install_gaming_packages() {
    if [ "$ENABLE_GAMING_PACKAGES" = "true" ]; then
        log_step "Installing gaming-related packages..."
        local script_content
        script_content=$(cat <<'EOF'
#!/bin/bash
set -e
PACKAGES=( "wine" "winetricks" "lutris" "steam" "gamemode" "lib32-gamemode" "mangohud" "lib32-mangohud" "discord" "obs-studio" )
yay -S --noconfirm --needed "${PACKAGES[@]}"
EOF
        )
        if echo "$script_content" | run_command distrobox enter "$CONTAINER_NAME" -- bash -s; then
            log_success "Gaming packages installed."
        else
            log_warn "Some gaming packages may have failed to install."
        fi
    fi
}

export_additional_gui_apps() {
    if [ "$AUTO_EXPORT_APPS" = "true" ]; then
        log_step "Finding and exporting additional repository applications..."
        local export_script
        export_script=$(cat <<'EOF'
#!/bin/bash
APPLICATIONS_DIR="$HOME/.local/share/applications"
find /usr/share/applications -name "*.desktop" -type f | while read -r desktop_file; do
    app_name=$(basename "$desktop_file" .desktop)
    if [ -f "${APPLICATIONS_DIR}/${app_name}.desktop" ] || [ -f "${APPLICATIONS_DIR}/${app_name}-distrobox.desktop" ]; then continue; fi
    case "$app_name" in
        org.freedesktop.*|systemd-*|dbus-*|gparted|htop|pamac-manager|pamac-gtk|yad*|avahi-discover|bssh|bvnc) continue ;;
    esac
    if grep -q "^Type=Application" "$desktop_file" && ! grep -q -E "^Terminal=true|NoDisplay=true" "$desktop_file"; then
        if distrobox-export --app "$app_name" --extra-flags "--no-sandbox"; then
            echo "$app_name"
        fi
    fi
done
EOF
        )
        if [ "$DRY_RUN" = "true" ]; then
            log_warn "[DRY RUN] Would attempt to find and export additional GUI apps."
            return
        fi

        local newly_exported
        newly_exported=$(echo "$export_script" | distrobox enter "$CONTAINER_NAME" -- bash -s 2>>"$LOG_FILE")
        if [ -n "$newly_exported" ]; then
            log_success "Automatically exported additional repository apps."
            while IFS= read -r app; do EXPORTED_APPS+=("$app"); done <<< "$newly_exported"
        else
            log_info "No new repository applications were found to export."
        fi
    fi
}

export_flatpak_apps() {
    if [ "$AUTO_EXPORT_FLATPAKS" = "true" ]; then
        log_step "Finding and exporting additional Flatpak applications..."
        local export_script
        export_script=$(cat <<'EOF'
#!/bin/bash
APPLICATIONS_DIR="$HOME/.local/share/applications"
if ! command -v flatpak &>/dev/null; then exit 0; fi
flatpak list --app --columns=application | grep -vE '(\.Platform|\.Locale|\.Sources)$' | while read -r app_id; do
    if [ -f "${APPLICATIONS_DIR}/${app_id}.desktop" ] || [ -f "${APPLICATIONS_DIR}/${app_id}-distrobox.desktop" ]; then continue; fi
    if distrobox-export --app "$app_id" --extra-flags "--no-sandbox"; then
        echo "$app_id"
    fi
done
EOF
        )
        if [ "$DRY_RUN" = "true" ]; then
            log_warn "[DRY RUN] Would attempt to find and export Flatpak apps."
            return
        fi

        local newly_exported
        newly_exported=$(echo "$export_script" | distrobox enter "$CONTAINER_NAME" -- bash -s 2>>"$LOG_FILE")
        if [ -n "$newly_exported" ]; then
            log_success "Automatically exported Flatpak apps."
            while IFS= read -r app; do EXPORTED_APPS+=("$app"); done <<< "$newly_exported"
        else
            log_info "No new Flatpak applications were found to export."
        fi
    fi
}

clean_caches() {
    if [ "$ENABLE_BUILD_CACHE" = "false" ]; then
        log_step "Cleaning package caches..."
        if run_command distrobox enter "$CONTAINER_NAME" -- sudo pacman -Scc --noconfirm; then
            log_success "Package caches cleaned to save space."
        else
            log_warn "Failed to clean package caches."
        fi
    fi
}

# --- Main Execution ---
main() {
    initialize_logging
    parse_arguments "$@"
    trap 'cleanup_on_failure' ERR

    echo -e "${BOLD}${BLUE}🚀 Steam Deck Persistent AUR Package Manager Setup v${SCRIPT_VERSION}${NC}"
    echo -e "${YELLOW}Container: $CONTAINER_NAME${NC}"
    log_info "A detailed log will be saved to: ${LOG_FILE}\n"
    if [ "$DRY_RUN" = "true" ]; then
        log_warn "[DRY RUN MODE ENABLED]: No changes will be made."
    fi

    check_steamos_version

    log_step "Step 1: Checking for required host tools..."
    for cmd in distrobox podman flatpak; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required tool not found: $cmd. Please ensure SteamOS is up to date."
            exit 1
        fi
    done
    log_success "All required host tools are available."

    log_step "Step 2: Setting up '$CONTAINER_NAME' container..."
    if distrobox list --no-color 2>/dev/null | grep -q " $CONTAINER_NAME "; then
        if [ "$FORCE_REBUILD" = "true" ]; then
            log_warn "Container '$CONTAINER_NAME' exists and --force-rebuild is set. Removing it now."
            if run_command distrobox rm "$CONTAINER_NAME" --force; then
                log_success "Existing container removed."
            else
                log_error "Failed to remove existing container. Aborting."
                exit 1
            fi
        else
            log_success "Container already exists. To rebuild it, use --force-rebuild."
        fi
    fi

    if ! distrobox list --no-color 2>/dev/null | grep -q " $CONTAINER_NAME "; then
        log_info "Container '$CONTAINER_NAME' not found or was removed. Creating it now..."
        VOLUME_ARGS=""
        if [ "$ENABLE_BUILD_CACHE" = "true" ]; then
            run_command mkdir -p "$HOME/.cache/yay" "$HOME/.cache/pacman/pkg"
            VOLUME_ARGS="--volume $HOME/.cache/yay:/home/$CURRENT_USER/.cache/yay:rw --volume $HOME/.cache/pacman/pkg:/var/cache/pacman/pkg:rw"
        fi
        
        if ! run_command distrobox create --name "$CONTAINER_NAME" --image archlinux:latest --yes $VOLUME_ARGS; then
            log_error "Failed to create container. Check the log for details."
            exit 1
        fi
        CONTAINER_WAS_CREATED_BY_SCRIPT="true"
        if ! wait_for_container "$CONTAINER_NAME"; then exit 1; fi
        log_success "Container created successfully."
    fi
    
    log_step "Step 3: Configuring container base environment..."
    local config_script
    config_script=$(cat << 'EOF'
#!/bin/bash
set -e
groupadd -f wheel
usermod -aG wheel "$(whoami)"
echo '%wheel ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/99-wheel-nopasswd
sudo chmod 440 /etc/sudoers.d/99-wheel-nopasswd
sudo pacman-key --init && sudo pacman-key --populate archlinux
EOF
    )
    if ! echo "$config_script" | run_command distrobox enter "$CONTAINER_NAME" -- bash -s; then
        log_error "Failed to configure container base environment."
        exit 1
    fi
    log_success "Container base environment configured."

    log_step "Step 4: Applying feature configurations..."
    configure_mirrors
    configure_locale
    configure_multilib
    setup_build_cache

    log_step "Step 5: Installing Pamac inside '$CONTAINER_NAME'..."
    local install_script
    install_script=$(cat <<'EOF'
#!/bin/bash
set -e
if pacman -Qs pamac-aur &>/dev/null; then
    echo "Pamac is already installed. Ensuring AUR is enabled."
    sudo sed -i 's/^#EnableAUR/EnableAUR/' /etc/pamac.conf
    exit 0
fi
echo "Updating system and installing dependencies..."
sudo pacman -Syu --noconfirm --needed git base-devel
if ! command -v yay &>/dev/null; then
    echo "Installing yay AUR helper..."
    git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm && cd .. && rm -rf yay-bin
fi
echo "Installing Pamac GUI from AUR..."
yay -S --noconfirm --needed pamac-aur
sudo sed -i 's/^#EnableAUR/EnableAUR/' /etc/pamac.conf
EOF
    )
    if ! echo "$install_script" | run_command distrobox enter "$CONTAINER_NAME" -- bash -s; then
        log_error "Pamac installation failed."
        exit 1
    fi
    log_success "Pamac installation complete."
    
    install_gaming_packages

    log_step "Step 6: Exporting Pamac to the SteamOS menu..."
    if ! run_command distrobox-export --app pamac-manager --extra-flags "--no-sandbox"; then
        log_warn "distrobox-export failed. Creating manual .desktop file."
        export CONTAINER_NAME
        echo | envsubst '$CONTAINER_NAME' > "$HOME/.local/share/applications/pamac-manager-distrobox.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Pamac Package Manager
Comment=Add or remove software installed in $CONTAINER_NAME
Icon=pamac-manager
Exec=distrobox enter $CONTAINER_NAME -- pamac-manager
Terminal=false
Categories=System;PackageManager;
EOF
    fi
    run_command update-desktop-database -q "$HOME/.local/share/applications"
    log_success "Pamac is available in the application menu."

    log_step "Step 7: Installing BoxBuddy for container management..."
    if ! flatpak info --user io.github.dvlv.BoxBuddy &>/dev/null; then
        run_command flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
        if run_command flatpak install --user -y flathub io.github.dvlv.BoxBuddy; then
            log_success "BoxBuddy installed."
        else
            log_warn "BoxBuddy installation failed (this is optional)."
        fi
    else
        log_success "BoxBuddy is already installed."
    fi

    log_step "Step 8: Exporting additional applications..."
    export_additional_gui_apps
    export_flatpak_apps

    log_step "Step 9: Final verification..."
    local verify_script
    verify_script=$(cat <<'EOF'
#!/bin/bash
errors=0
check_cmd() { command -v "$1" &>/dev/null || { echo "❌ command '$1' not found."; ((errors++)); }; }
check_pkg() { pacman -Qs "$1" &>/dev/null || { echo "❌ package '$1' not installed."; ((errors++)); }; }
check_conf() { grep -q "^$2" "$1" && ! grep -q "^#$2" "$1" || { echo "❌ '$2' not enabled in $1."; ((errors++)); }; }
check_cmd yay; check_cmd pamac-manager; check_pkg pamac-aur; check_conf /etc/pamac.conf EnableAUR
exit $errors
EOF
    )
    if echo "$verify_script" | run_command distrobox enter "$CONTAINER_NAME" -- bash -s; then
        log_success "All components verified successfully!"
    else
        log_error "Installation verification failed. Check the log for specific errors."
    fi
    
    log_step "Step 10: Finalizing..."
    clean_caches
    
    echo -e "\n${BOLD}${GREEN}🎉 SETUP COMPLETE! 🎉${NC}"
    echo -e "${GREEN}Enhanced Pamac with AUR support is now installed and ready to use.${NC}"
    echo ""
    echo -e "${BOLD}${YELLOW}FEATURES ENABLED:${NC}"
    [ "$ENABLE_MULTILIB" = "true" ] && echo -e "  ✓ ${GREEN}Multilib repository (32-bit app support)${NC}"
    [ "$ENABLE_BUILD_CACHE" = "true" ] && echo -e "  ✓ ${GREEN}Persistent build cache${NC}"
    [ "$CONFIGURE_MIRRORS" = "true" ] && echo -e "  ✓ ${GREEN}Optimized mirror configuration ($MIRROR_COUNTRIES)${NC}"
    [ "$AUTO_EXPORT_APPS" = "true" ] && echo -e "  ✓ ${GREEN}Repo App Auto-Export${NC}"
    [ "$AUTO_EXPORT_FLATPAKS" = "true" ] && echo -e "  ✓ ${GREEN}Flatpak App Auto-Export${NC}"
    [ "$ENABLE_GAMING_PACKAGES" = "true" ] && echo -e "  ✓ ${GREEN}Gaming packages installed${NC}"
    [ "$CONFIGURE_LOCALE" = "true" ] && echo -e "  ✓ ${GREEN}Locale configured ($TARGET_LOCALE)${NC}"
    [ "$ENABLE_BUILD_CACHE" = "false" ] && echo -e "  ✓ ${GREEN}Build Cache Cleaning${NC}"
    
    if [ ${#EXPORTED_APPS[@]} -gt 0 ]; then
        echo -e "\n${BOLD}${YELLOW}AUTO-EXPORTED APPS:${NC}"
        for app in "${EXPORTED_APPS[@]}"; do
            echo -e "  - $app"
        done
    fi

    echo ""
    echo -e "${BOLD}${YELLOW}ACCESS METHODS:${NC}"
    echo -e "  🖥️  Desktop Mode: Application Launcher → '${GREEN}Pamac Package Manager${NC}'"
    echo -e "  🛠️  Management: Use '${GREEN}BoxBuddy${NC}' for advanced container operations"
    echo ""
    echo -e "${BOLD}${YELLOW}USEFUL COMMANDS:${NC}"
    echo -e "  Update script: ${GREEN}./$(basename "$0") --update${NC}"
    echo -e "  Uninstall:     ${GREEN}./$(basename "$0") --uninstall${NC}"
    echo ""
    echo -e "${BOLD}${YELLOW}PRO-TIPS:${NC}"
    echo -e "  To improve compatibility for some GUI apps (especially Flatpaks), you can"
    echo -e "  give them access to the host display server with this command:"
    echo -e "  ${GREEN}flatpak override --user --env=DISPLAY=:0 <app-id>${NC}"
}

# Run main function with all arguments
main "$@"
