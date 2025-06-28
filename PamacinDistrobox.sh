#!/bin/bash

# This script automates the setup of a persistent, GUI-based package management
# system (Pamac with AUR) on SteamOS using Distrobox.
# It also installs Juice for easy GUI-based app exporting.
# It is safe to run this script multiple times.

# Stop on any error
set -e

# --- Color Codes for Output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}--- Steam Deck Persistent Package Manager Setup ---${NC}"
echo -e "${YELLOW}This script will set up an Arch Linux container using Distrobox, install Pamac (GUI package manager), and Juice (GUI for app exporting).${NC}\n"

# --- Step 1: Check for Distrobox and Podman ---
echo -e "${YELLOW}Step 1: Checking for Distrobox and Podman...${NC}"
if ! command -v distrobox &> /dev/null || ! command -v podman &> /dev/null; then
    echo "Distrobox or Podman not found in PATH. SteamOS 3.5 and later should include them."
    echo "If you are on an older version, please update SteamOS."
    echo "If they are installed in a non-standard location, add them to your PATH."
    # On older SteamOS, they might be installed via curl to ~/.local/bin
    if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        echo "Adding ~/.local/bin to PATH for this session."
        export PATH="$HOME/.local/bin:$PATH"
    fi
    # Re-check after potential PATH modification
    if ! command -v distrobox &> /dev/null || ! command -v podman &> /dev/null; then
        echo -e "${YELLOW}Could not find Distrobox or Podman. Please install them first.${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}Distrobox and Podman are available.${NC}\n"


# --- Step 2: Create Arch Linux Container ---
CONTAINER_NAME="arch-box"
echo -e "${YELLOW}Step 2: Checking for '$CONTAINER_NAME' container...${NC}"
if ! distrobox list | grep -q " $CONTAINER_NAME "; then
    echo "Container '$CONTAINER_NAME' not found. Creating it now..."
    echo "This will take a few minutes as it downloads the Arch Linux image."
    distrobox create --name "$CONTAINER_NAME" --image archlinux:latest
    echo -e "${GREEN}'$CONTAINER_NAME' container created successfully.${NC}"
else
    echo -e "${GREEN}Container '$CONTAINER_NAME' already exists.${NC}"
fi
echo ""

# --- Step 3: Install Pamac GUI Inside the Container ---
echo -e "${YELLOW}Step 3: Setting up Pamac inside the container...${NC}"
echo "This is the longest step. It will update the container and install software."
echo "You may be asked for your password to complete the installation inside the container."

distrobox enter "$CONTAINER_NAME" -- /bin/bash -s <<'EOF'
set -e # Stop on any error inside the container script

# --- Color Codes for Output ---
GREEN_IN='\033[0;32m'
YELLOW_IN='\033[1;33m'
NC_IN='\033[0m'

echo -e "${YELLOW_IN}Updating container system...${NC_IN}"
sudo pacman -Syu --noconfirm

echo -e "\n${YELLOW_IN}Installing necessary build tools (git, base-devel)...${NC_IN}"
sudo pacman -S --needed --noconfirm git base-devel

echo -e "\n${YELLOW_IN}Checking for yay (AUR Helper)...${NC_IN}"
if ! command -v yay &> /dev/null; then
    echo "yay not found. Cloning and installing..."
    # Cloning to a temporary directory
    temp_dir=$(mktemp -d)
    git clone https://aur.archlinux.org/yay.git "$temp_dir"
    cd "$temp_dir"
    makepkg -si --noconfirm
    cd -
    rm -rf "$temp_dir"
    echo -e "${GREEN_IN}yay installed successfully.${NC_IN}"
else
    echo -e "${GREEN_IN}yay is already installed.${NC_IN}"
fi

echo -e "\n${YELLOW_IN}Checking for Pamac GUI...${NC_IN}"
if ! pacman -Qs pamac-aur > /dev/null; then
    echo "Pamac not found. Installing with yay..."
    yay -S pamac-aur --noconfirm
    echo -e "${GREEN_IN}Pamac installed successfully.${NC_IN}"
else
    echo -e "${GREEN_IN}Pamac is already installed.${NC_IN}"
fi

echo -e "\n${YELLOW_IN}Exporting Pamac Manager to the Steam Deck menu...${NC_IN}"
distrobox-export --app pamac-manager

echo -e "\n${GREEN_IN}Container setup is complete!${NC_IN}"
EOF
echo -e "${GREEN}Pamac has been installed and configured inside the container.${NC}\n"

# --- Step 4: Install Juice GUI from Flatpak ---
echo -e "${YELLOW}Step 4: Checking for Juice (GUI for exporting apps)...${NC}"
FLATPAK_ID="com.github.bdefore.Juice"
if ! flatpak info "$FLATPAK_ID" &> /dev/null; then
    echo "Juice not found. Installing from Flathub..."
    flatpak install -y flathub "$FLATPAK_ID"
    echo -e "${GREEN}Juice installed successfully.${NC}"
else
    echo -e "${GREEN}Juice is already installed.${NC}"
fi
echo ""

# --- Final Instructions ---
echo -e "${GREEN}🎉 --- SETUP COMPLETE! --- 🎉${NC}"
echo -e "You now have a persistent, GUI-based system for AUR packages."
echo -e "\n${YELLOW}Your new workflow:${NC}"
echo -e "1. Open '${GREEN}Pamac Manager${NC}' from your application launcher to find and install new AUR/Arch packages."
echo -e "   (First time only: In Pamac, go to Preferences -> Third Party and enable AUR support)."
echo -e "2. After installing a new app, open '${GREEN}Juice${NC}'."
echo -e "3. In Juice, select '${GREEN}$CONTAINER_NAME${NC}', go to the Applications tab, and click '${GREEN}Export${NC}' next to your new app."
echo ""
echo -e "A system restart may be needed for all new application icons to appear correctly."
echo -e "${BLUE}Enjoy your fully-featured Steam Deck!${NC}"
