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

# --- Main Logic ---
echo -e "${BLUE}--- Steam Deck Persistent AUR Package Manager Setup ---${NC}"
echo -e "${YELLOW}This script will set up an Arch Linux container with Pamac and AUR support.${NC}"
echo -e "A detailed log will be saved to: ${LOG_FILE}\n"

# Step 1: Check for Host Dependencies
echo -e "${BLUE}Step 1: Checking for required host tools...${NC}"
for cmd in distrobox podman flatpak; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}Error: Required command '$cmd' not found.${NC}" | tee -a "$LOG_FILE"
        echo "Please ensure your Steam Deck is updated to SteamOS 3.5 or newer." | tee -a "$LOG_FILE"
        exit 1
    fi
done
echo -e "${GREEN}All required host tools are available.${NC}\n"

# Step 2: Create or Update Arch Linux Container
echo -e "${BLUE}Step 2: Creating or updating '$CONTAINER_NAME' container...${NC}"
if ! distrobox list --no-color 2>/dev/null | grep -q " $CONTAINER_NAME "; then
    echo "Container '$CONTAINER_NAME' not found. Creating it now (this may take a few minutes)..." | tee -a "$LOG_FILE"
    if ! distrobox create --name "$CONTAINER_NAME" --image archlinux:latest &>> "$LOG_FILE"; then
        echo -e "${RED}Failed to create container. Check the log for details: ${LOG_FILE}${NC}"
        exit 1
    fi
    echo -e "${GREEN}'$CONTAINER_NAME' container created successfully.${NC}"
else
    echo -e "${GREEN}Container '$CONTAINER_NAME' already exists. Updating it now...${NC}"
    distrobox enter "$CONTAINER_NAME" -- sudo pacman -Syu --noconfirm &>> "$LOG_FILE"
    echo -e "${GREEN}Container updated.${NC}"
fi
echo ""

# Step 3: Configure Container for Automation
echo -e "${BLUE}Step 3: Configuring container for passwordless operations...${NC}"
distrobox enter "$CONTAINER_NAME" --root -- /bin/sh -c "
    set -e; groupadd -f wheel; usermod -aG wheel '$CURRENT_USER'
    echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-wheel-nopasswd
    chmod 440 /etc/sudoers.d/99-wheel-nopasswd
    visudo -c -f /etc/sudoers.d/99-wheel-nopasswd
" &>> "$LOG_FILE"
echo -e "${GREEN}Container configured for automation.${NC}\n"

# Step 4: Install Pamac Inside the Container
echo -e "${BLUE}Step 4: Installing Pamac inside '$CONTAINER_NAME'...${NC}"
echo "This step may take a while but is fully automated."
TEMP_SCRIPT=$(mktemp)
cat > "$TEMP_SCRIPT" << 'CONTAINER_SCRIPT_EOF'
#!/bin/bash
set -e
GREEN_IN='\033[0;32m'; YELLOW_IN='\033[1;33m'; BLUE_IN='\033[0;34m'; NC_IN='\033[0m'
echo -e "${BLUE_IN}--- Now running inside the container ---${NC_IN}"
echo -e "${YELLOW_IN}Initializing pacman keyring...${NC_IN}"; sudo pacman-key --init &>/dev/null || true; sudo pacman-key --populate archlinux &>/dev/null || true
echo -e "${YELLOW_IN}Updating system and installing dependencies...${NC_IN}"; sudo pacman -Syu --needed --noconfirm git base-devel appstream-glib
echo -e "\n${YELLOW_IN}Installing yay (AUR Helper)...${NC_IN}"
if ! command -v yay &>/dev/null; then
    cd /tmp; git clone https://aur.archlinux.org/yay-bin.git; cd yay-bin; makepkg -si --noconfirm; cd / && rm -rf /tmp/yay-bin
    echo -e "${GREEN_IN}yay installed successfully.${NC_IN}"
else echo -e "${GREEN_IN}yay is already installed.${NC_IN}"; fi
echo -e "\n${YELLOW_IN}Installing Pamac GUI...${NC_IN}"
if ! pacman -Qs pamac-aur &>/dev/null; then
    yay -S --noconfirm pamac-aur
    echo -e "\n${YELLOW_IN}Enabling AUR support in Pamac...${NC_IN}"; sudo sed -i 's/^#\(EnableAUR\)/\1/' /etc/pamac.conf; sudo sed -i 's/^#\(CheckAURUpdates\)/\1/' /etc/pamac.conf
    echo -e "${GREEN_IN}Pamac installed and configured.${NC_IN}"
else echo -e "${GREEN_IN}Pamac is already installed.${NC_IN}"; fi
echo -e "\n${GREEN_IN}Container setup is complete. Exiting...${NC_IN}"
CONTAINER_SCRIPT_EOF

if ! distrobox enter "$CONTAINER_NAME" -- bash < "$TEMP_SCRIPT" &>> "$LOG_FILE"; then
    echo -e "${RED}Container setup failed. Please check the log for details: ${LOG_FILE}${NC}"; rm -f "$TEMP_SCRIPT"; exit 1
fi
rm -f "$TEMP_SCRIPT"
echo -e "${GREEN}Pamac installation complete.${NC}\n"

# Step 5: Export Pamac to the Host Menu
echo -e "${BLUE}Step 5: Exporting Pamac to the SteamOS menu...${NC}"
distrobox-export --app pamac-manager &>> "$LOG_FILE"
if [ -f "$HOME/.local/share/applications/pamac-manager.desktop" ]; then
    update-desktop-database -q "$HOME/.local/share/applications"
    echo -e "${GREEN}Successfully exported 'Pamac Manager' to your application launcher.${NC}"
else
    echo -e "${YELLOW}Warning: Could not confirm 'Pamac Manager' was exported. You may need to do it manually.${NC}"
fi
echo ""

# Step 6: Install and Launch BoxBuddy
echo -e "${BLUE}Step 6: Installing BoxBuddy for easy app management...${NC}"
FLATPAK_ID="io.github.dvlv.BoxBuddy"
FIRST_INSTALL=false
if ! flatpak info --user "$FLATPAK_ID" &>/dev/null; then
    FIRST_INSTALL=true
    if ! flatpak remote-info --user flathub &>/dev/null; then
        echo "Adding Flathub remote for the current user..." | tee -a "$LOG_FILE"
        flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo &>> "$LOG_FILE"
    fi
    echo "BoxBuddy not found. Installing from Flathub..." | tee -a "$LOG_FILE"
    if flatpak install --user -y flathub "$FLATPAK_ID" &>> "$LOG_FILE"; then
        echo -e "${GREEN}BoxBuddy installed successfully.${NC}"
    else
        echo -e "${YELLOW}BoxBuddy installation failed. This is optional, so setup will continue.${NC}"; FIRST_INSTALL=false
    fi
else
    echo -e "${GREEN}BoxBuddy is already installed.${NC}"
fi
if [ "$FIRST_INSTALL" = true ]; then
    echo -e "${BLUE}Launching BoxBuddy for the first time to guide you...${NC}"; (flatpak run "$FLATPAK_ID" &)
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
echo -e "1. Open '${GREEN}Pamac Manager${NC}' to install software from Arch/AUR."
echo -e "2. After installing an app, open '${GREEN}BoxBuddy${NC}', select '$CONTAINER_NAME', find the app, and click 'Export to Host'."
echo -e "3. The new app will now appear in both Desktop and Gaming Mode."
echo ""
echo -e "${YELLOW}TROUBLESHOOTING:${NC}"
echo -e "- A detailed log of this script's execution is available at: ${GREEN}${LOG_FILE}${NC}"
echo -e "- To remove everything: ${GREEN}distrobox rm $CONTAINER_NAME${NC}"
echo ""
echo -e "${BLUE}Enjoy your enhanced Steam Deck!${NC}"
