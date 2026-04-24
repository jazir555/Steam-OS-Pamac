#!/bin/bash

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-arch-pamac}"
LOG_FILE="$HOME/pamac-uninstall.log"

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; BOLD=''; NC=''
fi

init_logging() {
    echo "=== Pamac Uninstaller - $(date) ===" > "$LOG_FILE"
    echo "User: $(whoami)" >> "$LOG_FILE"
    echo "Container: $CONTAINER_NAME" >> "$LOG_FILE"
    trap 'echo "=== Uninstall finished at $(date) ===" >> "$LOG_FILE"' EXIT
}

log_info() { echo -e "$1" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}✓ $1${NC}" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}⚠ $1${NC}" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}✗ $1${NC}" | tee -a "$LOG_FILE"; }

remove_container() {
    log_info "\n${BOLD}Removing container '$CONTAINER_NAME'...${NC}"

    if distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        export_list=$(distrobox-export --list 2>/dev/null | grep "$CONTAINER_NAME" || true)
        if [[ -n "$export_list" ]]; then
            log_info "Removing exported applications..."
            while IFS= read -r line; do
                app_name=$(echo "$line" | awk '{print $2}' | tr -d '\n')
                if [[ -n "$app_name" ]]; then
                    log_info "Un-exporting: $app_name"
                    distrobox-export --app "$app_name" --delete --container "$CONTAINER_NAME" 2>/dev/null || true
                fi
            done <<< "$export_list"
        fi

        distrobox stop "$CONTAINER_NAME" &>> "$LOG_FILE" || true
        if distrobox rm -f "$CONTAINER_NAME" &>> "$LOG_FILE"; then
            log_success "Container removed"
        else
            log_error "Failed to remove container"
            return 1
        fi
    else
        log_warn "Container not found - skipping removal"
    fi
}

remove_exported_apps() {
    log_info "\n${BOLD}Cleaning up application shortcuts...${NC}"
    local app_dir="$HOME/.local/share/applications"
    local count=0

    if [[ -d "$app_dir" ]]; then
        find "$app_dir" -maxdepth 1 -type f -name "*.desktop" -exec \
            grep -l "distrobox enter ${CONTAINER_NAME}" {} \; 2>/dev/null | while read -r f; do
            rm -f "$f" 2>/dev/null
            count=$((count + 1))
        done
        find "$app_dir" -maxdepth 1 -type f -name "*-${CONTAINER_NAME}.desktop" -delete 2>/dev/null || true
        find "$app_dir" -maxdepth 1 -type f -name "*pamac*.desktop" -exec \
            grep -l "X-Distrobox-Container=${CONTAINER_NAME}" {} \; 2>/dev/null | xargs -r rm -f 2>/dev/null || true

        if command -v update-desktop-database &>/dev/null; then
            update-desktop-database "$app_dir" &>> "$LOG_FILE" || true
        fi
    fi

    log_success "Application shortcuts removed"
}

clean_wrappers_and_icons() {
    log_info "\n${BOLD}Cleaning CLI wrappers and icons...${NC}"
    rm -f "$HOME/.local/bin/pamac-$CONTAINER_NAME" &>> "$LOG_FILE" || true
    rm -f "$HOME/.local/share/icons/hicolor/scalable/apps/pamac-manager.svg" &>> "$LOG_FILE" || true
    rm -f "$HOME/.local/share/icons/hicolor/48x48/apps/pamac-manager.png" &>> "$LOG_FILE" || true

    command -v gtk-update-icon-cache >/dev/null 2>&1 && \
        gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" -f 2>/dev/null || true

    log_success "CLI wrappers and icons removed"
}

clean_caches() {
    log_info "\n${BOLD}Cleaning leftover files...${NC}"
    rm -rf "$HOME/.cache/yay-${CONTAINER_NAME}" &>> "$LOG_FILE" || true
    log_success "Cache files removed"
}

show_header() {
    clear
    echo -e "${BOLD}Steam Deck Pamac Uninstaller${NC}"
    echo -e "This will remove:"
    echo -e "  ${BOLD}Pamac package manager${NC} container ($CONTAINER_NAME)"
    echo -e "  All ${BOLD}exported application shortcuts${NC}"
    echo -e "  Build caches and temporary files"
    echo -e "\n${YELLOW}Note: Installed packages INSIDE the container will be deleted.${YELLOW}"
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

init_logging
show_header
confirm_uninstall

remove_container
remove_exported_apps
clean_wrappers_and_icons
clean_caches

echo -e "\n${BOLD}${GREEN}Uninstallation complete!${NC}"
echo -e "Pamac and its components have been removed from your system."
