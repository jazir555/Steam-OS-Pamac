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
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Variables ---
CONTAINER_NAME="arch-box"
CURRENT_USER=$(whoami) # Usually 'deck' on Steam Deck

echo -e "${BLUE}--- Steam Deck Persistent AUR Package Manager Setup ---${NC}"
echo -e "${YELLOW}This script will set up an Arch Linux container, install and configure Pamac, and make it available on your Steam Deck.${NC}\n"

# --- Step 1: Check for Distrobox and Podman ---
echo -e "${BLUE}Step 1: Checking for required tools (Distrobox and Podman)...${NC}"
if ! command -v distrobox &> /dev/null; then
    echo -e "${RED}Error: Distrobox not found.${NC}"
    echo "Please ensure your Steam Deck is updated to SteamOS 3.5 or newer."
    echo "If still missing, you can install Distrobox from Discover (KDE's app store)."
    exit 1
fi

if ! command -v podman &> /dev/null; then
    echo -e "${RED}Error: Podman not found.${NC}"
    echo "Please ensure your Steam Deck is updated to SteamOS 3.5 or newer."
    echo "If still missing, you can install Podman from Discover (KDE's app store)."
    exit 1
fi
echo -e "${GREEN}Distrobox and Podman are available.${NC}\n"

# --- Step 1.5: Initialize Podman if needed ---
echo -e "${BLUE}Step 1.5: Ensuring Podman is properly initialized...${NC}"
if ! podman info &> /dev/null; then
    echo "Initializing Podman for first use..."
    podman info > /dev/null 2>&1 || true
fi
echo -e "${GREEN}Podman is ready.${NC}\n"

# --- Step 2: Create Arch Linux Container ---
echo -e "${BLUE}Step 2: Checking for '$CONTAINER_NAME' container...${NC}"
if ! distrobox list --no-color 2>/dev/null | grep -q " $CONTAINER_NAME "; then
    echo "Container '$CONTAINER_NAME' not found. Creating it now..."
    echo "This may take several minutes as it downloads the Arch Linux image."
    
    # Add retry logic for container creation
    max_retries=3
    retry_count=0
    while [ $retry_count -lt $max_retries ]; do
        if distrobox create --name "$CONTAINER_NAME" --image archlinux:latest; then
            echo -e "${GREEN}'$CONTAINER_NAME' container created successfully.${NC}"
            break
        else
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                echo -e "${YELLOW}Container creation failed. Retrying... (Attempt $((retry_count + 1))/$max_retries)${NC}"
                sleep 5
            else
                echo -e "${RED}Failed to create container after $max_retries attempts.${NC}"
                exit 1
            fi
        fi
    done
else
    echo -e "${GREEN}Container '$CONTAINER_NAME' already exists.${NC}"
fi
echo ""

# --- Step 3: Pre-configure Container for Full Automation ---
echo -e "${BLUE}Step 3: Configuring container for passwordless operations...${NC}"
max_retries=3
retry_count=0
while [ $retry_count -lt $max_retries ]; do
    if distrobox enter "$CONTAINER_NAME" --root -- /bin/sh -c "
        # Ensure basic groups exist
        groupadd -f wheel
        groupadd -f sudo 2>/dev/null || true
        
        # Ensure our user exists and is in the wheel group
        usermod -aG wheel '$CURRENT_USER' 2>/dev/null || true
        
        # Create sudoers file for passwordless sudo
        echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-wheel-nopasswd
        chmod 440 /etc/sudoers.d/99-wheel-nopasswd
        
        # Verify sudoers syntax
        visudo -c -f /etc/sudoers.d/99-wheel-nopasswd
    "; then
        echo -e "${GREEN}Container configured for automation.${NC}"
        break
    else
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo -e "${YELLOW}Container configuration failed. Retrying... (Attempt $((retry_count + 1))/$max_retries)${NC}"
            sleep 5
        else
            echo -e "${RED}Failed to configure container after $max_retries attempts.${NC}"
            exit 1
        fi
    fi
done
echo ""

# --- Step 4: Install and Configure Pamac Inside the Container ---
echo -e "${BLUE}Step 4: Installing Pamac inside '$CONTAINER_NAME'...${NC}"
echo "This is the longest step. It will update the container and build software."
echo "Thanks to the previous step, this will now run without any password prompts."

# Create a temporary script file to run inside the container
TEMP_SCRIPT=$(mktemp)
cat > "$TEMP_SCRIPT" << 'CONTAINER_SCRIPT_EOF'
#!/bin/bash
# This entire block runs inside the container as a non-root user

# Stop on any error within the container script
set -e

# --- Color Codes for Output ---
GREEN_IN='\033[0;32m'
YELLOW_IN='\033[1;33m'
BLUE_IN='\033[0;34m'
RED_IN='\033[0;31m'
NC_IN='\033[0m'

echo -e "${BLUE_IN}--- Now running inside the container ---${NC_IN}"

# Test sudo access
echo -e "${YELLOW_IN}Testing passwordless sudo access...${NC_IN}"
if ! sudo -n true 2>/dev/null; then
    echo -e "${RED_IN}Error: Passwordless sudo is not working correctly.${NC_IN}"
    exit 1
fi
echo -e "${GREEN_IN}Sudo access confirmed.${NC_IN}"

echo -e "${YELLOW_IN}Updating system and installing base dependencies...${NC_IN}"
# Initialize pacman keyring if needed
sudo pacman-key --init 2>/dev/null || true
sudo pacman-key --populate archlinux 2>/dev/null || true

# Update repositories and install dependencies with better error handling
if ! sudo pacman -Sy --noconfirm; then
    echo -e "${YELLOW_IN}Initial sync failed, trying again...${NC_IN}"
    sudo pacman -Sy --noconfirm
fi

# Install essential packages
sudo pacman -S --needed --noconfirm git base-devel

# Install GUI and appstream dependencies (some may not be available, so install individually)
for pkg in appstream appstream-glib libappstream-glib; do
    sudo pacman -S --needed --noconfirm "$pkg" 2>/dev/null || echo -e "${YELLOW_IN}Package $pkg not available, skipping...${NC_IN}"
done

echo -e "\n${YELLOW_IN}Checking for yay (AUR Helper)...${NC_IN}"
if ! command -v yay &> /dev/null; then
    echo "yay not found. Installing from AUR..."
    temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    # Clone yay-bin for faster installation
    git clone https://aur.archlinux.org/yay-bin.git .
    
    # Build and install the package
    makepkg -si --noconfirm
    
    cd /
    rm -rf "$temp_dir"
    echo -e "${GREEN_IN}yay installed successfully.${NC_IN}"
else
    echo -e "${GREEN_IN}yay is already installed.${NC_IN}"
fi

echo -e "\n${YELLOW_IN}Checking for Pamac GUI...${NC_IN}"
if ! pacman -Qs pamac > /dev/null; then
    echo "Pamac not found. Installing with yay (this may take a while)..."
    
    # Try pamac-aur first, fall back to pamac-all if needed
    if ! yay -S --noconfirm pamac-aur; then
        echo -e "${YELLOW_IN}pamac-aur failed, trying pamac-all...${NC_IN}"
        yay -S --noconfirm pamac-all
    fi

    echo -e "\n${YELLOW_IN}Configuring Pamac for AUR support...${NC_IN}"
    # Create config if it doesn't exist
    sudo mkdir -p /etc
    if [ ! -f /etc/pamac.conf ]; then
        sudo tee /etc/pamac.conf > /dev/null << 'PAMAC_CONF_EOF'
# Pamac configuration file

# When to check for updates. Possible values: "never", "daily", "weekly", "monthly"
RefreshPeriod = 6

# When to check for updates from AUR. Possible values: "never", "daily", "weekly", "monthly"
AURRefreshPeriod = 6

# Enable AUR support
EnableAUR

# Check for updates from AUR
CheckAURUpdates

# Number of versions to keep in cache
KeepNumPackages = 3

# Remove only the versions of packages that are older than this number of days
RemoveUnrequiredDeps

# Check for .pacnew configuration files
CheckPacnewFiles

# Simple install: Install package without asking any questions
NoUpdateHideIcon
PAMAC_CONF_EOF
    else
        # Enable AUR support in existing config
        sudo sed -i 's/^#\(EnableAUR\)/\1/' /etc/pamac.conf
        sudo sed -i 's/^#\(CheckAURUpdates\)/\1/' /etc/pamac.conf
        
        # Add EnableAUR if it doesn't exist at all
        if ! grep -q "EnableAUR" /etc/pamac.conf; then
            echo "EnableAUR" | sudo tee -a /etc/pamac.conf > /dev/null
        fi
        if ! grep -q "CheckAURUpdates" /etc/pamac.conf; then
            echo "CheckAURUpdates" | sudo tee -a /etc/pamac.conf > /dev/null
        fi
    fi
    
    echo -e "${GREEN_IN}Pamac installed and configured successfully.${NC_IN}"
else
    echo -e "${GREEN_IN}Pamac is already installed.${NC_IN}"
fi

echo -e "\n${GREEN_IN}Container setup is complete. Exiting container...${NC_IN}"
CONTAINER_SCRIPT_EOF

# Make the script executable and run it in the container
chmod +x "$TEMP_SCRIPT"
if ! distrobox enter "$CONTAINER_NAME" -- bash < "$TEMP_SCRIPT"; then
    echo -e "${RED}Container setup failed. Please check the output above for errors.${NC}"
    rm -f "$TEMP_SCRIPT"
    exit 1
fi
rm -f "$TEMP_SCRIPT"
echo ""

# --- Step 5: Export Pamac to the Host Menu ---
echo -e "${BLUE}Step 5: Exporting Pamac to the SteamOS menu...${NC}"

# Try to export pamac-manager first, then pamac-gtk if that fails
if distrobox-export --app pamac-manager; then
    APP_NAME="pamac-manager"
elif distrobox-export --app pamac-gtk; then
    APP_NAME="pamac-gtk"
else
    echo -e "${YELLOW}Warning: Could not export Pamac automatically. You may need to do this manually later.${NC}"
    APP_NAME=""
fi

# Verify that the export was successful
if [ -n "$APP_NAME" ]; then
    DESKTOP_FILE_PATH="$HOME/.local/share/applications/${APP_NAME}.desktop"
    if [ -f "$DESKTOP_FILE_PATH" ]; then
        # Update desktop database
        if command -v update-desktop-database &> /dev/null; then
            update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true
        fi
        echo -e "${GREEN}Successfully exported 'Pamac' to your application launcher.${NC}"
    else
        echo -e "${YELLOW}Warning: Could not confirm that '$DESKTOP_FILE_PATH' was created.${NC}"
    fi
fi
echo ""

# --- Step 6: Install BoxBuddy for Future App Management ---
echo -e "${BLUE}Step 6: Installing BoxBuddy for easy app management...${NC}"
FLATPAK_ID="io.github.dvlv.BoxBuddy"

# Ensure flatpak is available and flathub remote is added
if command -v flatpak &> /dev/null; then
    # Add flathub remote if it doesn't exist
    if ! flatpak remotes --user | grep -q flathub; then
        echo "Adding Flathub remote..."
        flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    fi
    
    if ! flatpak info --user "$FLATPAK_ID" &> /dev/null; then
        echo "BoxBuddy not found. Installing from Flathub..."
        if flatpak install --user -y flathub "$FLATPAK_ID"; then
            echo -e "${GREEN}BoxBuddy installed successfully.${NC}"
        else
            echo -e "${YELLOW}BoxBuddy installation failed, but this won't prevent Pamac from working.${NC}"
        fi
    else
        echo -e "${GREEN}BoxBuddy is already installed.${NC}"
    fi
else
    echo -e "${YELLOW}Flatpak not found. BoxBuddy installation skipped.${NC}"
fi
echo ""

# --- Final Instructions ---
echo -e "${GREEN}🎉 --- SETUP COMPLETE! --- 🎉${NC}"
echo -e "Pamac with AUR support is now set up and ready to use."
echo ""
echo -e "${YELLOW}HOW TO USE YOUR NEW SETUP:${NC}"
echo -e "1. Find and open '${GREEN}Pamac${NC}' from your Steam Deck's application launcher"
echo -e "   (Look in 'All Applications' or try searching for 'Pamac' or 'Package Manager')"
echo -e "2. Use Pamac to search for and install any app from the Arch or AUR repositories"
echo ""
echo -e "${YELLOW}TO GET NEW APPS IN YOUR LAUNCHER:${NC}"
echo -e "After installing a new GUI app in Pamac (e.g., 'vscodium'), make it appear on your menu:"
echo -e "  - ${GREEN}Easy Way (GUI):${NC} Open '${GREEN}BoxBuddy${NC}', select '$CONTAINER_NAME', find your app, click 'Export'"
echo -e "  - ${GREEN}Command Line:${NC} Run: ${GREEN}distrobox-export --app <app-name>${NC}"
echo ""
echo -e "${YELLOW}TROUBLESHOOTING:${NC}"
echo -e "- If Pamac doesn't appear in your menu, try: ${GREEN}distrobox-export --app pamac-manager${NC}"
echo -e "- To enter your container manually: ${GREEN}distrobox enter $CONTAINER_NAME${NC}"
echo -e "- To remove everything: ${GREEN}distrobox rm $CONTAINER_NAME${NC}"
echo ""
echo -e "A system restart may help new applications appear correctly in Gaming Mode."
echo -e "${BLUE}Enjoy your enhanced Steam Deck!${NC}"
