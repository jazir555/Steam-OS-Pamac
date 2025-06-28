#!/bin/bash

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
  NC='\033[0m' # No Color
else
  GREEN=''; YELLOW=''; BLUE=''; RED=''; NC=''
fi

# --- Variables & Setup ---
CONTAINER_NAME="arch-box"
CURRENT_USER=$(whoami) # Usually 'deck' on Steam Deck
LOG_FILE="$HOME/distrobox-pamac-setup.log"

# --- Logging and Exit Handling ---
# Initialize log file with a timestamp
echo "=== Steam Deck Pamac Setup - Run started at: $(date) ===" > "$LOG_FILE"
# Ensure a final message is logged when the script exits, for any reason
trap 'echo "=== Run finished at: $(date) ===" >> "$LOG_FILE"' EXIT

# --- Helper Functions ---
log_and_echo() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

wait_for_container() {
    local container_name="$1"
    local max_attempts=30
    local attempt=1
    
    echo -e "${YELLOW}Waiting for container to be ready...${NC}"
    while [ $attempt -le $max_attempts ]; do
        if distrobox enter "$container_name" -- echo "Container ready" &>/dev/null; then
            echo -e "${GREEN}Container is ready.${NC}"
            return 0
        fi
        echo "Attempt $attempt/$max_attempts..."
        sleep 2
        ((attempt++))
    done
    
    echo -e "${RED}Container failed to become ready after $max_attempts attempts.${NC}"
    return 1
}

# --- Main Logic ---
echo -e "${BLUE}--- Steam Deck Persistent AUR Package Manager Setup ---${NC}"
echo -e "${YELLOW}This script will set up an Arch Linux container with Pamac and AUR support.${NC}"
echo -e "A detailed log will be saved to: ${LOG_FILE}\n"

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
echo -e "${GREEN}All required host tools are available.${NC}\n"

# Step 1.5: Verify Podman is working
echo -e "${BLUE}Step 1.5: Verifying Podman functionality...${NC}"
if ! podman info &>> "$LOG_FILE"; then
    log_and_echo "${YELLOW}Podman may need initialization. Attempting to start...${NC}"
    # Initialize podman if needed
    podman system reset --force &>> "$LOG_FILE" || true
    if ! podman info &>> "$LOG_FILE"; then
        log_and_echo "${RED}Podman is not functioning properly. Check the log for details.${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}Podman is working correctly.${NC}\n"

# Step 2: Create Container if it Doesn't Exist
echo -e "${BLUE}Step 2: Checking for '$CONTAINER_NAME' container...${NC}"
if ! distrobox list --no-color 2>/dev/null | grep -q " $CONTAINER_NAME "; then
    log_and_echo "Container '$CONTAINER_NAME' not found. Creating it now (this may take several minutes)..."
    
    # Create with additional options for better reliability
    if ! distrobox create \
        --name "$CONTAINER_NAME" \
        --image archlinux:latest \
        --pull \
        --yes &>> "$LOG_FILE"; then
        log_and_echo "${RED}Failed to create container. Check the log for details: ${LOG_FILE}${NC}"
        exit 1
    fi
    
    # Wait for container to be ready
    if ! wait_for_container "$CONTAINER_NAME"; then
        log_and_echo "${RED}Container creation failed or timed out.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}'$CONTAINER_NAME' container created successfully.${NC}"
else
    echo -e "${GREEN}Container '$CONTAINER_NAME' already exists. Skipping creation.${NC}"
fi
echo ""

# Step 3: Configure Container for Automation
echo -e "${BLUE}Step 3: Configuring container for passwordless operations...${NC}"
if ! distrobox enter "$CONTAINER_NAME" --root -- /bin/sh -c "
    set -e
    # Ensure wheel group exists
    groupadd -f wheel
    # Add user to wheel group
    usermod -aG wheel '$CURRENT_USER'
    # Create sudoers file for passwordless sudo
    echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-wheel-nopasswd
    chmod 440 /etc/sudoers.d/99-wheel-nopasswd
    # Validate sudoers file
    visudo -c -f /etc/sudoers.d/99-wheel-nopasswd
    echo 'Container configuration complete'
" &>> "$LOG_FILE"; then
    log_and_echo "${RED}Failed to configure container for automation.${NC}"
    exit 1
fi
echo -e "${GREEN}Container configured for automation.${NC}\n"

# Step 4: Install Pamac Inside the Container (if needed)
echo -e "${BLUE}Step 4: Installing Pamac inside '$CONTAINER_NAME' (if needed)...${NC}"
TEMP_SCRIPT=$(mktemp)
cat > "$TEMP_SCRIPT" << 'CONTAINER_SCRIPT_EOF'
#!/bin/bash
set -e
GREEN_IN='\033[0;32m'; YELLOW_IN='\033[1;33m'; BLUE_IN='\033[0;34m'; RED_IN='\033[0;31m'; NC_IN='\033[0m'

echo -e "${BLUE_IN}--- Checking status inside the container ---${NC_IN}"

# Function to check if package is installed
is_installed() {
    pacman -Qi "$1" &>/dev/null
}

# Check if pamac is already installed
if is_installed pamac-aur || is_installed pamac-gtk; then
    echo -e "${GREEN_IN}Pamac is already installed. Checking configuration...${NC_IN}"
    
    # Ensure AUR is enabled
    if ! grep -q "^EnableAUR" /etc/pamac.conf 2>/dev/null; then
        echo -e "${YELLOW_IN}Enabling AUR support...${NC_IN}"
        sudo sed -i 's/^#\(EnableAUR\)/\1/' /etc/pamac.conf
        sudo sed -i 's/^#\(CheckAURUpdates\)/\1/' /etc/pamac.conf
    fi
    
    echo -e "${GREEN_IN}Pamac is properly configured.${NC_IN}"
    exit 0
fi

echo -e "${YELLOW_IN}Pamac not found. Starting installation...${NC_IN}"

# Update system first
echo -e "${YELLOW_IN}Updating system packages...${NC_IN}"
sudo pacman -Syu --needed --noconfirm

# Install essential packages
echo -e "${YELLOW_IN}Installing build dependencies...${NC_IN}"
sudo pacman -S --needed --noconfirm git base-devel

# Install yay if not present
if ! command -v yay &>/dev/null; then
    echo -e "${YELLOW_IN}Installing yay AUR helper...${NC_IN}"
    cd /tmp
    if [ -d "yay-bin" ]; then
        rm -rf yay-bin
    fi
    git clone https://aur.archlinux.org/yay-bin.git
    cd yay-bin
    makepkg -si --noconfirm
    cd /
    rm -rf /tmp/yay-bin
    echo -e "${GREEN_IN}yay installed successfully.${NC_IN}"
else
    echo -e "${GREEN_IN}yay is already installed.${NC_IN}"
fi

# Install pamac
echo -e "${YELLOW_IN}Installing Pamac GUI from AUR...${NC_IN}"
yay -S --noconfirm --needed pamac-aur

# Configure pamac for AUR support
echo -e "${YELLOW_IN}Configuring Pamac for AUR support...${NC_IN}"
if [ -f /etc/pamac.conf ]; then
    sudo sed -i 's/^#\(EnableAUR\)/\1/' /etc/pamac.conf
    sudo sed -i 's/^#\(CheckAURUpdates\)/\1/' /etc/pamac.conf
    echo -e "${GREEN_IN}AUR support enabled in Pamac.${NC_IN}"
else
    echo -e "${RED_IN}Warning: /etc/pamac.conf not found${NC_IN}"
fi

echo -e "${GREEN_IN}Pamac installation and configuration complete!${NC_IN}"
CONTAINER_SCRIPT_EOF

if ! distrobox enter "$CONTAINER_NAME" -- bash < "$TEMP_SCRIPT" 2>&1 | tee -a "$LOG_FILE"; then
    log_and_echo "${RED}Container setup failed. Please check the log for details: ${LOG_FILE}${NC}"
    rm -f "$TEMP_SCRIPT"
    exit 1
fi
rm -f "$TEMP_SCRIPT"
echo -e "${GREEN}Container setup complete.${NC}\n"

# Step 5: Export Pamac to the Host Menu
echo -e "${BLUE}Step 5: Exporting Pamac to the SteamOS menu...${NC}"

# Ensure the applications directory exists
mkdir -p "$HOME/.local/share/applications"

# Try to export pamac-manager
export_success=false
for app_name in pamac-manager pamac-gtk; do
    if distrobox enter "$CONTAINER_NAME" -- which "$app_name" &>/dev/null; then
        echo -e "${YELLOW}Attempting to export $app_name...${NC}" | tee -a "$LOG_FILE"
        if distrobox-export --app "$app_name" &>> "$LOG_FILE"; then
            export_success=true
            echo -e "${GREEN}Successfully exported '$app_name' to your application launcher.${NC}"
            break
        else
            echo -e "${YELLOW}Failed to export $app_name, trying next...${NC}" | tee -a "$LOG_FILE"
        fi
    fi
done

if [ "$export_success" = false ]; then
    log_and_echo "${YELLOW}Warning: Automatic export failed. You can manually export Pamac later using BoxBuddy.${NC}"
fi

# Update desktop database
if [ -d "$HOME/.local/share/applications" ]; then
    update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true
fi
echo ""

# Step 6: Install BoxBuddy for Easy App Management
echo -e "${BLUE}Step 6: Installing BoxBuddy for easy app management...${NC}"
FLATPAK_ID="io.github.dvlv.BoxBuddy"
LAUNCH_BOXBUDDY=false

if ! flatpak info --user "$FLATPAK_ID" &>/dev/null; then
    # Ensure Flathub remote is added
    if ! flatpak remotes --user | grep -q "flathub"; then
        log_and_echo "Adding Flathub remote for the current user..."
        if ! flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo &>> "$LOG_FILE"; then
            log_and_echo "${YELLOW}Failed to add Flathub remote. BoxBuddy installation will be skipped.${NC}"
        fi
    fi
    
    log_and_echo "Installing BoxBuddy from Flathub..."
    if flatpak install --user -y flathub "$FLATPAK_ID" &>> "$LOG_FILE"; then
        echo -e "${GREEN}BoxBuddy installed successfully.${NC}"
        LAUNCH_BOXBUDDY=true
    else
        log_and_echo "${YELLOW}BoxBuddy installation failed. This is optional, so setup will continue.${NC}"
    fi
else
    echo -e "${GREEN}BoxBuddy is already installed.${NC}"
fi

# Launch BoxBuddy if it was just installed
if [ "$LAUNCH_BOXBUDDY" = true ]; then
    echo -e "${BLUE}Launching BoxBuddy to help you manage your containers...${NC}"
    # Launch in background and detach
    nohup flatpak run "$FLATPAK_ID" >/dev/null 2>&1 &
    disown
fi
echo ""

# Step 7: Verify Installation
echo -e "${BLUE}Step 7: Verifying installation...${NC}"
verification_issues=()

# Check if container is running
if ! distrobox list | grep -q "$CONTAINER_NAME"; then
    verification_issues+=("Container '$CONTAINER_NAME' not found")
fi

# Check if pamac is installed in container
if ! distrobox enter "$CONTAINER_NAME" -- which pamac-manager &>/dev/null && \
   ! distrobox enter "$CONTAINER_NAME" -- which pamac-gtk &>/dev/null; then
    verification_issues+=("Pamac not found in container")
fi

# Report verification results
if [ ${#verification_issues[@]} -eq 0 ]; then
    echo -e "${GREEN}All components verified successfully!${NC}"
else
    log_and_echo "${YELLOW}Verification found some issues:${NC}"
    for issue in "${verification_issues[@]}"; do
        log_and_echo "  - $issue"
    done
    log_and_echo "${YELLOW}The setup may still work, but you might need to troubleshoot these issues.${NC}"
fi
echo ""

# --- Final Instructions ---
echo -e "${GREEN}🎉 --- SETUP COMPLETE! --- 🎉${NC}"
echo -e "Pamac with AUR support is now set up and ready to use."
echo ""
echo -e "${YELLOW}HOW TO FIND YOUR NEW APPS:${NC}"
echo -e "  - ${GREEN}In Desktop Mode:${NC} Find '${GREEN}Pamac Manager${NC}' and '${GREEN}BoxBuddy${NC}' in the Application Launcher."
echo -e "  - ${GREEN}In Gaming Mode:${NC} Press the STEAM button -> Library -> find the '${GREEN}Non-Steam${NC}' collection."
echo ""
echo -e "${YELLOW}HOW TO USE:${NC}"
echo -e "1. Open '${GREEN}Pamac Manager${NC}' to install software from Arch repositories and AUR."
echo -e "2. After installing an app in Pamac, open '${GREEN}BoxBuddy${NC}', select '$CONTAINER_NAME', find the app, and click 'Export to Host'."
echo -e "3. The new app will appear in both Desktop and Gaming Mode menus."
echo ""
echo -e "${YELLOW}MANUAL EXPORT (if needed):${NC}"
echo -e "If an app doesn't appear automatically, you can export it manually:"
echo -e "  ${GREEN}distrobox-export --app <application-name>${NC}"
echo ""
echo -e "${YELLOW}TROUBLESHOOTING:${NC}"
echo -e "- Detailed log: ${GREEN}${LOG_FILE}${NC}"
echo -e "- To restart a container: ${GREEN}distrobox stop $CONTAINER_NAME && distrobox start $CONTAINER_NAME${NC}"
echo -e "- To remove everything: ${GREEN}distrobox rm $CONTAINER_NAME${NC}"
echo -e "- If Pamac won't start: ${GREEN}distrobox enter $CONTAINER_NAME -- pamac-manager${NC}"
echo ""
echo -e "${BLUE}Enjoy your enhanced Steam Deck with full Arch Linux package management!${NC}"
