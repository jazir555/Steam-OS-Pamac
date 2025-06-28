#!/bin/bash

# This script automates the setup of a persistent, GUI-based package management
# system (Pamac with AUR) on SteamOS using Distrobox.
# It is idempotent, meaning it is safe to run this script multiple times.

# Stop on any error
set -e

# --- Color Codes for Output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}--- Steam Deck Persistent AUR Package Manager Setup ---${NC}"
echo -e "${YELLOW}This script will set up an Arch Linux container, install and configure Pamac, and make it available on your Steam Deck.${NC}\n"

# --- Step 1: Check for Distrobox and Podman ---
echo -e "${BLUE}Step 1: Checking for Distrobox and Podman...${NC}"
if ! command -v distrobox &> /dev/null || ! command -v podman &> /dev/null; then
    echo "Error: Distrobox or Podman not found. SteamOS 3.5+ should include them."
    echo "Please ensure your Steam Deck is up to date."
    # On older SteamOS, they might be installed via curl to ~/.local/bin
    if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        echo "Adding ~/.local/bin to PATH for this session."
        export PATH="$HOME/.local/bin:$PATH"
    fi
    # Re-check after potential PATH modification
    if ! command -v distrobox &> /dev/null || ! command -v podman &> /dev/null; then
        echo -e "${YELLOW}Could not find Distrobox or Podman. Please install them first from the Distrobox website before running this script again.${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}Distrobox and Podman are available.${NC}\n"


# --- Step 2: Create Arch Linux Container ---
CONTAINER_NAME="arch-box"
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

# --- Step 3: Install and Configure Pamac Inside the Container ---
echo -e "${BLUE}Step 3: Installing Pamac inside '$CONTAINER_NAME'...${NC}"
echo "This is the longest step. It will update the container and build software."
echo "You may be asked for your password to authorize installations inside the container."

distrobox enter "$CONTAINER_NAME" -- /bin/bash -s <<'EOF'
# This entire block runs inside the container
set -e

# --- Color Codes for Output ---
GREEN_IN='\033[0;32m'
YELLOW_IN='\033[1;33m'
NC_IN='\033[0m'

echo -e "${YELLOW_IN}Updating container system repositories...${NC_IN}"
sudo pacman -Syu --noconfirm

echo -e "\n${YELLOW_IN}Installing dependencies (git, base-devel, appstream-glib)...${NC_IN}"
# Install build tools and a key pamac dependency with the native package manager first
sudo pacman -S --needed --noconfirm git base-devel appstream-glib

echo -e "\n${YELLOW_IN}Checking for yay (AUR Helper)...${NC_IN}"
if ! command -v yay &> /dev/null; then
    echo "yay not found. Cloning and installing..."
    # Create a temporary directory for the build
    temp_dir=$(mktemp -d)
    git clone https://aur.archlinux.org/yay-bin.git "$temp_dir"
    cd "$temp_dir"
    # Build and install the package
    makepkg -si --noconfirm
    # Clean up
    cd /
    rm -rf "$temp_dir"
    echo -e "${GREEN_IN}yay installed successfully.${NC_IN}"
else
    echo -e "${GREEN_IN}yay is already installed.${NC_IN}"
fi

echo -e "\n${YELLOW_IN}Checking for Pamac GUI...${NC_IN}"
# Check if the package is already installed
if ! pacman -Qs pamac-aur > /dev/null; then
    echo "Pamac not found. Installing with yay (this may take a while)..."
    # Use yay to install Pamac from the AUR. This is fully non-interactive.
    yay -S --noconfirm pamac-aur

    echo -e "\n${YELLOW_IN}Enabling AUR support in Pamac configuration...${NC_IN}"
    # This automatically enables AUR support in the Pamac GUI settings
    sudo sed -i 's/^#\(EnableAUR\)/\1/' /etc/pamac.conf
    sudo sed -i 's/^#\(CheckAURUpdates\)/\1/' /etc/pamac.conf
    echo -e "${GREEN_IN}Pamac installed and configured successfully.${NC_IN}"
else
    echo -e "${GREEN_IN}Pamac is already installed.${NC_IN}"
fi

echo -e "\n${GREEN_IN}Container setup is complete. Exiting container...${NC_IN}"
EOF
echo ""

# --- Step 4: Export Pamac to the Host Menu ---
echo -e "${BLUE}Step 4: Exporting Pamac to the SteamOS menu...${NC}"
# This MUST be run on the HOST, not inside the container.
distrobox-export --app pamac-manager

# Verify that the export was successful
if [ -f "$HOME/.local/share/applications/pamac-manager.desktop" ]; then
    echo -e "${GREEN}Successfully exported 'Pamac Manager' to your application launcher.${NC}"
else
    echo -e "${YELLOW}Warning: Could not confirm that 'pamac-manager.desktop' was created. You may need to export it manually or using BoxBuddy.${NC}"
fi
echo ""

# --- Step 5: Install a GUI for Future App Management ---
echo -e "${BLUE}Step 5: (Recommended) Installing BoxBuddy for easy app management...${NC}"
FLATPAK_ID="io.github.dvlv.BoxBuddy"
if ! flatpak info "$FLATPAK_ID" &> /dev/null; then
    echo "BoxBuddy not found. Installing from Flathub..."
    flatpak install -y flathub "$FLATPAK_ID"
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
echo -e "1. Find and open '${GREEN}Pamac Manager${NC}' from your Steam Deck's application launcher (under the 'All Applications' tab)."
echo -e "2. Use Pamac to search for and install any app from the Arch or AUR repositories."
echo ""
echo -e "${YELLOW}TO GET NEW APPS IN YOUR LAUNCHER:${NC}"
echo -e "After installing a new GUI app inside Pamac (e.g., 'vscodium'), it won't appear on your Steam Deck menu automatically."
echo -e "You have two easy options to make it appear:"
echo -e "  - ${GREEN}Easy Way (GUI):${NC} Open '${GREEN}BoxBuddy${NC}', select the '$CONTAINER_NAME' container, find your new app, and click 'Export to Host'."
echo -e "  - ${GREEN}Advanced Way (Terminal):${NC} Open Konsole and run: ${GREEN}distrobox-export --app <app-name>${NC}"
echo ""
echo -e "A system restart may be needed for all new application icons to appear correctly."
echo -e "${BLUE}Enjoy your fully-featured Steam Deck!${NC}"
