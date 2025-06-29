#!/bin/bash

# Steam Deck Pamac Uninstaller v1.0
# Removes Distrobox container and all associated applications
# Preserves installed packages in container if you want to keep using it

# --- Configuration ---
CONTAINER_NAME="${CONTAINER_NAME:-arch-box}"  # Must match install script's container name
USER_HOME="$HOME"
LOG_FILE="$USER_HOME/pamac-uninstall.log"

# --- Color Codes ---
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  RED='\033[0;31m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BOLD=''; NC=''
fi

# --- Logging Functions ---
init_logging() {
  echo "=== Pamac Uninstaller - $(date) ===" > "$LOG_FILE"
  echo "User: $(whoami)" >> "$LOG_FILE"
  echo "SteamOS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2)" >> "$LOG_FILE"
  echo "Container: $CONTAINER_NAME" >> "$LOG_FILE"
  trap 'echo "=== Uninstall finished at $(date) ===" >> "$LOG_FILE"' EXIT
}

log_info() { echo -e "$1" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}✓ $1${NC}" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}⚠️ $1${NC}" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}❌ $1${NC}" | tee -a "$LOG_FILE"; }

# --- Main Functions ---
remove_container() {
  log_info "\n${BOLD}Removing container '$CONTAINER_NAME'...${NC}"
  if distrobox list | grep -qw "$CONTAINER_NAME"; then
    if distrobox rm "$CONTAINER_NAME" --force &>> "$LOG_FILE"; then
      log_success "Container removed"
    else
      log_error "Failed to remove container (may still be running)"
      return 1
    fi
  else
    log_warn "Container not found - skipping removal"
  fi
}

remove_exported_apps() {
  log_info "\n${BOLD}Cleaning up application shortcuts...${NC}"
  local app_dir="$USER_HOME/.local/share/applications"
  local count=0
  
  # Pamac launchers
  find "$app_dir" -type f \( -name "*pamac*distrobox*" -o -name "*pamac-manager*" \) -delete &>> "$LOG_FILE"
  
  # Container-specific apps
  find "$app_dir" -type f -name "*$CONTAINER_NAME*" -delete &>> "$LOG_FILE"
  
  # Update desktop database if command exists
  if command -v update-desktop-database &>/dev/null; then
    update-desktop-database "$app_dir" &>> "$LOG_FILE"
  fi
  
  log_success "Application shortcuts removed"
}

remove_boxbuddy() {
  log_info "\n${BOLD}Checking for BoxBuddy...${NC}"
  if flatpak list --app | grep -q "io.github.dvlv.BoxBuddy"; then
    read -p "Remove BoxBuddy? (y/N): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
      if flatpak uninstall --user -y io.github.dvlv.BoxBuddy &>> "$LOG_FILE"; then
        log_success "BoxBuddy removed"
      else
        log_warn "Failed to remove BoxBuddy"
      fi
    else
      log_info "Keeping BoxBuddy installed"
    fi
  else
    log_info "BoxBuddy not installed - skipping"
  fi
}

clean_caches() {
  log_info "\n${BOLD}Cleaning leftover files...${NC}"
  # Remove build caches
  rm -rf "$USER_HOME/.cache/yay" "$USER_HOME/.cache/pacman/pkg" &>> "$LOG_FILE"
  
  # Remove container config
  rm -rf "$USER_HOME/.local/share/distrobox/containers/$CONTAINER_NAME" &>> "$LOG_FILE"
  
  log_success "Cache files removed"
}

# --- Uninstallation Flow ---
show_header() {
  clear
  echo -e "${BOLD}Steam Deck Pamac Uninstaller${NC}"
  echo -e "This will remove:"
  echo -e "  • ${BOLD}Pamac package manager${NC} container ($CONTAINER_NAME)"
  echo -e "  • All ${BOLD}exported application shortcuts${NC}"
  echo -e "  • Optionally remove BoxBuddy"
  echo -e "  • Build caches and temporary files"
  echo -e "\n${YELLOW}Note: Your installed packages INSIDE the container will be deleted.${NC}"
  echo -e "${YELLOW}If you want to keep any installed software, migrate it first.${NC}"
  echo -e "\nLog file: ${BOLD}$LOG_FILE${NC}"
  echo -e "\n----------------------------------------------"
}

confirm_uninstall() {
  read -p "Are you sure you want to uninstall? (y/N): " choice
  if [[ ! "$choice" =~ ^[Yy]$ ]]; then
    log_info "Uninstallation canceled"
    exit 0
  fi
}

# --- Main Execution ---
init_logging
show_header
confirm_uninstall

(
  remove_container
  remove_exported_apps
  remove_boxbuddy
  clean_caches
)

echo -e "\n${BOLD}${GREEN}Uninstallation complete!${NC}"
echo -e "Pamac and its components have been removed from your system."
echo -e "You may now safely delete this uninstall script.\n"
