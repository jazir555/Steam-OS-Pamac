## **Native Experience Features:**

### 🖥️ **Desktop Integration**
- **Native App Menu**: Pamac appears in your Steam Deck's application menu under "System" 
- **Proper Icon & Categorization**: Shows up with the correct Pamac icon and metadata
- **Launch Like Any App**: Click and run - no terminal commands needed
- **Auto-cleanup**: When you uninstall packages, their shortcuts are automatically removed

### 🔄 **Persistent Storage**
- **Survives Updates**: Your installed packages and configurations persist through SteamOS updates
- **Build Cache**: Speeds up AUR package compilation by caching builds in `~/.cache/yay`
- **Settings Retention**: Pamac configuration and preferences are maintained

### Core Functionality
1. **Immutable Filesystem Preservation** ✅  
   - All package installations occur entirely within the Distrobox container
   - No modifications to the host SteamOS filesystem
   - SteamOS remains read-only and secure

2. **AUR Package Management** ✅  
   - Installs Pamac with full AUR support inside container
   - GUI and CLI access to Arch Linux packages + AUR
   - `yay` helper pre-installed for terminal operations

3. **Automatic Setup** ✅  
   - Single-script execution handles everything
   - Container creation
   - Pamac installation
   - System configuration
   - Application exporting

4. **Seamless Desktop Integration** ✅  
   - Pamac appears in SteamOS application menu
   - Installed apps get automatically added to menu
   - Exporting respects SteamOS .desktop standards

### Security and Safety
- **No Developer Mode Required** ✅  
  Works within standard SteamOS restrictions
- **No Sudo on Host** ✅  
  All privileged operations are containerized
- **No System Modifications** ✅  
  Leaves SteamOS core files untouched

### User Experience
- **GUI Application** ✅  
  Pamac runs as native-looking desktop app
- **Menu Integration** ✅  
  Newly installed apps appear alongside Steam games
- **Proactive Error Handling** ✅  
  Comprehensive logging and recovery mechanisms

### 🏗️ **Full Arch Linux Environment**
- **Complete Package Access**: Full Arch repos + AUR (60,000+ packages)
- **Development Tools**: Complete build environment for compiling from source
- **Gaming Packages**: Steam, Lutris, Wine, etc. without conflicts
- **System Tools**: Advanced utilities not available in SteamOS

### 🔧 **Smart Container Features**
- **Automatic Arch Updates**: Keeps your Arch environment current
- **Shared Home Directory**: Access to your Steam Deck files
- **Hardware Access**: GPU, controllers, and other devices work normally
- **Network Integration**: Shares network settings with SteamOS

## **How It Works Behind the Scenes:**

1. **Container Creation**: Creates an isolated Arch Linux environment
2. **Desktop Export**: Makes Pamac appear as a native SteamOS application
3. **File Integration**: Installed apps can create shortcuts on your desktop
4. **Cleanup Automation**: Pacman hooks ensure removed software doesn't leave orphaned shortcuts

## **User Experience:**

```bash
# Installation - Run once:
./SteamOS-Pamac-Installer.sh

1. Run installation script
2. Select from options in terminal via 1,2,3

# Daily usage - Just like any native app:
# 1. Open Start menu
# 2. Navigate to "System" or "All Applications" 
# 3. Click "Pamac Manager"
# 4. Install/remove software normally
# 5. Installed apps appear in your menu automatically
```

## **Why This Approach Works Perfectly:**

- **SteamOS Compatibility**: Doesn't break during SteamOS updates
- **Performance**: Negligible overhead - apps run at native speed
- **Safety**: Can't break your Steam Deck system
- **Flexibility**: Full Linux software ecosystem available
- **Convenience**: Works exactly like a native package manager

This gives you the best of both worlds: SteamOS's gaming-optimized stability with Arch Linux's comprehensive software availability, all while maintaining the user experience of a native package manager.

# Steam-OS-Pamac

## Installation

### Option 1: Remote install (recommended)
```bash
bash -c "$(curl -sSL https://raw.githubusercontent.com/your-repo/Steam-OS-Pamac/main/SteamOS-Pamac-Installer.sh)"
```

> **Why not `curl | bash`?** Piping into bash (`curl ... | bash`) replaces stdin
> with the pipe, so the script cannot read your keyboard for interactive prompts
> (battery warnings, destructive-reset confirmations, etc.). Using command
> substitution (`bash -c "$(curl ...)"`) downloads the script first, then
> executes it as a string, leaving stdin connected to your terminal.

### Option 2: Download and run locally
```bash
chmod +x ~/Desktop/SteamOS-Pamac-Installer.sh
./SteamOS-Pamac-Installer.sh
```




### Process
```mermaid
graph LR
A[SteamOS Host] --> B[Distrobox Container]
B --> C[Arch Linux Userspace]
C --> D[Pamac Package Manager]
C --> E[AUR Packages]
D --> F[GUI Applications]
E --> F
F --> G[SteamOS Application Menu]
```

## Security Model

This script makes deliberate security tradeoffs to provide a seamless
package-manager experience on a locked-down gaming device. Understanding
these tradeoffs helps you decide if the script is right for your threat
model.

### Isolation
- All package operations run inside a Distrobox/Podman rootless container
- The host SteamOS is never directly modified (except for desktop-file
  symlinks in `~/.local/share/applications`)
- Container storage lives in `~/.local/share/containers/`, not on the
  root filesystem

### Privilege Escalation
- **Polkit rules**: On single-user devices (1 human user detected), the
  wheel group gets passwordless `org.manjaro.pamac.*` via polkit. On
  multi-user hosts, the rule is scoped to the installing user only.
- **Sudoers**: `timestamp_timeout=0` scoped to `%wheel` — sudo credentials
  are not cached between operations, limiting the escalation window.
- **`--strict-security`**: Disables the `SigLevel = TrustAll` keyring
  recovery fallback and the fake `systemd-run` wrapper. AUR builds that
  rely on `DynamicUser=yes` will fail under strict mode, which is the
  correct behavior for security-sensitive hosts.

### Fake systemd-run
- The wrapper only triggers when real systemd is unavailable inside the
  container — it is never installed on the host.
- It logs all operations to `/tmp/systemd-run-fake.log` for auditability.
- Under `--strict-security`, the wrapper is refused entirely.

### AUR Trust
- The Chaotic-AUR, archlinuxcn, and EndeavourOS repositories are
  optional and gated behind `--enable-extra-repos`. They are disabled
  by default.
- Key imports use dynamic discovery first (mirror-distributed keyring
  packages) before falling back to keyservers. User-configurable
  `*_KEY_ID` env vars always override hardcoded fallbacks.

### What the script does NOT do
- It does not modify SteamOS read-only partitions
- It does not disable Secure Boot or other firmware protections
- It does not create system-wide service accounts or daemons

### Post-Upgrade Maintenance

**SSH configuration (`--enable-ssh-env` only):** Major SteamOS version
upgrades (e.g. 3.x → 4.x) may rewrite host-side files under `/etc/ssh/`.
If you used `--enable-ssh-env`, the following may need re-creation after
a major upgrade:
- `/etc/ssh/sshd_config.d/permit-user-env.conf` (PermitUserEnvironment)
- `~/.ssh/environment` (host environment variables)

Re-run the script with `--enable-ssh-env` to re-apply these settings,
or manually restore them per the in-script guidance.

**Everything else persists** across SteamOS updates: container data,
desktop file exports, pamac configuration, and the GUI/CLI wrappers
all survive normal `steamOS update` cycles.

### Verification Test
When you run the script, you'll see this final success message:
```
🎉 SETUP COMPLETE! 🎉
Enhanced Pamac with AUR support is now installed and ready to use.

ACCESS METHODS:
  🖥️  Desktop Mode: Application Launcher → 'Pamac Package Manager'
  🛠️  Management: Use 'BoxBuddy' for advanced container operations
```

All installed applications (including those from AUR) will appear in your application menu under appropriate categories, looking and behaving like native SteamOS applications. The container provides full Arch Linux compatibility while keeping SteamOS perfectly intact.


