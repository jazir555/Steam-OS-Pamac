#!/bin/bash

set -euo pipefail

readonly SCRIPT_VERSION="5.2.0"
readonly DEFAULT_CONTAINER_NAME="arch-pamac"
readonly LOG_FILE="$HOME/distrobox-pamac-setup.log"
readonly REQUIRED_TOOLS=("distrobox")
CONTAINER_HAS_INIT="unknown"

CONTAINER_NAME="${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}"

if [[ -n "${SUDO_USER:-}" ]]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER=$(whoami)
fi

ENABLE_MULTILIB="${ENABLE_MULTILIB:-true}"
ENABLE_BUILD_CACHE="${ENABLE_BUILD_CACHE:-true}"
ENABLE_GAMING_PACKAGES="${ENABLE_GAMING_PACKAGES:-false}"
FORCE_REBUILD="${FORCE_REBUILD:-false}"
OPTIMIZE_MIRRORS="${OPTIMIZE_MIRRORS:-true}"

DRY_RUN="${DRY_RUN:-false}"
CHECK_ONLY="${CHECK_ONLY:-false}"
UNINSTALL="${UNINSTALL:-false}"
LOG_LEVEL="${LOG_LEVEL:-normal}"

setup_colors() {
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        readonly GREEN=$(tput setaf 2)
        readonly YELLOW=$(tput setaf 3)
        readonly BLUE=$(tput setaf 4)
        readonly RED=$(tput setaf 1)
        readonly BOLD=$(tput bold)
        readonly NC=$(tput sgr0)
    else
        readonly GREEN='' YELLOW='' BLUE='' RED='' BOLD='' NC=''
    fi
}

initialize_logging() {
    local os_version
    os_version=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Unknown')

    local dry_run_header=""
    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run_header=" (DRY RUN MODE)"
    fi

    {
        echo "=== Steam Deck Pamac Setup v${SCRIPT_VERSION}${dry_run_header} - $(date) ==="
        echo "User: $CURRENT_USER"
        echo "OS: $os_version"
        echo "Container: $CONTAINER_NAME"
        echo "Features: MULTILIB=$ENABLE_MULTILIB GAMING=$ENABLE_GAMING_PACKAGES BUILD_CACHE=$ENABLE_BUILD_CACHE OPTIMIZE_MIRRORS=$OPTIMIZE_MIRRORS"
        echo "=========================================="
    } > "$LOG_FILE"

    trap 'echo "=== Run finished: $(date) - Exit: $? ===" >> "$LOG_FILE"' EXIT
}

_log() {
    local level="$1" color="$2" message="$3"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    local plain_message
    plain_message=$(echo "$message" | sed 's/\x1B\[[0-9;]*[A-Za-z]//g')

    echo "[$timestamp] $level: $plain_message" >> "$LOG_FILE"

    case "$LOG_LEVEL" in
        "quiet") [[ "$level" == "ERROR" ]] && echo -e "${color}${message}${NC}" ;;
        "normal") [[ "$level" != "DEBUG" ]] && echo -e "${color}${message}${NC}" ;;
        "verbose") echo -e "${color}${message}${NC}" ;;
    esac
}

log_step()   { _log "STEP"    "$BLUE"   "\n${BOLD}==> $1${NC}"; }
log_info()   { _log "INFO"    ""        "$1"; }
log_success(){ _log "SUCCESS" "$GREEN"  "✓ $1"; }
log_warn()   { _log "WARN"    "$YELLOW" "⚠ $1"; }
log_error()  { _log "ERROR"   "$RED"    "✗ $1"; }
log_debug()  { _log "DEBUG"   ""        "$1"; }

run_command() {
    log_debug "Executing: $*"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY RUN] Would execute: $*"
        return 0
    fi

    local status=0
    set +e
    if [[ "$LOG_LEVEL" == "verbose" ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"; status=${PIPESTATUS[0]}
    else
        "$@" >> "$LOG_FILE" 2>&1; status=$?
    fi
    set -e

    [[ $status -ne 0 ]] && log_debug "Command failed with exit code: $status"
    return "$status"
}

container_root_exec() {
  if [[ "${DISTROBOX_CONTAINER_MANAGER:-podman}" == "docker" ]]; then
    docker exec -i -u 0 "$CONTAINER_NAME" "$@"
  else
    podman exec -i -u 0 -e HOME="/home/${CURRENT_USER}" "$CONTAINER_NAME" "$@"
  fi
}

container_user_exec() {
  if [[ "${DISTROBOX_CONTAINER_MANAGER:-podman}" == "docker" ]]; then
    docker exec -i -u "$CURRENT_USER" -e HOME="/home/${CURRENT_USER}" "$CONTAINER_NAME" "$@"
  else
    podman exec -i -u "$CURRENT_USER" -e HOME="/home/${CURRENT_USER}" "$CONTAINER_NAME" "$@"
  fi
}

container_start() {
  local mgr="${DISTROBOX_CONTAINER_MANAGER:-podman}"
  if [[ "$mgr" == "docker" ]]; then
    docker start "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
  else
    podman start "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
  fi
}

container_is_running() {
  if [[ "${DISTROBOX_CONTAINER_MANAGER:-podman}" == "docker" ]]; then
    docker inspect "$CONTAINER_NAME" --format '{{.State.Running}}' 2>/dev/null | grep -q "true"
  else
    podman inspect "$CONTAINER_NAME" --format '{{.State.Running}}' 2>/dev/null | grep -q "true"
  fi
}

container_get_status() {
  if [[ "${DISTROBOX_CONTAINER_MANAGER:-podman}" == "docker" ]]; then
    docker inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "not_found"
  else
    podman inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "not_found"
  fi
}

container_is_usable() {
  container_root_exec bash -c "echo ok" 2>/dev/null | grep -q "ok"
}

force_remove_container() {
  local name="$1"
  local mgr="${DISTROBOX_CONTAINER_MANAGER:-podman}"

  if [[ "$mgr" == "docker" ]]; then
    docker rm -f "$name" 2>/dev/null || true
    return
  fi

  if ! podman inspect "$name" >/dev/null 2>&1; then
    return
  fi

  local status
  status=$(podman inspect "$name" --format '{{.State.Status}}' 2>/dev/null || echo "not_found")
  if [[ "$status" == "not_found" ]]; then
    return
  fi

  if [[ "$status" == "stopping" || "$status" == "stopped" ]]; then
    log_debug "Container '$name' in '$status' state - killing container processes"
    local pid
    pid=$(podman inspect "$name" --format '{{.State.Pid}}' 2>/dev/null || echo "0")
    if [[ "$pid" -gt 0 ]]; then
      kill -9 "$pid" 2>/dev/null || true
    fi
    local conmon_pid
    conmon_pid=$(podman inspect "$name" --format '{{.ConmonPidFile}}' 2>/dev/null || true)
    if [[ -n "$conmon_pid" && -f "$conmon_pid" ]]; then
      local cpid
      cpid=$(cat "$conmon_pid" 2>/dev/null || echo "0")
      if [[ "$cpid" -gt 0 ]]; then
        kill -9 "$cpid" 2>/dev/null || true
      fi
    fi
    sleep 1
  fi

  podman rm -f "$name" 2>/dev/null || true
  if podman inspect "$name" >/dev/null 2>&1; then
    log_debug "User podman rm failed, trying sudo..."
    sudo podman rm -f "$name" 2>/dev/null || true
  fi
}

validate_container_name() {
    if [[ ! "$CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        log_error "Invalid container name: $CONTAINER_NAME"
        log_info "Container names must start with an alphanumeric character and contain only letters, numbers, hyphens, and underscores."
        return 1
    fi

    if [[ ${#CONTAINER_NAME} -gt 63 ]]; then
        log_error "Container name too long (max 63 characters): $CONTAINER_NAME"
        return 1
    fi
}

check_system_requirements() {
    log_step "Checking system requirements..."
    local missing_tools=()
    local all_ok=true

    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
            all_ok=false
        fi
    done

    local have_runtime=false
    if command -v podman >/dev/null 2>&1; then
        have_runtime=true
        log_debug "Found container runtime: podman"
    elif command -v docker >/dev/null 2>&1; then
        have_runtime=true
        log_debug "Found container runtime: docker"
    fi

    if [[ "$have_runtime" == "false" ]]; then
        missing_tools+=("podman or docker")
        all_ok=false
    fi

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "On SteamOS, install distrobox with:"
        log_info "  curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix ~/.local"
        log_info "Then restart your terminal or run: source ~/.bashrc"
    else
        log_success "All required tools are present."
    fi

    local available_space
    if available_space=$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}'); then
        if [[ -n "$available_space" ]] && [[ $available_space -lt 2097152 ]]; then
            log_warn "Low disk space detected. At least 2GB is recommended."
            log_info "Available space: $(( available_space / 1024 ))MB"
            all_ok=false
        elif [[ -n "$available_space" ]]; then
            log_success "Sufficient disk space available: $(( available_space / 1024 / 1024 ))GB"
        fi
    else
        log_warn "Could not check disk space."
    fi

    if grep -q "ID=steamos" /etc/os-release 2>/dev/null; then
        log_success "SteamOS detected."
    else
        log_info "Not running on SteamOS. Script will adapt automatically."
    fi

    [[ "$all_ok" == "true" ]]
}

ensure_podman() {
    if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        log_debug "Podman already usable"
        export DISTROBOX_CONTAINER_MANAGER=podman
        return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        log_debug "Docker found - using it"
        export DISTROBOX_CONTAINER_MANAGER=docker
        return 0
    fi

    log_step "No container runtime found - Distrobox will handle setup"
    export DISTROBOX_CONTAINER_MANAGER=podman
    log_info "Distrobox will automatically install podman when creating the container."
    log_success "Podman setup will be handled automatically by Distrobox."
}

show_usage() {
    cat << EOF
${BOLD}Steam Deck Pamac Setup v${SCRIPT_VERSION}${NC}

USAGE:
  $0 [OPTIONS]

OPTIONS:
  --container-name NAME     Set container name (default: ${DEFAULT_CONTAINER_NAME})
  --force-rebuild           Rebuild existing container if it exists
  --enable-multilib         Enable 32-bit package support (default)
  --disable-multilib        Explicitly disable 32-bit package support
  --enable-gaming           Install extra gaming packages
  --disable-gaming          Do not install gaming packages (default)
  --enable-build-cache      Enable persistent build cache for yay (default)
  --disable-build-cache     Disable persistent build cache for yay
  --optimize-mirrors        Select fastest Pacman mirrors (default)
  --no-optimize-mirrors     Do not change default Pacman mirrors
  --uninstall               Remove container and all related files
  --check                   Perform system checks and exit without installing
  --dry-run                 Show what would be done without making changes
  --verbose                 Show detailed output, including command logs
  --quiet                   Only show errors
  --version                 Show version information
  -h, --help                Show this help message

EXAMPLES:
  $0                                       # Basic setup
  $0 --enable-gaming --no-optimize-mirrors # Gaming setup, skip mirror optimization
  $0 --container-name my-arch              # Custom container name
  $0 --check                               # Verify system is ready
  $0 --uninstall                           # Remove everything
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --container-name)
                [[ -z "${2:-}" ]] && { log_error "Container name cannot be empty"; exit 1; }
                CONTAINER_NAME="$2"
                shift 2
                ;;
            --force-rebuild) FORCE_REBUILD="true"; shift ;;
            --enable-multilib) ENABLE_MULTILIB="true"; shift ;;
            --disable-multilib) ENABLE_MULTILIB="false"; shift ;;
            --enable-gaming) ENABLE_GAMING_PACKAGES="true"; shift ;;
            --disable-gaming) ENABLE_GAMING_PACKAGES="false"; shift ;;
            --enable-build-cache) ENABLE_BUILD_CACHE="true"; shift ;;
            --disable-build-cache) ENABLE_BUILD_CACHE="false"; shift ;;
            --optimize-mirrors) OPTIMIZE_MIRRORS="true"; shift ;;
            --no-optimize-mirrors) OPTIMIZE_MIRRORS="false"; shift ;;
            --uninstall) UNINSTALL="true"; shift ;;
            --dry-run) DRY_RUN="true"; shift ;;
            --check) CHECK_ONLY="true"; shift ;;
            --verbose) LOG_LEVEL="verbose"; shift ;;
            --quiet) LOG_LEVEL="quiet"; shift ;;
            --version) echo "Steam Deck Pamac Setup v${SCRIPT_VERSION}"; exit 0 ;;
            -h|--help) show_usage; exit 0 ;;
            *) log_error "Unknown option: $1"; show_usage; exit 1 ;;
        esac
    done
}

uninstall_setup() {
    log_step "Uninstalling Pamac setup for container: $CONTAINER_NAME"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY RUN] Uninstall simulation started."
    fi

    local container_found=false
    if distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        container_found=true
        log_info "Container '$CONTAINER_NAME' found. Cleaning exported apps and removing container..."

        local container_accessible=false
        if distrobox-enter "$CONTAINER_NAME" -- bash -c "echo accessible" 2>/dev/null | grep -q "accessible"; then
            container_accessible=true
        fi

        if [[ "$container_accessible" == "true" ]]; then
            local export_list
            export_list=$(distrobox-enter "$CONTAINER_NAME" -- distrobox-export --list 2>/dev/null || true)
            local parsed_apps
            parsed_apps=$(echo "$export_list" | grep -E "^- (App|app|Application):" | sed 's/^- [A-Za-z]*: *//' || true)
            if [[ -n "$parsed_apps" ]]; then
                log_info "Removing exported applications..."
                while IFS= read -r app_name; do
                    [[ -z "$app_name" ]] && continue
                    log_info "Un-exporting app: $app_name"
                    distrobox-enter "$CONTAINER_NAME" -- distrobox-export --app "$app_name" --delete 2>/dev/null || true
                done <<< "$parsed_apps"
            fi
        else
            log_warn "Container not accessible for export unlisting. Will clean desktop files directly."
        fi

        run_command distrobox stop "$CONTAINER_NAME" || true
        run_command distrobox rm -f "$CONTAINER_NAME" || true
        force_remove_container "$CONTAINER_NAME"
    else
        log_info "Container '$CONTAINER_NAME' not found, skipping container removal."
    fi

    local app_dir="$HOME/.local/share/applications"
    if [[ -d "$app_dir" ]]; then
        log_info "Cleaning up exported application launchers"
        if [[ "$DRY_RUN" != "true" ]]; then
            local cleaned=0
            while IFS= read -r -d '' df; do
                if grep -l "distrobox enter ${CONTAINER_NAME}" "$df" >/dev/null 2>&1; then
                    rm -f "$df" 2>/dev/null || true
                    cleaned=$((cleaned + 1))
                fi
            done < <(find "$app_dir" -maxdepth 1 -type f -name "*.desktop" -print0 2>/dev/null)
            find "$app_dir" -maxdepth 1 -type f -name "*-${CONTAINER_NAME}.desktop" -delete 2>/dev/null || true
            if [[ "$container_found" == "true" ]]; then
                while IFS= read -r -d '' df; do
                    if grep -l "X-Distrobox-Container=${CONTAINER_NAME}" "$df" >/dev/null 2>&1; then
                        rm -f "$df" 2>/dev/null || true
                        cleaned=$((cleaned + 1))
                    fi
                done < <(find "$app_dir" -maxdepth 1 -type f -name "*pamac*.desktop" -print0 2>/dev/null)
            fi
            command -v update-desktop-database >/dev/null 2>&1 && \
                update-desktop-database "$app_dir" 2>/dev/null || true
        else
            log_warn "[DRY RUN] Would search for and delete .desktop files in $app_dir"
        fi
    fi

    local cache_dir="$HOME/.cache/yay-${CONTAINER_NAME}"
    [[ -d "$cache_dir" ]] && { log_info "Removing build cache at $cache_dir"; [[ "$DRY_RUN" != "true" ]] && rm -rf "$cache_dir"; }

    local bin_file="$HOME/.local/bin/pamac-${CONTAINER_NAME}"
    [[ -f "$bin_file" ]] && { log_info "Removing CLI wrapper at $bin_file"; [[ "$DRY_RUN" != "true" ]] && rm -f "$bin_file"; }

    local icon_svg="$HOME/.local/share/icons/hicolor/scalable/apps/pamac-manager.svg"
    local icon_png="$HOME/.local/share/icons/hicolor/48x48/apps/pamac-manager.png"
    [[ -f "$icon_svg" ]] && { log_info "Removing icon: $icon_svg"; [[ "$DRY_RUN" != "true" ]] && rm -f "$icon_svg"; }
    [[ -f "$icon_png" ]] && { log_info "Removing icon: $icon_png"; [[ "$DRY_RUN" != "true" ]] && rm -f "$icon_png"; }

    command -v gtk-update-icon-cache >/dev/null 2>&1 && \
        gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" -f 2>/dev/null || true

    log_success "Uninstallation completed."
}

wait_for_container() {
  local max_attempts=30
  local attempt=0
  log_info "Waiting for container '$CONTAINER_NAME' to become ready..."

  set +e
  while true; do
    attempt=$((attempt + 1))

    local status
    status=$(container_get_status)
    log_debug "Container status: $status (attempt $attempt/$max_attempts)"

    case "$status" in
      "running")
        if container_root_exec bash -c "echo ready" 2>/dev/null | grep -q "ready"; then
          set -e
          log_success "Container is ready."
          return 0
        fi
        ;;
      "stopping"|"paused"|"stopped")
        if [[ $attempt -le 5 ]]; then
          log_debug "Container in '$status' state, waiting..."
        else
          log_warn "Container stuck in '$status' state - removing and recreating"
          set -e
          force_remove_container "$CONTAINER_NAME"
          return 2
        fi
        ;;
      "not_found")
        set -e
        log_error "Container '$CONTAINER_NAME' not found."
        return 1
        ;;
      "created")
        log_debug "Container in 'created' state, attempting start..."
        container_start
        ;;
    esac

    if [[ $attempt -gt $max_attempts ]]; then
      set -e
      log_error "Container failed to become ready after $((max_attempts * 2)) seconds."
      log_info "Try removing with: podman rm -f $CONTAINER_NAME"
      return 1
    fi

    sleep 2
    if [[ $((attempt % 5)) -eq 0 ]]; then
      log_info "Still waiting... (${attempt}/${max_attempts})"
    fi
  done
}

detect_init_support() {
    if [[ "$CONTAINER_HAS_INIT" != "unknown" ]]; then
        return
    fi

    log_info "Detecting container init system support..."

    if grep -q "ID=steamos" /etc/os-release 2>/dev/null; then
        CONTAINER_HAS_INIT="true"
        log_info "SteamOS detected - assuming init (systemd) is supported."
        return
    fi

    if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -c 2>/dev/null; then
        CONTAINER_HAS_INIT="false"
        log_info "Running inside a container without systemd - using non-init mode."
        return
    fi

    if [[ "$(cat /proc/1/comm 2>/dev/null || echo unknown)" != "systemd" ]]; then
        CONTAINER_HAS_INIT="false"
        log_info "Host init is not systemd - using non-init container mode."
        return
    fi

    local init_binary=""
    init_binary=$(podman info --format '{{.Host.InitPath}}' 2>/dev/null || echo "")
    if [[ -n "$init_binary" ]]; then
        local resolved
        resolved=$(command -v "$init_binary" 2>/dev/null || echo "")
        if [[ -n "$resolved" ]] || [[ -f "$init_binary" ]]; then
            CONTAINER_HAS_INIT="true"
            log_info "Init system supported (podman init binary: $init_binary)."
        else
            CONTAINER_HAS_INIT="false"
            log_info "Init binary '$init_binary' not found - using non-init container."
        fi
    else
        CONTAINER_HAS_INIT="false"
        log_info "No podman init support detected - using non-init container."
    fi
}

create_container() {
    log_step "Creating Arch Linux container: $CONTAINER_NAME"

    detect_init_support

    local -a create_args=(
        --name "$CONTAINER_NAME"
        --image "archlinux:latest"
        --yes
    )

    if [[ "$CONTAINER_HAS_INIT" == "true" ]]; then
        create_args+=(--init)
        log_info "Creating container with init (systemd) support."
    else
        log_info "Creating container without init (systemd not available in this environment)."
    fi

    if [[ "$ENABLE_BUILD_CACHE" == "true" ]]; then
        local cache_dir="$HOME/.cache/yay-${CONTAINER_NAME}"
        mkdir -p "$cache_dir"
        create_args+=(--volume "${cache_dir}:/home/${CURRENT_USER}/.cache/yay:rw")
        log_info "Enabled persistent build cache: $cache_dir"
    fi

  if ! run_command distrobox create "${create_args[@]}"; then
    log_warn "Container create failed - attempting cleanup and retry..."
    force_remove_container "$CONTAINER_NAME"
    sleep 2
    if ! run_command distrobox create "${create_args[@]}"; then
      log_error "Failed to create Distrobox container after retry."
      return 1
    fi
  fi

  log_info "Starting container..."
  set +e
  container_start
  set -e

  local wait_result=0
  wait_for_container || wait_result=$?

  if [[ "$wait_result" -eq 2 ]]; then
    log_info "Container was stuck, recreating..."
    if run_command distrobox create "${create_args[@]}"; then
      container_start
      wait_for_container || return 1
    else
      log_error "Failed to recreate container after removal."
      return 1
    fi
  elif [[ "$wait_result" -ne 0 ]]; then
    return 1
  fi

  if container_root_exec bash -c "echo ready" 2>/dev/null | grep -q "ready"; then
    log_success "Container is functional and ready."
  else
    log_error "Container created but is not functional."
    return 1
  fi
}

configure_container_base() {
    log_step "Configuring container base environment"

local setup_script=""
read -r -d '' setup_script <<'SETUP_EOF' || true
  set -euo pipefail

  current_user="$1"
  if [[ -z "$current_user" ]]; then
    echo "ERROR: Host username not supplied to container setup." >&2
    exit 1
  fi

  echo "Container: configuring base environment for user='$current_user'"

  rm -f /var/lib/pacman/db.lck

  echo "Installing essential packages..."
pacman -S --noconfirm --needed --overwrite '*' sudo shadow gnupg archlinux-keyring base-devel git go

echo "Initializing pacman keyring..."
pacman-key --init || echo "Warning: pacman-key --init failed"
pacman-key --populate archlinux || echo "Warning: pacman-key --populate failed"

echo "Updating system packages (best-effort)..."
if pacman -Syu --noconfirm --overwrite '*' 2>/dev/null; then
    echo "System packages updated."
else
    echo "Note: --overwrite upgrade had issues, trying alternative approaches..."
    # Sync DB first, then try upgrade
    pacman -Sy --noconfirm || true
    # Explicitly remove conflicting files if DB is now consistent
    pacman -Su --noconfirm --overwrite '*' 2>/dev/null || echo "Warning: partial upgrade may have issues"
fi

if ! id "$current_user" >/dev/null 2>&1; then
    echo "User '$current_user' not found. Creating user with same name."
    useradd -m -G wheel -s /bin/bash "$current_user" || { echo "Error: failed to create user"; exit 1; }
    echo "Created user '$current_user' and added to wheel group."
else
    echo "User '$current_user' exists inside container."
    usermod -aG wheel "$current_user" || echo "Warning: could not add user to wheel group"
fi

if ! getent group wheel >/dev/null 2>&1; then
    groupadd wheel || echo "Warning: groupadd wheel failed"
fi

echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-wheel-nopasswd
chmod 0440 /etc/sudoers.d/99-wheel-nopasswd
echo "Configured passwordless sudo for wheel."

echo "Installing polkit..."
if pacman -S --noconfirm --needed --overwrite '*' polkit; then
    polkit_dir="/etc/polkit-1/rules.d"
    mkdir -p "$polkit_dir"
    cat > "$polkit_dir/10-pamac-nopasswd.rules" << 'POLKIT_EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.manjaro.pamac.") == 0 &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
POLKIT_EOF
    echo "polkit passwordless rule created for pamac operations."
else
    echo "Warning: could not install polkit. pamac GUI may prompt for password."
fi

echo "Setting up D-Bus..."
if command -v dbus-daemon >/dev/null 2>&1; then
    mkdir -p /run/dbus
    if [[ ! -S /run/dbus/system_bus_socket ]]; then
        dbus-daemon --system --fork 2>/dev/null || echo "Note: dbus-daemon start failed (may already be running via init)"
    fi
fi

echo "Setting up pamac-daemon autostart for non-systemd environments..."
init_proc=$(cat /proc/1/comm 2>/dev/null || echo unknown)
if [[ "$init_proc" != "systemd" ]]; then
    echo "Non-systemd container detected. Setting up pamac-daemon launch helper."
    cat > /usr/local/bin/pamac-daemon-launch.sh << 'LAUNCHER_EOF'
#!/bin/bash
set +e
if [[ ! -S /run/dbus/system_bus_socket ]]; then
    mkdir -p /run/dbus
    dbus-daemon --system --fork 2>/dev/null
fi
if command -v pamac-daemon >/dev/null 2>&1; then
    pamac-daemon 2>/dev/null &
fi
LAUNCHER_EOF
    chmod +x /usr/local/bin/pamac-daemon-launch.sh

    cat > /etc/profile.d/pamac-daemon.sh << 'PROFILE_EOF'
#!/bin/bash
/usr/local/bin/pamac-daemon-launch.sh 2>/dev/null &
PROFILE_EOF
    chmod +x /etc/profile.d/pamac-daemon.sh
    echo "pamac-daemon launch helper installed."
else
    echo "Systemd container detected. pamac-daemon will be managed by systemd."
fi

echo "Container base setup finished."
SETUP_EOF

    local _base_rc=0
    set +e
    echo "$setup_script" | container_root_exec bash -s "$CURRENT_USER" 2>&1 | tee -a "$LOG_FILE"
    _base_rc=${PIPESTATUS[0]}
    set -e
    if [[ $_base_rc -ne 0 ]]; then
        log_error "Failed to configure container base environment (exit=$_base_rc)."
        return 1
    fi
}

optimize_pacman_mirrors() {
    if [[ "$OPTIMIZE_MIRRORS" == "false" ]]; then
        log_info "Skipping Pacman mirror optimization as requested."
        return
    fi

    log_step "Optimizing Pacman mirrors"

    local mirror_script
  read -r -d '' mirror_script << 'EOF' || true
  set -euo pipefail

  rm -f /var/lib/pacman/db.lck

  echo "Installing reflector..."
if ! pacman -S --noconfirm --needed --overwrite '*' reflector; then
    echo "Failed to install reflector. Skipping mirror optimization."
    exit 0
fi

echo "Backing up current mirrorlist..."
[[ -f /etc/pacman.d/mirrorlist ]] && cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

echo "Generating optimized mirrorlist (this may take a minute)..."
if timeout 120 reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null; then
    echo "Successfully updated mirrorlist."
else
    echo "Reflector failed or timed out. Restoring backup if available."
    [[ -f /etc/pacman.d/mirrorlist.backup ]] && cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
    exit 0
fi
EOF

    if ! echo "$mirror_script" | container_root_exec bash; then
        log_warn "Mirror optimization had issues. Continuing with default mirrors."
    fi
}

configure_multilib() {
    if [[ "$ENABLE_MULTILIB" == "true" ]]; then
        log_step "Enabling multilib (32-bit) support"

        local multilib_script
  read -r -d '' multilib_script << 'EOF' || true
  set -euo pipefail

  rm -f /var/lib/pacman/db.lck

  if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    echo "Enabling multilib repository..."
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
    echo "Multilib repository enabled."
else
    echo "Multilib repository is already enabled."
fi

echo "Updating package database..."
pacman -Sy --noconfirm
EOF

        if ! echo "$multilib_script" | container_root_exec bash; then
            log_warn "Failed to enable multilib support. 32-bit packages may not be available."
        fi
    fi
}

install_aur_helper() {
    log_step "Installing AUR helper (yay)"

    if container_user_exec bash -c "command -v yay >/dev/null 2>&1"; then
        log_info "AUR helper 'yay' is already installed."
        return 0
    fi

    local yay_script
  read -r -d '' yay_script <<'YAY_EOF' || true
  set -euo pipefail

  current_user="$1"

  rm -f /var/lib/pacman/db.lck

  echo "Installing build dependencies..."
pacman -S --noconfirm --needed --overwrite '*' git base-devel go

echo "Cloning and building yay from AUR..."
rm -rf /tmp/yay
sudo -Hu "$current_user" git clone "https://aur.archlinux.org/yay.git" /tmp/yay
chown -R "$current_user:$current_user" /tmp/yay
sudo -Hu "$current_user" bash -lc "cd /tmp/yay && makepkg -si --noconfirm --clean"
YAY_EOF

    if ! echo "$yay_script" | container_root_exec bash -s "$CURRENT_USER"; then
        log_error "Failed to install AUR helper (yay)."
        return 1
    fi
}

install_pamac() {
    log_step "Installing Pamac package manager"

    if container_user_exec bash -c "command -v pamac-manager >/dev/null 2>&1"; then
        log_info "Pamac is already installed."
        return 0
    fi

    local pamac_script
  read -r -d '' pamac_script <<'PAMAC_EOF' || true
  set -euo pipefail

  current_user="$1"

  rm -f /var/lib/pacman/db.lck

  echo "Installing pamac-aur from AUR..."
sudo -Hu "$current_user" bash -lc "yay -S --noconfirm --needed --noprogressbar pamac-aur"

echo "Configuring Pamac for AUR support..."
if [[ -f /etc/pamac.conf ]]; then
    sed -i 's/^#EnableAUR/EnableAUR/' /etc/pamac.conf
    sed -i 's/^#CheckAURUpdates/CheckAURUpdates/' /etc/pamac.conf
    sed -i 's/^#CheckAURVCSUpdates/CheckAURVCSUpdates/' /etc/pamac.conf
    if ! grep -q '^EnableAUR' /etc/pamac.conf; then
        echo "EnableAUR" >> /etc/pamac.conf
    fi
    if ! grep -q '^CheckAURUpdates' /etc/pamac.conf; then
        echo "CheckAURUpdates" >> /etc/pamac.conf
    fi
    echo "Pamac configuration updated for AUR support."
else
    echo "Warning: /etc/pamac.conf not found. Creating minimal config."
    mkdir -p /etc
    printf 'EnableAUR\nCheckAURUpdates\nCheckAURVCSUpdates\n' > /etc/pamac.conf
fi

echo "Syncing package database..."
init_proc=$(cat /proc/1/comm 2>/dev/null || echo unknown)
if [[ "$init_proc" == "systemd" ]]; then
    systemctl enable --now pamac-daemon 2>/dev/null || echo "Note: pamac-daemon service could not be enabled"
    pamac refresh --no-confirm 2>/dev/null || pamac refresh --force 2>/dev/null || echo "Note: pamac DB sync failed"
else
    /usr/local/bin/pamac-daemon-launch.sh 2>/dev/null || true
    sleep 1
    pamac refresh --no-confirm 2>/dev/null || pamac refresh --force 2>/dev/null || echo "Note: pamac DB sync failed (daemon may not be running)"
fi

if command -v pamac-manager >/dev/null 2>&1; then
    echo "Pamac installed successfully."
    pamac --version 2>/dev/null || echo "Pamac version info not available"
else
    echo "Error: Pamac installation verification failed."
    exit 1
fi

echo "Creating pamac-manager launch wrapper..."
cat > /usr/local/bin/pamac-manager-wrapper << 'WRAPPER'
#!/bin/bash
init_proc=$(cat /proc/1/comm 2>/dev/null || echo unknown)
if [[ "$init_proc" != "systemd" ]]; then
    if [[ ! -S /run/dbus/system_bus_socket ]]; then
        mkdir -p /run/dbus 2>/dev/null || true
        dbus-daemon --system --fork 2>/dev/null || true
    fi
    if command -v pamac-daemon >/dev/null 2>&1; then
        if ! pidof pamac-daemon >/dev/null 2>&1; then
            pamac-daemon 2>/dev/null &
            sleep 1
        fi
    fi
fi
exec pamac-manager "$@"
WRAPPER
chmod +x /usr/local/bin/pamac-manager-wrapper
echo "pamac-manager-wrapper created."
PAMAC_EOF

    if ! echo "$pamac_script" | container_root_exec bash -s "$CURRENT_USER"; then
        log_error "Failed to install Pamac."
        return 1
    fi
}

install_gaming_packages() {
    if [[ "$ENABLE_GAMING_PACKAGES" != "true" ]]; then
        log_info "Skipping gaming packages (use --enable-gaming to include them)."
        return
    fi

    log_step "Installing gaming packages"

    local gaming_script
    read -r -d '' gaming_script << 'EOF' || true
set -euo pipefail

current_user="$1"
is_multilib="$2"
gaming_packages=( "lutris" "wine-staging" "winetricks" "gamemode" "mangohud" )

if [[ "$is_multilib" == "true" ]]; then
    echo "Adding 32-bit gaming libraries..."
    gaming_packages+=( "lib32-gamemode" "lib32-mangohud" )
fi

echo "Installing gaming packages: ${gaming_packages[*]}"
failed_packages=()

for package in "${gaming_packages[@]}"; do
    echo "Installing ${package}..."
    if ! sudo -Hu "$current_user" bash -lc "yay -S --noconfirm --needed --noprogressbar ${package}"; then
        echo "Warning: Failed to install ${package}"
        failed_packages+=("${package}")
    fi
done

if [[ ${#failed_packages[@]} -gt 0 ]]; then
    echo "Warning: Some packages failed to install: ${failed_packages[*]}"
else
    echo "All gaming packages installed successfully."
fi
EOF

    if ! echo "$gaming_script" | container_root_exec bash -s "$CURRENT_USER" "$ENABLE_MULTILIB"; then
        log_warn "Gaming package installation encountered errors."
    fi
}

export_pamac_to_host() {
    log_step "Exporting Pamac to host system"

    local icon_svg_dir="$HOME/.local/share/icons/hicolor/scalable/apps"
    local icon_png48_dir="$HOME/.local/share/icons/hicolor/48x48/apps"
    mkdir -p "$icon_svg_dir" "$icon_png48_dir"

    log_info "Copying pamac icons from container to host..."

    set +e
    if container_root_exec test -f /usr/share/icons/hicolor/scalable/apps/pamac-manager.svg 2>/dev/null; then
        container_root_exec cat /usr/share/icons/hicolor/scalable/apps/pamac-manager.svg > "$icon_svg_dir/pamac-manager.svg" 2>/dev/null
        if [[ -s "$icon_svg_dir/pamac-manager.svg" ]]; then
            log_info "Copied SVG icon"
        else
            rm -f "$icon_svg_dir/pamac-manager.svg"
            log_warn "SVG icon copy produced empty file, removed"
        fi
    fi
    if container_root_exec test -f /usr/share/icons/hicolor/48x48/apps/pamac-manager.png 2>/dev/null; then
        container_root_exec cat /usr/share/icons/hicolor/48x48/apps/pamac-manager.png > "$icon_png48_dir/pamac-manager.png" 2>/dev/null
        if [[ -s "$icon_png48_dir/pamac-manager.png" ]]; then
            log_info "Copied PNG icon"
        else
            rm -f "$icon_png48_dir/pamac-manager.png"
            log_warn "PNG icon copy produced empty file, removed"
        fi
    fi
    set -e

    command -v gtk-update-icon-cache >/dev/null 2>&1 && \
        gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" -f 2>/dev/null || true

  log_info "Exporting Pamac application using distrobox-export..."
  if run_command distrobox-enter "$CONTAINER_NAME" -- distrobox-export --app pamac-manager; then
    log_success "Pamac exported successfully using distrobox-export."
    local exported_desktop
    exported_desktop=$(find "$HOME/.local/share/applications" -maxdepth 1 -name "pamac-manager*.desktop" -print -quit 2>/dev/null)
    if [[ -n "$exported_desktop" ]]; then
        if grep -q '^Exec=.*pamac-manager$' "$exported_desktop" 2>/dev/null; then
            sed -i 's/^Exec=.*pamac-manager$/Exec=distrobox enter '${CONTAINER_NAME}' -- pamac-manager-wrapper/' "$exported_desktop"
            log_info "Patched desktop entry to use wrapper: $exported_desktop"
        fi
    fi
  else
    log_warn "distrobox-export failed. Creating manual desktop entry..."

        local desktop_dir="$HOME/.local/share/applications"
        mkdir -p "$desktop_dir"

        local desktop_file="$desktop_dir/pamac-manager-${CONTAINER_NAME}.desktop"
        cat > "$desktop_file" << DESKTOP_EOF
[Desktop Entry]
Name=Pamac Manager
Comment=Package Manager for Arch Linux Container
Exec=distrobox enter ${CONTAINER_NAME} -- pamac-manager-wrapper
Icon=pamac-manager
Terminal=false
Type=Application
Categories=System;PackageManager;Settings;
Keywords=package;manager;software;arch;aur;
StartupNotify=true
X-Distrobox-App=pamac-manager
X-Distrobox-Container=${CONTAINER_NAME}
DESKTOP_EOF
        chmod +x "$desktop_file"
        log_success "Created manual desktop entry: $desktop_file"
    fi

    if command -v update-desktop-database >/dev/null 2>&1; then
        run_command update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    fi

    local bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"
    local cli_wrapper="$bin_dir/pamac-${CONTAINER_NAME}"

    cat > "$cli_wrapper" << WRAPPER_EOF
#!/bin/bash
exec distrobox enter "${CONTAINER_NAME}" -- pamac "\$@"
WRAPPER_EOF
    chmod +x "$cli_wrapper"
    log_info "Created CLI wrapper: $cli_wrapper"

    if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
        log_info "Add '$bin_dir' to your PATH to use the CLI wrapper directly."
    fi
}

setup_post_install_hooks() {
    log_step "Setting up post-install hooks for desktop integration"

    local hook_script
    read -r -d '' hook_script <<'HOOK_EOF' || true
set -euo pipefail

current_user="$1"
container_name="$2"

hook_dir="/etc/pacman.d/hooks"
mkdir -p "$hook_dir"

cat > "$hook_dir/99-distrobox-export.hook" << 'HOOKDEF'
[Trigger]
Operation = Install
Operation = Remove
Type = Package
Target = *

[Action]
Description = Syncing desktop entries to host via distrobox-export
When = PostTransaction
Exec = /usr/local/bin/distrobox-export-hook.sh
HOOKDEF

  cat > "/usr/local/bin/distrobox-export-hook.sh" << HOOKSCRIPT
#!/bin/bash
set +e

APP_DIR="/home/${current_user}/.local/share/applications"
EXPORT_LOG="/tmp/distrobox-export-hook.log"
echo "\$(date): Hook triggered" > "\$EXPORT_LOG"

# Remove stale exports for apps no longer installed in container
if [[ -d "\$APP_DIR" ]]; then
    for df in "\$APP_DIR"/*.desktop; do
        [[ -f "\$df" ]] || continue
        local_app=\$(grep '^X-Distrobox-App=' "\$df" 2>/dev/null | cut -d= -f2)
        [[ -z "\$local_app" ]] && continue
        if [[ ! -f "/usr/share/applications/\${local_app}.desktop" ]]; then
            echo "Removing stale export: \$df" >> "\$EXPORT_LOG"
            rm -f "\$df"
        fi
    done
fi

if command -v distrobox-export >/dev/null 2>&1; then
    exported=0
    for desktop in /usr/share/applications/*.desktop; do
        [[ -f "\$desktop" ]] || continue
        grep -qi 'NoDisplay=true' "\$desktop" && continue
        app_name=\$(basename "\$desktop" .desktop)
        if distrobox-export --app "\$app_name" 2>/dev/null; then
            exported=\$((exported + 1))
        fi
    done
    echo "\$(date): Exported \$exported apps" >> "\$EXPORT_LOG"
fi

if command -v update-desktop-database >/dev/null 2>&1 && [[ -d "\$APP_DIR" ]]; then
    update-desktop-database "\$APP_DIR" 2>/dev/null || true
fi
HOOKSCRIPT

chmod +x "/usr/local/bin/distrobox-export-hook.sh"
echo "Post-install hook configured."
HOOK_EOF

    if ! echo "$hook_script" | container_root_exec bash -s "$CURRENT_USER" "$CONTAINER_NAME"; then
        log_warn "Failed to set up post-install hooks. Newly installed apps may not auto-appear in menu."
    fi
}

export_existing_apps() {
  log_step "Exporting existing desktop applications from container"

  local export_script
  read -r -d '' export_script <<'EXPORT_EOF' || true
  set +e

  current_user="$1"
  container_name="$2"
  exported=0
  failed=0

  for desktop in /usr/share/applications/*.desktop; do
    [[ -f "$desktop" ]] || continue
    app_name=$(basename "$desktop" .desktop)

    grep -qi 'NoDisplay=true' "$desktop" && continue
    grep -qi 'TerminalOnly=true' "$desktop" && continue

    if distrobox-export --app "$app_name" 2>/dev/null; then
      exported=$((exported + 1))
    else
      failed=$((failed + 1))
    fi
  done

  echo "Exported $exported applications ($failed failed)"
EXPORT_EOF

  if ! echo "$export_script" | distrobox-enter "$CONTAINER_NAME" -- bash -s "$CURRENT_USER" "$CONTAINER_NAME"; then
    log_warn "Some applications could not be exported to host."
  else
    log_success "Existing applications exported to host menu."
  fi
}

show_completion_message() {
    echo
    log_success "Steam Deck Pamac Setup completed successfully!"
    echo
    echo -e "${BOLD}${BLUE}--- Installation Summary ---${NC}"
    echo "  Container: ${BOLD}$CONTAINER_NAME${NC}"
    echo "  Pamac GUI package manager installed and configured"
    echo "  AUR helper 'yay' available for command-line package management"
    [[ "$OPTIMIZE_MIRRORS" == "true" ]] && echo "  Pacman mirrors optimized for performance"
    [[ "$ENABLE_MULTILIB" == "true" ]] && echo "  32-bit package support enabled"
    [[ "$ENABLE_GAMING_PACKAGES" == "true" ]] && echo "  Gaming packages installed"
    [[ "$ENABLE_BUILD_CACHE" == "true" ]] && echo "  Persistent build cache enabled"
    echo
    echo -e "${BOLD}${GREEN}--- How to Use ---${NC}"
    echo "  Find 'Pamac Manager' in your application menu"
    echo "  Command line access: ${BOLD}distrobox enter $CONTAINER_NAME${NC}"
    echo "  CLI shortcut: ${BOLD}pamac-${CONTAINER_NAME} <command>${NC}"
    echo
    echo -e "${BOLD}${YELLOW}--- Important Notes ---${NC}"
    echo "  Container persists across reboots"
    echo "  To uninstall: run this script with ${BOLD}--uninstall${NC}"
    echo "  Installation log saved to: ${BOLD}$LOG_FILE${NC}"
    echo
}

run_pre_flight_checks() {
    log_step "Running pre-flight system checks..."
    if check_system_requirements; then
        log_success "All system checks passed."
        return 0
    else
        log_error "System requirements not met. Please address the issues above."
        return 1
    fi
}

main() {
    setup_colors

    if [[ "$EUID" -eq 0 ]]; then
        echo -e "\e[91mThis script should not be run as root.\e[0m" >&2
        echo -e "\e[91mPlease run as the regular user (e.g., 'deck' on Steam Deck).\e[0m" >&2
        exit 1
    fi

    parse_arguments "$@"
    initialize_logging

    if [[ "$UNINSTALL" == "true" ]]; then
        uninstall_setup
        exit 0
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        ensure_podman
        run_pre_flight_checks
        exit $?
    fi

    validate_container_name || exit 1
    export PODMAN_ASSUME_YES=1

    run_pre_flight_checks || exit 1
    ensure_podman

    echo -e "${BOLD}${BLUE}Steam Deck Pamac Setup v${SCRIPT_VERSION}${NC}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${BOLD}${YELLOW}DRY RUN MODE - No actual changes will be made${NC}"
    fi
    echo

  if [[ "$FORCE_REBUILD" == "true" ]] && distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
    log_step "Force rebuild requested - removing existing container"
    uninstall_setup
    force_remove_container "$CONTAINER_NAME"
    sleep 2
  fi

  if ! distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
    force_remove_container "$CONTAINER_NAME"
    create_container || exit 1
  else
    log_info "Container '$CONTAINER_NAME' exists, checking usability..."

    local existing_status
    existing_status=$(container_get_status)
    log_debug "Existing container status: $existing_status"

    case "$existing_status" in
      "running")
        if container_is_usable; then
          log_success "Using existing running container: $CONTAINER_NAME"
        else
          log_warn "Container is running but not usable, rebuilding..."
          force_remove_container "$CONTAINER_NAME"
          sleep 2
          create_container || exit 1
        fi
        ;;
      "stopping"|"paused"|"dead"|"exited"|"stopped")
        log_warn "Container in '$existing_status' state - removing and recreating"
        force_remove_container "$CONTAINER_NAME"
        sleep 2
        create_container || exit 1
        ;;
      "created")
        log_info "Container in 'created' state, starting..."
        container_start || {
          log_warn "Failed to start, recreating..."
          force_remove_container "$CONTAINER_NAME"
          sleep 2
          create_container || exit 1
        }
        wait_for_container || exit 1
        ;;
      *)
        log_warn "Container in unknown state '$existing_status' - removing and recreating"
        force_remove_container "$CONTAINER_NAME"
        sleep 2
        create_container || exit 1
        ;;
    esac
  fi

    configure_container_base || exit 1
    optimize_pacman_mirrors
    configure_multilib

    install_aur_helper || exit 1
    install_pamac || exit 1

    install_gaming_packages

    export_pamac_to_host

    setup_post_install_hooks
    export_existing_apps

    show_completion_message
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
