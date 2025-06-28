#!/bin/bash

# Enhanced Steam Deck Pamac Setup Script
# This script automates the setup of a persistent, GUI-based package management
# system (Pamac with AUR) on SteamOS using Distrobox.
# It is idempotent, fully automated, and requires no user input after execution.
#
# WHY THIS DOES NOT REQUIRE DEVELOPER MODE:
# This script is carefully designed to work on a standard Steam Deck (SteamOS 3.5+).
# 1. It relies on pre-installed tools (Podman, Distrobox) and never tries to modify host packages.
# 2. All files (container data, app launchers, logs) are written exclusively to the user's home directory.
# 3. It uses user-level Flatpak commands, which do not touch the read-only system root.

# Stop on any error
set -e

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

# --- Variables & Setup ---
CONTAINER_NAME="arch-box"
CURRENT_USER=$(whoami) # Usually 'deck' on Steam Deck
LOG_FILE="$HOME/distrobox-pamac-setup.log"
SCRIPT_VERSION="2.0"

# --- Logging and Exit Handling ---
# Initialize log file with a timestamp
echo "=== Steam Deck Pamac Setup v${SCRIPT_VERSION} - Run started at: $(date) ===" > "$LOG_FILE"
echo "User: $CURRENT_USER" >> "$LOG_FILE"
echo "System: $(uname -a)" >> "$LOG_FILE"
echo "SteamOS Version: $(cat /etc/os-release | grep VERSION_ID | cut -d'=' -f2 | tr -d '\"' 2>/dev/null || echo 'Unknown')" >> "$LOG_FILE"
echo "===========================================" >> "$LOG_FILE"

# Ensure a final message is logged when the script exits, for any reason
trap 'echo "=== Run finished at: $(date) - Exit code: $? ===" >> "$LOG_FILE"' EXIT

# --- Helper Functions ---
log_and_echo() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

log_only() {
    echo -e "$1" >> "$LOG_FILE"
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

trap cleanup_on_failure ERR

# --- Pre-flight Checks ---
echo -e "${BOLD}${BLUE}🚀 Steam Deck Persistent AUR Package Manager Setup v${SCRIPT_VERSION}${NC}"
echo -e "${YELLOW}This script will set up an Arch Linux container with Pamac and AUR support.${NC}"
echo -e "A detailed log will be saved to: ${LOG_FILE}\n"

# Check if running on Steam Deck
if [ "$CURRENT_USER" != "deck" ] && [ ! -f "/etc/steamos-release" ]; then
    log_and_echo "${YELLOW}Warning: This script is designed for Steam Deck/SteamOS but will continue...${NC}"
fi

# Check SteamOS version
if ! check_steamos_version; then
    log_and_echo "${YELLOW}Warning: SteamOS version may be too old. Recommended: 3.5+${NC}"
fi

# Step 1: Check for Host Dependencies
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
    log_and_echo "You may need to run: sudo steamos-update"
    exit 1
fi
echo -e "${GREEN}✓ All required host tools are available.${NC}\n"

# Step 1.5: Verify and Initialize Podman
echo -e "${BLUE}Step 1.5: Verifying Podman functionality...${NC}"
if ! podman info &>> "$LOG_FILE"; then
    log_and_echo "${YELLOW}Podman needs initialization. Setting up...${NC}"
    
    # Initialize podman machine if needed
    if ! podman machine list 2>/dev/null | grep -q "podman-machine-default"; then
        log_and_echo "Initializing Podman machine..."
        podman machine init &>> "$LOG_FILE" || true
    fi
    
    # Start podman machine if needed
    if ! podman machine list 2>/dev/null | grep -q "Currently running"; then
        log_and_echo "Starting Podman machine..."
        podman machine start &>> "$LOG_FILE" || true
    fi
    
    # Final check
    if ! podman info &>> "$LOG_FILE"; then
        log_and_echo "${RED}Podman is not functioning properly. Check the log for details.${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}✓ Podman is working correctly.${NC}\n"

# Step 2: Create Container if it Doesn't Exist
echo -e "${BLUE}Step 2: Setting up '$CONTAINER_NAME' container...${NC}"
if ! distrobox list --no-color 2>/dev/null | grep -q " $CONTAINER_NAME "; then
    log_and_echo "Container '$CONTAINER_NAME' not found. Creating it now..."
    log_and_echo "This may take several minutes for the first run..."
    
    # Create with additional options for better reliability
    if ! distrobox create \
        --name "$CONTAINER_NAME" \
        --image archlinux:latest \
        --pull \
        --yes \
        --additional-packages "systemd" \
        --init-hooks "systemctl --user enable --now podman.socket" \
        --home "$HOME" \
        --volume /tmp:/tmp:rw \
        --volume /dev:/dev:rw \
        --volume /sys:/sys:ro \
        --volume /run/user/$(id -u):/run/user/$(id -u):rw &>> "$LOG_FILE"; then
        log_and_echo "${RED}Failed to create container. Check the log for details: ${LOG_FILE}${NC}"
        exit 1
    fi
    
    # Wait for container to be ready
    if ! wait_for_container "$CONTAINER_NAME"; then
        log_and_echo "${RED}Container creation failed or timed out.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ '$CONTAINER_NAME' container created successfully.${NC}"
else
    echo -e "${GREEN}✓ Container '$CONTAINER_NAME' already exists.${NC}"
    
    # Ensure existing container is running
    if ! distrobox enter "$CONTAINER_NAME" -- echo "test" &>/dev/null; then
        log_and_echo "Starting existing container..."
        distrobox enter "$CONTAINER_NAME" -- echo "Container started" &>> "$LOG_FILE"
    fi
fi
echo ""

# Step 3: Configure Container for Automation
echo -e "${BLUE}Step 3: Configuring container for passwordless operations...${NC}"
TEMP_CONFIG_SCRIPT=$(mktemp)
cat > "$TEMP_CONFIG_SCRIPT" << 'CONFIG_SCRIPT_EOF'
#!/bin/bash
set -e

# Get current user
CURRENT_USER="$1"

# Ensure wheel group exists
groupadd -f wheel

# Add user to wheel group
usermod -aG wheel "$CURRENT_USER"

# Create sudoers file for passwordless sudo
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-wheel-nopasswd
chmod 440 /etc/sudoers.d/99-wheel-nopasswd

# Validate sudoers file
visudo -c -f /etc/sudoers.d/99-wheel-nopasswd

# Initialize pacman keyring
pacman-key --init || true
pacman-key --populate archlinux || true

echo 'Container configuration complete'
CONFIG_SCRIPT_EOF

if ! distrobox enter "$CONTAINER_NAME" --root -- bash "$TEMP_CONFIG_SCRIPT" "$CURRENT_USER" &>> "$LOG_FILE"; then
    log_and_echo "${RED}Failed to configure container for automation.${NC}"
    rm -f "$TEMP_CONFIG_SCRIPT"
    exit 1
fi
rm -f "$TEMP_CONFIG_SCRIPT"
echo -e "${GREEN}✓ Container configured for automation.${NC}\n"

# Step 4: Install Pamac Inside the Container
echo -e "${BLUE}Step 4: Installing Pamac inside '$CONTAINER_NAME'...${NC}"
TEMP_INSTALL_SCRIPT=$(mktemp)
cat > "$TEMP_INSTALL_SCRIPT" << 'INSTALL_SCRIPT_EOF'
#!/bin/bash
set -e

# Color codes for container output
GREEN_IN='\033[0;32m'; YELLOW_IN='\033[1;33m'; BLUE_IN='\033[0;34m'; RED_IN='\033[0;31m'; NC_IN='\033[0m'

echo -e "${BLUE_IN}--- Installing Pamac in container ---${NC_IN}"

# Function to check if package is installed
is_installed() {
    pacman -Qi "$1" &>/dev/null
}

# Check if pamac is already installed
if is_installed pamac-aur || is_installed pamac-gtk; then
    echo -e "${GREEN_IN}Pamac is already installed. Checking configuration...${NC_IN}"
    
    # Ensure AUR is enabled
    if [ -f /etc/pamac.conf ]; then
        sudo sed -i 's/^#EnableAUR/EnableAUR/' /etc/pamac.conf
        sudo sed -i 's/^#CheckAURUpdates/CheckAURUpdates/' /etc/pamac.conf
    fi
    
    echo -e "${GREEN_IN}Pamac is properly configured.${NC_IN}"
    exit 0
fi

echo -e "${YELLOW_IN}Installing Pamac and dependencies...${NC_IN}"

# Update package database
echo -e "${YELLOW_IN}Updating package database...${NC_IN}"
sudo pacman -Sy --noconfirm

# Install essential packages
echo -e "${YELLOW_IN}Installing build dependencies...${NC_IN}"
sudo pacman -S --needed --noconfirm git base-devel wget curl

# Install yay if not present
if ! command -v yay &>/dev/null; then
    echo -e "${YELLOW_IN}Installing yay AUR helper...${NC_IN}"
    
    # Create temporary directory
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    # Clone and build yay
    git clone https://aur.archlinux.org/yay-bin.git
    cd yay-bin
    
    # Build and install yay
    makepkg -si --noconfirm --needed
    
    # Cleanup
    cd /
    rm -rf "$TEMP_DIR"
    
    echo -e "${GREEN_IN}✓ yay installed successfully.${NC_IN}"
else
    echo -e "${GREEN_IN}✓ yay is already installed.${NC_IN}"
fi

# Install pamac-aur
echo -e "${YELLOW_IN}Installing Pamac GUI from AUR...${NC_IN}"
yay -S --noconfirm --needed pamac-aur

# Configure pamac for AUR support
echo -e "${YELLOW_IN}Configuring Pamac for AUR support...${NC_IN}"
if [ -f /etc/pamac.conf ]; then
    sudo sed -i 's/^#EnableAUR/EnableAUR/' /etc/pamac.conf
    sudo sed -i 's/^#CheckAURUpdates/CheckAURUpdates/' /etc/pamac.conf
    echo -e "${GREEN_IN}✓ AUR support enabled in Pamac.${NC_IN}"
else
    echo -e "${RED_IN}Warning: /etc/pamac.conf not found${NC_IN}"
fi

# Test pamac installation
if command -v pamac-manager &>/dev/null; then
    echo -e "${GREEN_IN}✓ Pamac installation verified successfully!${NC_IN}"
else
    echo -e "${RED_IN}✗ Pamac installation verification failed${NC_IN}"
    exit 1
fi

echo -e "${GREEN_IN}Pamac installation and configuration complete!${NC_IN}"
INSTALL_SCRIPT_EOF

if ! distrobox enter "$CONTAINER_NAME" -- bash "$TEMP_INSTALL_SCRIPT" 2>&1 | tee -a "$LOG_FILE"; then
    log_and_echo "${RED}Container setup failed. Please check the log for details: ${LOG_FILE}${NC}"
    rm -f "$TEMP_INSTALL_SCRIPT"
    exit 1
fi
rm -f "$TEMP_INSTALL_SCRIPT"
echo -e "${GREEN}✓ Pamac installation complete.${NC}\n"

# Step 5: Export Pamac to the Host Menu
echo -e "${BLUE}Step 5: Exporting Pamac to the SteamOS menu...${NC}"

# Ensure the applications directory exists
mkdir -p "$HOME/.local/share/applications"

# Export pamac-manager
export_success=false
for app_name in pamac-manager pamac-gtk; do
    if distrobox enter "$CONTAINER_NAME" -- which "$app_name" &>/dev/null; then
        echo -e "${YELLOW}Exporting $app_name...${NC}" | tee -a "$LOG_FILE"
        if distrobox-export --app "$app_name" --extra-flags "--no-sandbox" &>> "$LOG_FILE"; then
            export_success=true
            echo -e "${GREEN}✓ Successfully exported '$app_name' to your application launcher.${NC}"
            break
        else
            echo -e "${YELLOW}Failed to export $app_name, trying next...${NC}" | tee -a "$LOG_FILE"
        fi
    fi
done

if [ "$export_success" = false ]; then
    log_and_echo "${YELLOW}Warning: Automatic export failed. Creating manual desktop entry...${NC}"
    
    # Create manual desktop entry
    cat > "$HOME/.local/share/applications/pamac-manager-distrobox.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Pamac Package Manager
Comment=Add or remove software installed on your system
Icon=pamac-manager
Exec=distrobox enter $CONTAINER_NAME -- pamac-manager
Terminal=false
Categories=System;PackageManager;
Keywords=Updates;Install;Uninstall;Program;Software;
EOF
    
    echo -e "${GREEN}✓ Manual desktop entry created.${NC}"
fi

# Update desktop database
if [ -d "$HOME/.local/share/applications" ]; then
    update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true
fi
echo ""

# Step 6: Install BoxBuddy for Easy App Management
echo -e "${BLUE}Step 6: Installing BoxBuddy for easy app management...${NC}"
FLATPAK_ID="io.github.dvlv.BoxBuddy"

# Check if flatpak is properly configured
if ! flatpak remotes --user | grep -q "flathub"; then
    log_and_echo "Adding Flathub remote..."
    if ! flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo &>> "$LOG_FILE"; then
        log_and_echo "${YELLOW}Failed to add Flathub remote. BoxBuddy installation will be skipped.${NC}"
    fi
fi

if ! flatpak info --user "$FLATPAK_ID" &>/dev/null; then
    log_and_echo "Installing BoxBuddy from Flathub..."
    if flatpak install --user -y flathub "$FLATPAK_ID" &>> "$LOG_FILE"; then
        echo -e "${GREEN}✓ BoxBuddy installed successfully.${NC}"
    else
        log_and_echo "${YELLOW}BoxBuddy installation failed. This is optional, so setup will continue.${NC}"
    fi
else
    echo -e "${GREEN}✓ BoxBuddy is already installed.${NC}"
fi
echo ""

# Step 7: Final Verification
echo -e "${BLUE}Step 7: Verifying installation...${NC}"
verification_issues=()

# Check if container exists and is working
if ! distrobox list --no-color 2>/dev/null | grep -q " $CONTAINER_NAME "; then
    verification_issues+=("Container '$CONTAINER_NAME' not found")
elif ! distrobox enter "$CONTAINER_NAME" -- echo "test" &>/dev/null; then
    verification_issues+=("Container '$CONTAINER_NAME' is not responding")
fi

# Check if pamac is installed and working in container
if ! distrobox enter "$CONTAINER_NAME" -- which pamac-manager &>/dev/null; then
    verification_issues+=("Pamac not found in container")
fi

# Check if desktop entry exists
if [ ! -f "$HOME/.local/share/applications/pamac-manager-distrobox.desktop" ] && \
   [ ! -f "$HOME/.local/share/applications/pamac-manager.desktop" ]; then
    verification_issues+=("Desktop entry not found")
fi

# Report verification results
if [ ${#verification_issues[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ All components verified successfully!${NC}"
else
    log_and_echo "${YELLOW}Verification found some issues:${NC}"
    for issue in "${verification_issues[@]}"; do
        log_and_echo "  - $issue"
    done
    log_and_echo "${YELLOW}The setup may still work, but you might need to troubleshoot these issues.${NC}"
fi
echo ""

# --- Success Message and Instructions ---
echo -e "${BOLD}${GREEN}🎉 SETUP COMPLETE! 🎉${NC}"
echo -e "${GREEN}Pamac with AUR support is now installed and ready to use.${NC}"
echo ""
echo -e "${BOLD}${YELLOW}HOW TO ACCESS YOUR NEW APPS:${NC}"
echo -e "  🖥️  ${GREEN}In Desktop Mode:${NC} Find '${GREEN}Pamac Package Manager${NC}' in the Application Launcher"
echo -e "  🎮  ${GREEN}In Gaming Mode:${NC} STEAM button → Library → '${GREEN}Non-Steam${NC}' collection"
echo ""
echo -e "${BOLD}${YELLOW}USAGE INSTRUCTIONS:${NC}"
echo -e "1. 📦 Open '${GREEN}Pamac Package Manager${NC}' to browse and install software"
echo -e "2. 🔍 Use the search to find packages from Arch repos and AUR"
echo -e "3. 🚀 After installing apps, they should appear in your menus automatically"
echo -e "4. 🛠️  Use '${GREEN}BoxBuddy${NC}' for advanced container management"
echo ""
echo -e "${BOLD}${YELLOW}MANUAL COMMANDS (if needed):${NC}"
echo -e "• Export an app manually: ${GREEN}distrobox-export --app <application-name>${NC}"
echo -e "• Enter container: ${GREEN}distrobox enter $CONTAINER_NAME${NC}"
echo -e "• Run Pamac directly: ${GREEN}distrobox enter $CONTAINER_NAME -- pamac-manager${NC}"
echo ""
echo -e "${BOLD}${YELLOW}TROUBLESHOOTING:${NC}"
echo -e "• 📋 Detailed log: ${GREEN}${LOG_FILE}${NC}"
echo -e "• 🔄 Restart container: ${GREEN}distrobox stop $CONTAINER_NAME && distrobox start $CONTAINER_NAME${NC}"
echo -e "• 🗑️  Remove everything: ${GREEN}distrobox rm $CONTAINER_NAME${NC}"
echo -e "• 🆘 Get help: Check the Steam Deck community forums"
echo ""
echo -e "${BOLD}${BLUE}Your Steam Deck now has access to thousands of Linux applications!${NC}"
echo -e "${BOLD}${BLUE}Enjoy exploring the AUR and Arch repositories! 🚀${NC}"
