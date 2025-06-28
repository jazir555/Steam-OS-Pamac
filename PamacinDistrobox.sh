#!/bin/bash

# This script automates the setup of a persistent, GUI-based package management
# system (Pamac with AUR) on SteamOS using Distrobox.
# It is idempotent and fully automated, requiring no user input after execution.
#
# WHY THIS DOES NOT REQUIRE DEVELOPER MODE:
# This script is carefully designed to work on a standard Steam Deck (SteamOS 3.5+).
# 1. It checks for Podman/Distrobox, which are pre-installed by Valve. It does NOT try to install them on the host.
# 2. All container files are stored in the user's home directory, which is always writable.
# 3. App exports (.desktop files) and Flatpak installs are user-level operations that do not touch the read-only system root.

# Stop on any error
set -e

# --- Color Codes for Output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Variables ---
CONTAINER_NAME="arch-box"
CURRENT_USER=$(whoami) # Usually 'deck' on Steam Deck

echo -e "${BLUE}--- Steam Deck Persistent AUR Package Manager Setup ---${NC}"
echo -e "${YELLOW}This script will set up an Arch Linux container, install and configure Pamac, and make it available on your Steam Deck.${NC}\n"

# --- Step 1: Check for Distrobox and Podman ---
echo -e "${BLUE}Step 1: Checking for required tools (Distrobox and Podman)...${NC}"
if ! command -v distrobox &> /dev/null || ! command -v podman &> /dev/null; then
    echo -e "${YELLOW}Error: Distrobox or Podman not found."
    echo "Please ensure your Steam Deck is updated to SteamOS 3.5 or newer before running this script."
    exit 1
fi
echo -e "${GREEN}Distrobox and Podman are available.${NC}\n"


# --- Step 2: Create Arch Linux Container ---
echo -e "${BLUE}Step 2: Checking for '$CONTAINER_NAME' container...${NC}"
if ! distrobox list --no-color | grep -q " $CONTAINER_NAME "; then
    echo "Container '$CONTAINER_NAME' not found. Creating it now..."
    echo "This may take several minutes as it downloads the Arch Linux image."
    distrobox create --name "$CONTAINER_NAME" --image archlinux:latest
    echo -e "${GREEN}'$CONTAINER_NAME' container created successfully.${NC}"
else
    echo -e "${GREEN}Container '$CONTAINER_NAME' already exists.${NC}"
fi
echo ""

# --- Step 3: Pre-configure Container for Full Automation ---
# This is the CRITICAL fix. We enter as root to grant our user passwordless
# sudo access inside the container. This prevents the script from halting
# to ask for a password during the main installation.
echo -e "${BLUE}Step 3: Configuring container for passwordless operations...${NC}"
distrobox enter "$CONTAINER_NAME" --root -- /bin/sh -c "
    # Add wheel group if it doesn't exist for safety
    groupadd -f wheel
    # Ensure our user is in the wheel group
    usermod -aG wheel $CURRENT_USER
    # Create a sudoers file to give the wheel group passwordless sudo
    echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-wheel-nopasswd
"
echo -e "${GREEN}Container configured for automation.${NC}\n"

# --- Step 4: Install and Configure Pamac Inside the Container ---
echo -e "${BLUE}Step 4: Installing Pamac inside '$CONTAINER_NAME'...${NC}"
echo "This is the longest step. It will update the container and build software."
echo "Thanks to the previous step, this will now run without any password prompts."

# We enter as the normal user, who now has passwordless sudo.
distrobox enter "$CONTAINER_NAME" -- /bin/bash -s <<'EOF'
# This entire block runs inside the container as a non-root user

# Stop on any error within the container script
set -e

# --- Color Codes for Output ---
GREEN_IN='\033[0;32m'
YELLOW_IN='\033[1;33m'
BLUE_IN='\033[0;34m'
NC_IN='\033[0m'

echo -e "${BLUE_IN}--- Now running inside the container ---${NC_IN}"

echo -e "${YELLOW_IN}Updating system and installing base dependencies...${NC_IN}"
# Update repositories and install git, build tools, and all Pamac/appstream dependencies.
sudo pacman -Syu --needed --noconfirm git base-devel appstream appstream-glib

echo -e "\n${YELLOW_IN}Checking for yay (AUR Helper)...${NC_IN}"
if ! command -v yay &> /dev/null; then
    echo "yay not found. Cloning and installing from pre-compiled binary..."
    temp_dir=$(mktemp -d)
    git clone https://aur.archlinux.org/yay-bin.git "$temp_dir"
    cd "$temp_dir"
    # Build and install the package. -s installs deps, -i installs package.
    # --noconfirm prevents all prompts. sudo is now passwordless.
    makepkg -si --noconfirm
    cd /
    rm -rf "$temp_dir"
    echo -e "${GREEN_IN}yay installed successfully.${NC_IN}"
else
    echo -e "${GREEN_IN}yay is already installed.${NC_IN}"
fi

echo -e "\n${YELLOW_IN}Checking for Pamac GUI...${NC_IN}"
if ! pacman -Qs pamac-aur > /dev/null; then
    echo "Pamac not found. Installing with yay (this may take a while)..."
    yay -S --noconfirm pamac-aur

    echo -e "\n${YELLOW_IN}Enabling AUR support in Pamac configuration...${NC_IN}"
    sudo sed -i 's/^#\(EnableAUR\)/\1/' /etc/pamac.conf
    sudo sed -i 's/^#\(CheckAURUpdates\)/\1/' /etc/pamac.conf
    echo -e "${GREEN_IN}Pamac installed and configured successfully.${NC_IN}"
else
    echo -e "${GREEN_IN}Pamac is already installed.${NC_IN}"
fi

echo -e "\n${GREEN_IN}Container setup is complete. Exiting container...${NC_IN}"
EOF
echo ""

# --- Step 5: Export Pamac to the Host Menu ---
echo -e "${BLUE}Step 5: Exporting Pamac to the SteamOS menu...${NC}"
distrobox-export --app pamac-manager

# Verify that the export was successful
DESKTOP_FILE_PATH="$HOME/.local/share/applications/pamac-manager.desktop"
if [ -f "$DESKTOP_FILE_PATH" ]; then
    update-desktop-database -q "$HOME/.local/share/applications"
    echo -e "${GREEN}Successfully exported 'Pamac Manager' to your application launcher.${NC}"
else
    echo -e "${YELLOW}Warning: Could not confirm that '$DESKTOP_FILE_PATH' was created. You may need to export it manually.${NC}"
fi
echo ""

# --- Step 6: Install a GUI for Future App Management ---
echo -e "${BLUE}Step 6: (Recommended) Installing BoxBuddy for easy app management...${NC}"
FLATPAK_ID="io.github.dvlv.BoxBuddy"
if ! flatpak info --user "$FLATPAK_ID" &> /dev/null; then
    echo "BoxBuddy not found. Installing from Flathub for the current user..."
    # The --user flag is critical to ensure installation happens in the home directory,
    # avoiding the need for root access or Developer Mode.
    flatpak install --user -y flathub "$FLATPAK_ID"
    echo -e "${GREEN}BoxBuddy installed successfully.${NC}"
else
    echo -e "${GREEN}BoxBuddy is already installed.${NC}"
fi
echo ""

# --- Final Instructions ---
echo -e "${GREEN}🎉 --- SETUP COMPLETE! --- 🎉${NC}"
echo -e "Pamac with AUR support is now set up and ready to use."
echo ""
echo -e "${YELLOW}HOW TO USE YOUR NEW SETUP:${NC}"
echo -e "1. Find and open '${GREEN}Pamac Manager${NC}' from your Steam Deck's application launcher (under 'All Applications' or 'Utilities')."
echo -e "2. Use Pamac to search for and install any app from the Arch or AUR repositories."
echo ""
echo -e "${YELLOW}TO GET NEW APPS IN YOUR LAUNCHER:${NC}"
echo -e "After installing a new GUI app inside Pamac (e.g., 'vscodium'), it won't appear on your Steam Deck menu automatically."
echo -e "You have two easy options to make it appear:"
echo -e "  - ${GREEN}Easy Way (GUI):${NC} Open '${GREEN}BoxBuddy${NC}', select the '$CONTAINER_NAME' container, find your new app, and click 'Export to Host'."
echo -e "  - ${GREEN}Advanced Way (Terminal):${NC} Open Konsole and run: ${GREEN}distrobox-export --app <app-name>${NC}"
echo ""
echo -e "A system restart may be needed for all new application icons to appear correctly in Gaming Mode."
echo -e "${BLUE}Enjoy your fully-featured Steam Deck!${NC}"
