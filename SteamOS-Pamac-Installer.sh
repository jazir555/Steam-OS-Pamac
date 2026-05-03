#!/bin/bash

set -euo pipefail

# Heredoc quoting convention:
#   <<'EOF'  — no host variable expansion; content runs inside container
#   <<EOF    — host variables expand at write-time; use \$ for literal $

readonly SCRIPT_VERSION="5.2.0"
readonly DEFAULT_CONTAINER_NAME="arch-pamac"
readonly LOG_FILE="$HOME/distrobox-pamac-setup.log"
readonly REQUIRED_TOOLS=("distrobox")
CONTAINER_HAS_INIT="unknown"

CONTAINER_NAME="${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}"

CURRENT_USER=$(whoami)

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

    trap 'exit_code=$?; echo "=== Run finished: $(date) - Exit: $exit_code ===" >> "$LOG_FILE"' EXIT
}

_log() {
    local level="$1" color="$2" message="$3"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    local plain_message
    plain_message=$(echo "$message" | sed 's/\x1B\[[0-9;]*[A-Za-z]//g')

    echo "[$timestamp] $level: $plain_message" >> "$LOG_FILE"

    case "$LOG_LEVEL" in
        "quiet") if [[ "$level" == "ERROR" ]]; then echo -e "${color}${message}${NC}"; fi ;;
        "normal") if [[ "$level" != "DEBUG" ]]; then echo -e "${color}${message}${NC}"; fi ;;
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

container_runtime() {
    if [[ -n "${PODMAN_SUDO_FALLBACK:-}" ]]; then
        sudo podman "$@"
    else
        podman "$@"
    fi
}

container_root_exec() {
  container_start 2>/dev/null || true
  container_runtime exec -i -u 0 -e HOME="/root" "$CONTAINER_NAME" "$@"
}

container_user_exec() {
  container_start 2>/dev/null || true
  container_runtime exec -i -u "$CURRENT_USER" \
    -e HOME="/home/${CURRENT_USER}" \
    -e XDG_DATA_DIRS="/usr/local/share:/usr/share" \
    -e XDG_DATA_HOME="/home/${CURRENT_USER}/.local/share" \
    -e PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$CONTAINER_NAME" "$@"
}

container_cp_from() {
    local src="$1" dst="$2"
    log_debug "Copying from container: $src -> $dst"
    container_start 2>/dev/null || true
    if container_runtime cp "$CONTAINER_NAME:$src" "$dst" 2>/dev/null; then
        log_debug "Copied $src from container."
        return 0
    else
        log_debug "Failed to copy $src from container."
        return 1
    fi
}

container_start() {
  container_runtime start "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
}

container_is_running() {
  container_runtime inspect "$CONTAINER_NAME" --format '{{.State.Running}}' 2>/dev/null | grep -q "true"
}

container_get_status() {
  container_runtime inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "not_found"
}

container_is_usable() {
  container_root_exec bash -c "echo ok" 2>/dev/null | grep -q "ok"
}

container_get_status_safe() {
  container_get_status 2>/dev/null || echo "unknown"
}

ensure_container_healthy() {
	local desc="${1:-container operation}"
	local max_attempts=3
	local attempt=1

	while [[ $attempt -le $max_attempts ]]; do
		if container_is_usable; then
			return 0
		fi

		local status
		status=$(container_get_status_safe)
		log_warn "Container status: '$status' (attempt $attempt/$max_attempts for: $desc)"

		case "$status" in
			"running")
				log_info "Container running but not responding. Attempting exec retry..."
				sleep 2
				;;
			"stopped"|"exited")
				log_info "Container stopped. Starting..."
				container_start 2>/dev/null || true
				sleep 3
				if [[ "$CONTAINER_HAS_INIT" == "false" ]]; then
					if container_is_usable; then
						return 0
					fi
					log_debug "Non-init container not yet usable after start, waiting..."
					sleep 3
					if container_is_usable; then
						return 0
					fi
				fi
				local wait_rc=0
				wait_for_container || wait_rc=$?
				if [[ "$wait_rc" -eq 2 ]]; then
					log_info "Container was stuck and removed (wait_for_container rc=2). Signaling recreate."
					return 2
				elif [[ "$wait_rc" -ne 0 ]]; then
					log_error "Failed to start container."
					return 1
				fi
				;;
			"improper")
				log_warn "Container in improper state. Attempting forced recovery..."
				force_remove_container "$CONTAINER_NAME"
				log_info "Container removed due to improper state. Signaling recreate."
				return 2
				;;
			"not_found")
				log_error "Container '$CONTAINER_NAME' not found."
				return 2
				;;
			*)
				log_debug "Container in state '$status', waiting..."
				sleep 3
				;;
		esac

		attempt=$((attempt + 1))
	done

	log_error "Container health check failed after $max_attempts attempts for: $desc"
	return 1
}

_RECREATE_COUNT=0
_MAX_RECREATES=2

_ensure_healthy_or_recreate() {
    local desc="${1:-container operation}"
    local healthy_rc=0
    ensure_container_healthy "$desc" || healthy_rc=$?
    if [[ "$healthy_rc" -eq 0 ]]; then
        _RECREATE_COUNT=0
        return 0
    elif [[ "$healthy_rc" -eq 2 ]]; then
        _RECREATE_COUNT=$((_RECREATE_COUNT + 1))
        if [[ $_RECREATE_COUNT -gt $_MAX_RECREATES ]]; then
            log_error "Container recreated $_MAX_RECREATES times without success. Aborting."
            return 1
        fi
        log_info "Container signaled for recreation ($desc), attempt $_RECREATE_COUNT/$_MAX_RECREATES. Recreating..."
        force_remove_container "$CONTAINER_NAME"
        sleep 2
        if ! create_container; then
            log_error "Failed to recreate container after '$desc' recovery."
            return 1
        fi
        log_success "Container recreated successfully after '$desc' issue."
        return 0
    else
        return 1
    fi
}

force_remove_container() {
  local name="$1"
  local runtime_cmd="podman"
  [[ -n "${PODMAN_SUDO_FALLBACK:-}" ]] && runtime_cmd="sudo podman"

  if [[ "${DISTROBOX_CONTAINER_MANAGER:-podman}" == "docker" ]]; then
    docker rm -f "$name" 2>/dev/null || true
    return
  fi

  if ! $runtime_cmd inspect "$name" >/dev/null 2>&1; then
    return
  fi

  local status
  status=$($runtime_cmd inspect "$name" --format '{{.State.Status}}' 2>/dev/null || echo "not_found")
  if [[ "$status" == "not_found" ]]; then
    return
  fi

  if [[ "$status" == "stopping" || "$status" == "stopped" || "$status" == "improper" ]]; then
    log_debug "Container '$name' in '$status' state - killing container processes"
    local pid
    pid=$($runtime_cmd inspect "$name" --format '{{.State.Pid}}' 2>/dev/null || echo "0")
    if [[ "$pid" -gt 0 ]]; then
      kill -9 "$pid" 2>/dev/null || true
    fi
    local conmon_pid
    conmon_pid=$($runtime_cmd inspect "$name" --format '{{.ConmonPidFile}}' 2>/dev/null || true)
    if [[ -n "$conmon_pid" && -f "$conmon_pid" ]]; then
      local cpid
      cpid=$(cat "$conmon_pid" 2>/dev/null || echo "0")
      if [[ "$cpid" -gt 0 ]]; then
        kill -9 "$cpid" 2>/dev/null || true
      fi
    fi
    sleep 1
  fi

 $runtime_cmd rm -f "$name" 2>/dev/null || true
 if $runtime_cmd inspect "$name" >/dev/null 2>&1; then
 log_debug "User podman rm failed, trying sudo..."
 if sudo -n true 2>/dev/null; then
 sudo podman rm -f "$name" 2>/dev/null || true
 else
 log_warn "User podman rm failed and passwordless sudo not available. Skipping sudo fallback to avoid hang."
 fi
 fi

	if $runtime_cmd inspect "$name" >/dev/null 2>&1; then
		log_warn "Podman rm still failed for '$name'. Podman may be corrupted."
		log_warn "WARNING: Manual storage cleanup is a last resort. Deleting files from podman's"
		log_warn "overlayfs storage while the container engine is running can leave the podman"
		log_warn "database in an inconsistent state, causing 'ghost' containers or future failures"
		log_warn "that even 'podman system reset' may not fix. Proceed only if other options failed."
		if [[ -t 0 ]]; then
			echo -ne "${RED}${BOLD}Type 'yes' to proceed with manual storage cleanup, or anything else to skip: ${NC}" >&2
			local cleanup_confirm
			read -r cleanup_confirm
			if [[ "$cleanup_confirm" != "yes" ]]; then
				log_warn "User declined manual storage cleanup. Skipping."
				log_info "You can try 'podman system reset --force' or restart podman manually."
				return
			fi
		else
			log_warn "Non-interactive session — skipping manual storage cleanup to avoid podman corruption."
			log_info "Run this script interactively to approve cleanup, or try 'podman system reset --force'."
			return
		fi
		local podman_storage="${XDG_DATA_HOME:-$HOME/.local/share}/containers/storage"
		if [[ -d "$podman_storage" ]]; then
			log_warn "Removing container '$name' files from podman storage..."
			find "$podman_storage" -maxdepth 3 -path "*/$name*" -exec rm -rf {} \; 2>/dev/null || true
		fi
		local podman_run="/run/user/$(id -u)/containers"
		if [[ -d "$podman_run" ]]; then
			find "$podman_run" -maxdepth 2 -path "*/$name*" -exec rm -rf {} \; 2>/dev/null || true
		fi
		$runtime_cmd rm -f "$name" 2>/dev/null || true
		if sudo -n true 2>/dev/null; then
			sudo podman rm -f "$name" 2>/dev/null || true
		fi
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

check_memory_ok() {
    local min_avail_kb="${1:-524288}"
    local desc="${2:-operation}"

    if [[ ! -f /proc/meminfo ]]; then
        log_debug "Cannot check /proc/meminfo, skipping memory check."
        return 0
    fi

    local mem_avail_kb
    mem_avail_kb=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")

    if [[ "$mem_avail_kb" == "0" ]]; then
        log_debug "MemAvailable not found, skipping memory check."
        return 0
    fi

    if [[ "$mem_avail_kb" -lt "$min_avail_kb" ]]; then
        local mem_avail_mb=$(( mem_avail_kb / 1024 ))
        local min_avail_mb=$(( min_avail_kb / 1024 ))
        log_warn "Low available memory: ${mem_avail_mb}MB (need at least ${min_avail_mb}MB for $desc)."
        log_warn "The operation may be killed by OOM. Consider closing other applications."
        if [[ "$mem_avail_kb" -lt $(( min_avail_kb / 2 )) ]]; then
            log_error "Insufficient memory for $desc. Skipping this operation."
            return 1
        fi
    else
        log_debug "Memory check OK: $(( mem_avail_kb / 1024 ))MB available for $desc."
    fi

    return 0
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

repair_podman() {
    log_step "Attempting podman repair..."
    local repaired=false

    log_info "Checking rootless podman socket..."
    local socket_path="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
    if [[ -S "$socket_path" ]]; then
        log_debug "Podman socket exists at $socket_path"
    else
        log_warn "Podman socket not found. Trying to start podman socket..."
        if systemctl --user start podman.socket 2>/dev/null; then
            log_info "Started podman user socket."
            sleep 2
            repaired=true
        fi
    fi

    if podman info >/dev/null 2>&1; then
        log_success "Podman is now functional."
        return 0
    fi

    log_info "Checking for podman database lock files..."
    local podman_root="${XDG_DATA_HOME:-$HOME/.local/share}/containers/storage"
    if [[ -d "$podman_root" ]]; then
        find "$podman_root" -name "*.lock" -type f -delete 2>/dev/null || true
        log_debug "Cleaned stale lock files."
    fi

    if podman info >/dev/null 2>&1; then
        log_success "Podman recovered after lock cleanup."
        return 0
    fi

    log_warn "Podman database may be corrupted. A full system reset is required but is DESTRUCTIVE."
    log_warn "WARNING: 'podman system reset --force' will remove ALL containers, images, and volumes — not just the Pamac container. Any other distroboxes or podman workloads will be lost."
    local skip_reset=false
    if [[ -t 0 ]]; then
        echo -ne "${RED}${BOLD}Type 'yes' to proceed with podman system reset, or anything else to skip: ${NC}" >&2
        local reset_confirm
        read -r reset_confirm
        if [[ "$reset_confirm" != "yes" ]]; then
            log_warn "User declined podman system reset. Skipping to next recovery step."
            log_info "You can run 'podman system reset --force' manually if needed."
            skip_reset=true
        fi
    else
        log_warn "Non-interactive session — skipping automatic podman system reset to avoid data loss."
        log_info "Run 'podman system reset --force' manually if you want to reset all podman data."
        skip_reset=true
    fi
    if [[ "$skip_reset" != "true" ]]; then
        local reset_output
        reset_output=$(podman system reset --force 2>&1) && rc=0 || rc=$?
        log_debug "podman system reset: $reset_output"
    fi

    if [[ "$skip_reset" != "true" ]] && podman info >/dev/null 2>&1; then
        log_success "Podman recovered after system reset."
        return 0
    fi

    log_info "Attempting to migrate podman storage..."
    podman system migrate 2>/dev/null || true

    if podman info >/dev/null 2>&1; then
        log_success "Podman recovered after storage migration."
        return 0
    fi

    log_info "Trying podman with sudo fallback..."
    if sudo podman info >/dev/null 2>&1; then
        log_warn "Rootless podman broken, root podman works. Using sudo for container operations."
        export PODMAN_SUDO_FALLBACK=true
        if container_runtime info >/dev/null 2>&1; then
            log_success "Using root podman fallback."
            return 0
        fi
    fi

    log_error "Podman repair failed. All recovery attempts exhausted."
    return 1
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

    if command -v podman >/dev/null 2>&1; then
        log_warn "Podman installed but not functional."
        if ! repair_podman; then
            if command -v docker >/dev/null 2>&1; then
                log_warn "Podman repair failed. Falling back to docker."
                export DISTROBOX_CONTAINER_MANAGER=docker
                return 0
            fi
            log_error "No working container runtime available. Install podman or docker."
            return 1
        fi
        export DISTROBOX_CONTAINER_MANAGER=podman
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
        elif container_is_usable 2>/dev/null; then
            container_accessible=true
            log_debug "Container accessible via container exec fallback."
        fi

        if [[ "$container_accessible" == "true" ]]; then
            log_info "Removing exported applications..."
            while IFS= read -r app_file; do
                [[ -z "$app_file" || ! -f "$app_file" ]] && continue
                local app_name
                app_name=$(grep '^X-SteamOS-Pamac-SourceApp=' "$app_file" 2>/dev/null | cut -d= -f2- || true)
                if [[ -n "$app_name" ]]; then
                    log_info "Un-exporting app: $app_name"
                    if [[ "$DRY_RUN" != "true" ]]; then
			distrobox-enter "$CONTAINER_NAME" -- env XDG_DATA_DIRS="/usr/local/share:/usr/share" XDG_DATA_HOME="/home/${CURRENT_USER}/.local/share" distrobox-export --container "$CONTAINER_NAME" --app "$app_name" --delete 2>/dev/null || true
                    fi
                fi
            done < <(find "$HOME/.local/share/applications" -maxdepth 1 -type f -name "*.desktop" -exec grep -l "^X-SteamOS-Pamac-Container=${CONTAINER_NAME}$" {} + 2>/dev/null || true)
        else
            log_warn "Container not accessible for export unlisting. Will clean desktop files directly."
        fi

        run_command distrobox stop --yes "$CONTAINER_NAME" || true
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
                if grep -Eq "X-SteamOS-Pamac-Container=${CONTAINER_NAME}|distrobox( enter|[-]enter).*(^| )${CONTAINER_NAME}( |$)" "$df" >/dev/null 2>&1; then
                    rm -f "$df" 2>/dev/null || true
                    cleaned=$((cleaned + 1))
                fi
            done < <(find "$app_dir" -maxdepth 1 -type f -name "*.desktop" -print0 2>/dev/null)
            find "$app_dir" -maxdepth 1 -type f \( -name "${CONTAINER_NAME}-*.desktop" -o -name "*-${CONTAINER_NAME}.desktop" \) -delete 2>/dev/null || true
            rm -f "$app_dir/${CONTAINER_NAME}.desktop" 2>/dev/null || true
            command -v update-desktop-database >/dev/null 2>&1 && \
                update-desktop-database "$app_dir" 2>/dev/null || true
        else
            log_warn "[DRY RUN] Would search for and delete .desktop files in $app_dir"
        fi
    fi

    local state_dir="$HOME/.local/share/steamos-pamac/$CONTAINER_NAME"
    [[ -d "$state_dir" ]] && { log_info "Removing export state at $state_dir"; [[ "$DRY_RUN" != "true" ]] && rm -rf "$state_dir"; }

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
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "[DRY RUN] Would wait for container '$CONTAINER_NAME'"
    return 0
  fi
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
      "stopping"|"paused"|"stopped"|"improper")
        if [[ $attempt -le 5 ]]; then
          log_debug "Container in '$status' state, waiting..."
        else
          log_warn "Container stuck in '$status' state - removing and recreating"
          set -e
          force_remove_container "$CONTAINER_NAME"
          return 2
        fi
        ;;
  "exited")
    if [[ "$CONTAINER_HAS_INIT" == "false" ]]; then
      log_debug "Container exited (normal in non-init mode). Restarting..."
      container_start
      sleep 3
      if container_is_usable; then
        set -e
        log_success "Container restarted and ready (non-init mode)."
        return 0
      fi
      if [[ $attempt -gt 5 ]]; then
        log_warn "Non-init container not responding after restart. Removing and recreating."
        set -e
        force_remove_container "$CONTAINER_NAME"
        return 2
      fi
    elif [[ $attempt -le 2 ]]; then
      log_debug "Container exited. Attempting restart (attempt $attempt)..."
      container_start
    elif [[ $attempt -le 5 ]]; then
      local exit_code
      exit_code=$(container_runtime inspect "$CONTAINER_NAME" --format '{{.State.ExitCode}}' 2>/dev/null || echo "unknown")
      log_warn "Container keeps exiting (exit code: $exit_code). Inspecting..."
      case "$exit_code" in
        137) log_error "Container was OOM-killed (exit 137). Not enough memory available." ;;
        139) log_error "Container segfaulted (exit 139). Possible kernel or image incompatibility." ;;
        1) log_warn "Container exited with code 1 (general error)." ;;
      esac
      log_debug "Waiting longer before next restart attempt..."
    else
      log_warn "Container stuck in 'exited' state - removing and recreating"
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
        CONTAINER_HAS_INIT="false"
        log_info "SteamOS detected - using non-init mode (nested systemd is unreliable on Steam Deck)."
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
    local mgr="${DISTROBOX_CONTAINER_MANAGER:-podman}"
    if [[ "$mgr" == "docker" ]]; then
        init_binary=$(docker info --format '{{.Host.InitPath}}' 2>/dev/null || echo "")
    else
        init_binary=$(container_runtime info --format '{{.Host.InitPath}}' 2>/dev/null || echo "")
    fi
    if [[ -n "$init_binary" ]]; then
        local resolved
        resolved=$(command -v "$init_binary" 2>/dev/null || echo "")
        if [[ -n "$resolved" ]] || [[ -f "$init_binary" ]]; then
            CONTAINER_HAS_INIT="true"
            log_info "Init system supported ($mgr init binary: $init_binary)."
        else
            CONTAINER_HAS_INIT="false"
            log_info "Init binary '$init_binary' not found - using non-init container."
        fi
    else
        CONTAINER_HAS_INIT="false"
        log_info "No $mgr init support detected - using non-init container."
    fi
}

create_container() {
    log_step "Creating Arch Linux container: $CONTAINER_NAME"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY RUN] Would create container '$CONTAINER_NAME'"
        return 0
    fi

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
    container_start 2>/dev/null || true

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

repair_pacman_db() {
    log_info "Checking and repairing pacman database (if needed)..."
    container_root_exec bash -c '
set +e
rm -f /var/lib/pacman/db.lck

if ! pacman -Dk 2>/dev/null; then
    echo "Pacman DB inconsistencies detected. Attempting repair..."
    for db_dir in /var/lib/pacman/local/*/; do
        pkg_name=$(basename "$db_dir")
        if [[ ! -f "$db_dir/desc" ]]; then
            echo "Removing broken DB entry: $pkg_name (missing desc)"
            rm -rf "$db_dir"
        fi
        if [[ ! -f "$db_dir/files" ]]; then
            echo "Reinstalling package with missing files DB: $pkg_name"
            pkg_base=$(grep -m1 "^%NAME%$" "$db_dir/desc" 2>/dev/null | tail -1)
            [[ -z "$pkg_base" ]] && pkg_base=$(echo "$pkg_name" | sed "s/-[0-9].*//")
            pacman -S --noconfirm --needed "$pkg_base" 2>/dev/null || true
        fi
    done
    pacman -Dk 2>/dev/null || echo "Warning: pacman DB still has minor inconsistencies (non-fatal)."
else
    echo "Pacman DB is consistent."
fi
' 2>/dev/null || true
}

exec_container_script() {
    local _script="$1"
    local _desc="$2"
    shift 2
    local _rc=0
    local _script_file
    local _preamble='_safe_sleep() { if ! sleep "$1" 2>/dev/null; then read -t "$1" -r _ 2>/dev/null || true; fi; }
'

    _script_file=$(mktemp /tmp/pamac-script-XXXXXXXX)
    printf '%s\n' "${_preamble}${_script}" > "$_script_file"

    local _marker="PAMAC_SCRIPT_OK_$(head -c 16 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null || echo "$$_$(date +%s%N)")"
  printf '\necho "%s"\n' "$_marker" >> "$_script_file"

  set +e
  local _output=""
  if [[ "$LOG_LEVEL" == "verbose" ]]; then
    _output=$(container_root_exec bash -s "$@" < "$_script_file" 2>&1 | tee -a "$LOG_FILE")
    _rc=${PIPESTATUS[0]}
  else
    _output=$(container_root_exec bash -s "$@" < "$_script_file" 2>&1)
    _rc=$?
    echo "$_output" >> "$LOG_FILE"
  fi
  set -e

  rm -f "$_script_file"

 if [[ "$CONTAINER_HAS_INIT" == "false" ]] && [[ $_rc -ne 0 ]]; then
 if echo "$_output" | grep -q "$_marker"; then
 log_debug "Script '$_desc' completed successfully (exit $_rc is expected in non-init container - podman may kill entry process after completion)."
 container_start 2>/dev/null || true
 repair_pacman_db
 return 0
 fi
 if [[ $_rc -eq 137 ]]; then
 log_warn "Script '$_desc' got exit 137 without completion marker. May be OOM or signal kill. Attempting DB repair..."
 else
 log_warn "Script '$_desc' got exit $_rc without completion marker in non-init container. May be premature container stop. Attempting DB repair..."
 fi
 container_start 2>/dev/null || true
 repair_pacman_db
 fi

 if [[ $_rc -ne 0 ]] && ! { [[ "$CONTAINER_HAS_INIT" == "false" ]] && echo "$_output" | grep -q "$_marker"; }; then
        log_warn "Script '$_desc' failed (exit=$_rc)."
        container_root_exec bash -c "rm -f /var/lib/pacman/db.lck; pkill -9 gpg-agent 2>/dev/null || true" 2>/dev/null || true
        ensure_container_healthy "$_desc" || return 1
        repair_pacman_db
        return $_rc
    fi
    return 0
}

exec_container_pipe() {
    local _desc="$1"
    shift
    local _rc=0
    local _script_file
    local _marker="PAMAC_PIPE_OK_$(head -c 16 /dev/urandom 2>/dev/null | xxd -p 2>/dev/null || echo "$$_$(date +%s%N)")"
    local _preamble='_safe_sleep() { if ! sleep "$1" 2>/dev/null; then read -t "$1" -r _ 2>/dev/null || true; fi; }
'

    _script_file=$(mktemp /tmp/pamac-pipe-XXXXXXXX)
    printf '%s' "$_preamble" > "$_script_file"
    cat >> "$_script_file"
    printf '\necho "%s"\n' "$_marker" >> "$_script_file"

    set +e
    local _output=""
    if [[ "$LOG_LEVEL" == "verbose" ]]; then
        _output=$(container_root_exec bash -s "$@" < "$_script_file" 2>&1 | tee -a "$LOG_FILE")
        _rc=${PIPESTATUS[0]}
    else
        _output=$(container_root_exec bash -s "$@" < "$_script_file" 2>&1)
        _rc=$?
        echo "$_output" >> "$LOG_FILE"
    fi
    set -e

    rm -f "$_script_file"

 if [[ "$CONTAINER_HAS_INIT" == "false" ]] && [[ $_rc -ne 0 ]]; then
 if echo "$_output" | grep -q "$_marker"; then
 log_debug "Piped script '$_desc' completed successfully (exit $_rc is expected in non-init container - podman may kill entry process after completion)."
 container_start 2>/dev/null || true
 repair_pacman_db
 return 0
 fi
 if [[ $_rc -eq 137 ]]; then
 log_warn "Piped script '$_desc' got exit 137 without completion marker. May be OOM or signal kill. Attempting DB repair..."
 else
 log_warn "Piped script '$_desc' got exit $_rc without completion marker in non-init container. May be premature container stop. Attempting DB repair..."
 fi
 container_start 2>/dev/null || true
 repair_pacman_db
 fi

 if [[ $_rc -ne 0 ]] && ! { [[ "$CONTAINER_HAS_INIT" == "false" ]] && echo "$_output" | grep -q "$_marker"; }; then
        log_warn "Piped script '$_desc' failed (exit=$_rc)."
        container_root_exec bash -c "rm -f /var/lib/pacman/db.lck; pkill -9 gpg-agent 2>/dev/null || true" 2>/dev/null || true
        ensure_container_healthy "$_desc" || return 1
        repair_pacman_db
        return $_rc
    fi
    return 0
}

configure_container_base() {
    log_step "Configuring container base environment"

    local _ok=true

    log_info "Stage 1/6: Initializing pacman keyring..."
    local keyring_script
read -r -d '' keyring_script <<'KEYRING_EOF' || true
set -uo pipefail

rm -f /var/lib/pacman/db.lck

echo "Step 1/4: Cleaning up stale gpg-agent state..."
pkill -9 gpg-agent 2>/dev/null || true
pkill -9 dirmngr 2>/dev/null || true
_safe_sleep 1
rm -f /etc/pacman.d/gnupg/S.gpg-agent 2>/dev/null || true
rm -f /etc/pacman.d/gnupg/S.gpg-agent.extra 2>/dev/null || true
rm -f /etc/pacman.d/gnupg/S.gpg-agent.browser 2>/dev/null || true
rm -f /etc/pacman.d/gnupg/S.gpg-agent.ssh 2>/dev/null || true
rm -f /etc/pacman.d/gnupg/S.dirmngr 2>/dev/null || true

if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
echo "Disabling systemd gpg-agent socket activation that interferes with keyring init..."
 systemctl stop gpg-agent@*.socket 2>/dev/null || true
 systemctl stop gpg-agent@*.service 2>/dev/null || true
 systemctl stop dirmngr@*.socket 2>/dev/null || true
fi

export GNUPGHOME=/etc/pacman.d/gnupg
export GPG_AGENT_INFO=
chmod 700 /etc/pacman.d/gnupg 2>/dev/null || true

echo "Step 2/4: Initializing pacman keyring with existing keyring..."
keyring_init_ok=false
if pacman-key --init 2>/dev/null; then
echo "Keyring init succeeded."
keyring_init_ok=true
else
echo "Warning: pacman-key --init failed (likely gpg-agent/systemd conflict)."
echo "Attempting with forced gpg-agent cleanup..."
pkill -9 gpg-agent 2>/dev/null || true
pkill -9 dirmngr 2>/dev/null || true
_safe_sleep 3
rm -f /etc/pacman.d/gnupg/S.gpg-agent /etc/pacman.d/gnupg/S.gpg-agent.extra 2>/dev/null || true
rm -f /etc/pacman.d/gnupg/S.gpg-agent.browser /etc/pacman.d/gnupg/S.gpg-agent.ssh 2>/dev/null || true
rm -f /etc/pacman.d/gnupg/S.dirmngr 2>/dev/null || true
if pacman-key --init 2>/dev/null; then
echo "Keyring init succeeded on retry."
keyring_init_ok=true
else
echo "Warning: pacman-key --init still failed."
fi
fi

if [[ "$keyring_init_ok" == "true" ]]; then
    echo "Step 3/4: Populating keyring with existing archlinux keys..."
    echo "Ensuring correct permissions on GPG directory..."
    chmod 700 /etc/pacman.d/gnupg 2>/dev/null || true
    find /etc/pacman.d/gnupg -type f -exec chmod 600 {} \; 2>/dev/null || true
    find /etc/pacman.d/gnupg -type d -exec chmod 700 {} \; 2>/dev/null || true
    if pacman-key --populate archlinux 2>/dev/null; then
        echo "Keyring populated successfully."
    else
echo "Warning: pacman-key --populate failed."
echo "Falling back to SigLevel=Never."
echo "SECURITY WARNING: PGP signature verification is now DISABLED. Packages will be installed without cryptographic verification, which makes them vulnerable to tampering or man-in-the-middle attacks. This is a last resort for environments with broken GPG/entropy."
        if command -v sed >/dev/null 2>&1; then
            sed -i 's/^SigLevel.*/SigLevel = Never/' /etc/pacman.conf
            if ! grep -q '^SigLevel' /etc/pacman.conf; then
                echo 'SigLevel = Never' >> /etc/pacman.conf
            fi
        else
            echo 'SigLevel = Never' >> /etc/pacman.conf
        fi
    fi
else
    echo "Falling back to SigLevel=Never to allow package installation without PGP verification."
echo "SECURITY WARNING: PGP signature verification is now DISABLED. Packages will be installed without cryptographic verification, which makes them vulnerable to tampering or man-in-the-middle attacks. This is a last resort for environments with broken GPG/entropy."
    if command -v sed >/dev/null 2>&1; then
        sed -i 's/^SigLevel.*/SigLevel = Never/' /etc/pacman.conf
        if ! grep -q '^SigLevel' /etc/pacman.conf; then
            echo 'SigLevel = Never' >> /etc/pacman.conf
        fi
    else
        echo 'SigLevel = Never' >> /etc/pacman.conf
    fi
fi

echo "Step 4/4: Updating archlinux-keyring package..."
rm -f /var/lib/pacman/db.lck
if pacman -Syy --noconfirm 2>/dev/null; then
    pacman -S --noconfirm --needed archlinux-keyring 2>/dev/null || {
        echo "Warning: archlinux-keyring update failed, retrying..."
        pacman -S --noconfirm --needed archlinux-keyring 2>/dev/null || echo "Warning: keyring update failed"
    }
    if pacman-key --verify /usr/share/keyrings/archlinux-packer.gpg 2>/dev/null || pacman-key --list-sigs 2>/dev/null | grep -q "archlinux"; then
        if grep -q '^SigLevel.*Never' /etc/pacman.conf 2>/dev/null; then
            echo "Restoring SigLevel to Required DatabaseOptional after successful keyring update."
            sed -i 's/^SigLevel.*/SigLevel = Required DatabaseOptional/' /etc/pacman.conf
        fi
    fi
else
    echo "Warning: database sync failed, skipping keyring update."
fi

echo "Configuring pacman for low-memory environment..."
if grep -q '^ParallelDownloads' /etc/pacman.conf 2>/dev/null; then
    sed -i 's/^ParallelDownloads.*/ParallelDownloads = 1/' /etc/pacman.conf
else
    echo 'ParallelDownloads = 1' >> /etc/pacman.conf
fi

echo "Keyring initialization complete."
KEYRING_EOF

    if ! exec_container_script "$keyring_script" "keyring-init"; then
        log_warn "Keyring initialization had issues. Continuing..."
        _ok=false
    fi

    if ! container_is_usable; then
        log_error "Container not usable after keyring init."
        return 1
    fi

    log_info "Stage 2/6: Performing system upgrade..."
    local upgrade_script
    read -r -d '' upgrade_script <<'UPG_EOF' || true
set -uo pipefail

rm -f /var/lib/pacman/db.lck

echo "Syncing package databases..."
pacman -Syy --noconfirm 2>/dev/null || echo "Note: database sync had issues but continuing"

verify_core_tools() {
    if ! command -v pacman >/dev/null 2>&1; then
        echo "FATAL: pacman is missing. Cannot recover."
        return 1
    fi
    if ! command -v grep >/dev/null 2>&1; then
        echo "FATAL: grep is missing."
        return 1
    fi
    return 0
}

verify_core_tools || { echo "Core tools missing before upgrade. Cannot proceed."; exit 2; }

echo "Checking for disk space before upgrade..."
df_home_kb=$(df -k / 2>/dev/null | awk 'NR==2{print $4}' || echo "0")
if [[ "$df_home_kb" -lt 512000 ]] && [[ "$df_home_kb" -gt 0 ]]; then
    echo "Warning: Low disk space (${df_home_kb}KB). Upgrade may fail."
fi

echo "Checking available system memory..."
if grep -q MemAvailable /proc/meminfo 2>/dev/null; then
    mem_avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    if [[ "$mem_avail_kb" -lt 524288 ]]; then
        echo "Warning: Low available memory (${mem_avail_kb}KB). Upgrade may be killed by OOM."
    fi
fi

echo "Upgrading system packages (3-pass: keyring+SSL first, then non-critical, then critical)..."
rm -f /var/lib/pacman/db.lck

CRITICAL_PKGS="openssl glibc lib32-glibc systemd-libs pam"
upgrade_ok=true

echo "Pass 1: Upgrading keyring and certificate packages first..."
sync 2>/dev/null || true
_safe_sleep 1
if ! pacman -S --noconfirm --needed archlinux-keyring ca-certificates-mozilla 2>/dev/null; then
    echo "Note: keyring/cert upgrade had issues but continuing..."
fi

verify_core_tools || {
    echo "FATAL: Core tools broken after keyring upgrade. Cannot recover."
    exit 2
}

echo "Pass 2: Upgrading remaining non-critical packages..."
SKIP_PKGS="systemd systemd-sysvcompat"
exclude_args=""
for pkg in $CRITICAL_PKGS archlinux-keyring ca-certificates-mozilla $SKIP_PKGS; do
    exclude_args="$exclude_args --ignore $pkg"
done
if ! pacman -Su --noconfirm --needed $exclude_args 2>/dev/null; then
    echo "Non-critical upgrade had issues, trying with conflict resolution..."
    pacman -Su --noconfirm --needed $exclude_args 2>/dev/null || echo "Warning: non-critical upgrade failed"
fi

verify_core_tools || {
    echo "FATAL: Core tools broken after non-critical upgrade. Cannot recover."
    exit 2
}

echo "Pass 3: Upgrading critical packages (openssl, glibc, systemd)..."
for pkg in $CRITICAL_PKGS; do
    if pacman -Q "$pkg" >/dev/null 2>&1; then
        rm -f /var/lib/pacman/db.lck
        echo "Upgrading $pkg..."
        if pacman -S --noconfirm --needed "$pkg" 2>/dev/null; then
            echo "$pkg upgraded."
        else
            echo "Warning: $pkg upgrade failed. Attempting recovery..."
            if ! command -v pacman >/dev/null 2>&1; then
                echo "FATAL: pacman broken after partial $pkg upgrade. This indicates shared library corruption."
                echo "Attempting to recover by re-installing $pkg from cache..."
 if ls /var/cache/pacman/pkg/${pkg}-*.pkg.tar.* >/dev/null 2>&1; then
 latest_pkg=$(ls -t /var/cache/pacman/pkg/${pkg}-*.pkg.tar.* 2>/dev/null | head -1)
 if [[ -n "$latest_pkg" ]]; then
 pacman -U --noconfirm "$latest_pkg" 2>/dev/null || {
 echo "FATAL: Recovery failed. The container must be recreated."
 exit 2
 }
 else
 echo "FATAL: No cached package for $pkg. The container must be recreated."
 exit 2
 fi
                else
                    echo "FATAL: No cached package for $pkg. The container must be recreated."
                    exit 2
                fi
            fi
        fi
    fi
done

verify_core_tools || {
    echo "FATAL: Core tools broken after critical upgrade. The container must be recreated."
    exit 2
}

echo "Running ldconfig to update shared library cache..."
if command -v ldconfig >/dev/null 2>&1; then
    ldconfig 2>/dev/null || echo "Note: ldconfig had issues"
else
    echo "Note: ldconfig not found, skipping"
fi

echo "System upgrade completed."
UPG_EOF

    if ! exec_container_script "$upgrade_script" "pacman-upgrade"; then
        log_warn "System upgrade had issues, continuing anyway..."
        if ! container_is_usable; then
            log_error "Container is not usable after upgrade attempt."
            log_error "This usually indicates a partial glibc upgrade corrupted the container."
            log_error "Try running: podman rm -f $CONTAINER_NAME && distrobox rm -f $CONTAINER_NAME"
            log_error "Then re-run this script with --force-rebuild"
            return 1
        fi
    fi

    log_info "Stage 3/6: Installing core system packages..."
    local core_script
    read -r -d '' core_script <<'CORE_EOF' || true
set -uo pipefail

rm -f /var/lib/pacman/db.lck

safe_install() {
    local attempt=0
    local max_attempts=3
    local rc=0
    while [[ $attempt -lt $max_attempts ]]; do
        rm -f /var/lib/pacman/db.lck
        if pacman -S --noconfirm --needed "$@"; then
            ldconfig 2>/dev/null || true
            return 0
        fi
        rc=$?
        attempt=$((attempt + 1))
        if [[ $attempt -lt $max_attempts ]]; then
            echo "Core package install failed (attempt $attempt/$max_attempts, exit=$rc), repairing DB..."
if [[ $rc -eq 137 ]]; then
echo "Exit code 137 indicates OOM kill. Syncing and retrying..."
sync 2>/dev/null || true
_safe_sleep 3
fi
pacman -Dk 2>/dev/null || true
pacman -Syy --noconfirm 2>/dev/null || true
_safe_sleep 2
fi
    done
    return $rc
}

echo "Installing core packages (sudo, shadow, gnupg)..."
if ! safe_install sudo shadow gnupg; then
    echo "ERROR: Failed to install core packages after retries."
    exit 1
fi
echo "Core packages installed."
CORE_EOF

    if ! exec_container_script "$core_script" "core-packages"; then
        log_warn "Failed to install core packages. Continuing to ensure later stages run..."
        _ok=false
        if ! container_is_usable; then
            log_warn "Container not usable, attempting restart..."
            container_start 2>/dev/null || true
            wait_for_container || {
                log_error "Container unrecoverable after core package failure."
                return 1
            }
        fi
    fi

    log_info "Stage 4/6: Installing development packages (batched to avoid OOM)..."
    local dev_script
    read -r -d '' dev_script <<'DEV_EOF' || true
set -uo pipefail

rm -f /var/lib/pacman/db.lck

check_mem() {
    local min_kb="${1:-262144}"
    local desc="${2:-install}"
    if [[ ! -f /proc/meminfo ]]; then
        return 0
    fi
    local avail_kb
    avail_kb=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    if [[ "$avail_kb" != "0" && "$avail_kb" -lt "$min_kb" ]]; then
        echo "Warning: Low memory (${avail_kb}KB available) for $desc."
    fi
}

safe_install() {
    local attempt=0
    local max_attempts=3
    local rc=0
    while [[ $attempt -lt $max_attempts ]]; do
        rm -f /var/lib/pacman/db.lck
        if pacman -S --noconfirm --needed "$@"; then
            ldconfig 2>/dev/null || true
            return 0
        fi
        rc=$?
        attempt=$((attempt + 1))
        if [[ $attempt -lt $max_attempts ]]; then
            echo "Install failed (attempt $attempt/$max_attempts, exit=$rc), repairing DB..."
if [[ $rc -eq 137 ]]; then
echo "Exit code 137 indicates OOM kill. Trying with swap flush..."
sync 2>/dev/null || true
_safe_sleep 3
fi
pacman -Dk 2>/dev/null || true
pacman -Syy --noconfirm 2>/dev/null || true
_safe_sleep 3
fi
    done
    return $rc
}

echo "Installing git..."
check_mem 262144 "git install"
if ! safe_install git; then
    echo "Failed to install git."
    exit 1
fi

echo "Installing base-devel in smaller batches to avoid OOM..."
check_mem 524288 "base-devel install"
sync 2>/dev/null || true
_safe_sleep 1
BASE_DEVEL_BATCHES=(
    "m4 autoconf automake binutils"
    "bison debugedit diffutils fakeroot"
    "flex"
    "gcc"
    "gettext groff"
    "gzip libtool make patch"
    "pkgconf sed texinfo which"
)
for batch in "${BASE_DEVEL_BATCHES[@]}"; do
echo "Installing batch: $batch"
check_mem 262144 "base-devel batch"
sync 2>/dev/null || true
_safe_sleep 1
if ! safe_install $batch; then
        echo "Warning: batch install failed for: $batch"
    fi
done
if ! pacman -Q base-devel >/dev/null 2>&1 && ! safe_install base-devel; then
    echo "Warning: base-devel group meta-package could not be installed."
fi

echo "Installing go..."
check_mem 262144 "go install"
sync 2>/dev/null || true
_safe_sleep 1
if ! safe_install go; then
    echo "Failed to install go."
    exit 1
fi

echo "Development packages installed."
DEV_EOF

    if ! exec_container_script "$dev_script" "dev-packages"; then
        log_warn "Development package install failed. Continuing..."

        if ! container_is_usable; then
            log_warn "Container not usable, attempting restart..."
            container_start 2>/dev/null || true
            wait_for_container || {
                log_error "Container unrecoverable."
                return 1
            }
        fi
    fi

    log_info "Stage 5/6: Creating user and configuring sudo..."
    local user_script
    read -r -d '' user_script <<'USER_EOF' || true
set -uo pipefail

current_user="$1"
if [[ -z "$current_user" ]]; then
    echo "ERROR: Host username not supplied." >&2
    exit 1
fi

echo "Container: configuring user '${current_user}'"

if ! id "$current_user" >/dev/null 2>&1; then
    echo "User '$current_user' not found. Creating user."
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
USER_EOF

    exec_container_script "$user_script" "user-setup" "$CURRENT_USER" || return 1

log_info "Stage 6a/7: Installing polkit and setting up D-Bus..."
local polkit_dbus_script
read -r -d '' polkit_dbus_script <<'POLKIT_DBUS_EOF' || true
set -uo pipefail

echo "Installing polkit..."
if pacman -S --noconfirm --needed polkit; then
polkit_dir="/etc/polkit-1/rules.d"
mkdir -p "$polkit_dir"
printf '%s\n' 'polkit.addRule(function(action, subject) {' \
' if (action.id.indexOf("org.manjaro.pamac.") == 0 &&' \
' subject.isInGroup("wheel")) {' \
' return polkit.Result.YES;' \
' }' \
'});' > "$polkit_dir/10-pamac-nopasswd.rules"
echo "polkit passwordless rule created for pamac operations."
if ! id polkitd >/dev/null 2>&1; then
useradd -r -d / -s /usr/bin/nologin polkitd 2>/dev/null || echo "Note: polkitd user creation failed"
fi
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

echo "Patching polkit policy for non-interactive authorization..."
pamac_policy="/usr/share/polkit-1/actions/org.manjaro.pamac.policy"
if [[ -f "$pamac_policy" ]]; then
sed -i 's|<allow_any>auth_admin_keep</allow_any>|<allow_any>yes</allow_any>|' "$pamac_policy"
sed -i 's|<allow_inactive>auth_admin_keep</allow_inactive>|<allow_inactive>yes</allow_inactive>|' "$pamac_policy"
sed -i 's|<allow_active>auth_admin_keep</allow_active>|<allow_active>yes</allow_active>|' "$pamac_policy"
echo "Polkit policy patched: allow_any=yes, allow_inactive=yes, allow_active=yes"
else
echo "Note: pamac polkit policy not yet installed (will be patched after pamac-aur install)."
fi

echo "Polkit and D-Bus setup finished."
POLKIT_DBUS_EOF

if ! exec_container_script "$polkit_dbus_script" "polkit-dbus-setup"; then
log_warn "Polkit/dbus setup had issues, retrying..."
container_start 2>/dev/null || true
sleep 3
if container_is_usable; then
if ! exec_container_script "$polkit_dbus_script" "polkit-dbus-setup-retry"; then
log_warn "Polkit/dbus setup retry also failed. Will attempt repair later."
_ok=false
fi
else
log_warn "Container not usable for polkit/dbus retry. Will attempt repair later."
_ok=false
fi
fi

log_info "Stage 6b/7: Installing critical helpers (bootstrap, systemd-run, D-Bus config)..."
local critical_script
read -r -d '' critical_script <<'CRITICAL_EOF' || true
set -uo pipefail

HOST_USER="$1"

echo "Installing Pamac bootstrap helper..."
cat > /usr/local/bin/pamac-session-bootstrap.sh << 'BOOTSTRAP'
#!/bin/bash
set +e
BOOTSTRAP_LOG="/tmp/pamac-bootstrap.log"
touch "$BOOTSTRAP_LOG" 2>/dev/null && chmod 666 "$BOOTSTRAP_LOG" 2>/dev/null

_safe_sleep() {
if ! sleep "$1" 2>/dev/null; then
read -t "$1" -r _ 2>/dev/null || true
fi
}

log_bootstrap() {
echo "[$(date '+%H:%M:%S')] $*" >> "$BOOTSTRAP_LOG" 2>/dev/null || true
}

ensure_service() {
local name="$1"
local pid_ok="$2"
local start_cmd="$3"
local retries=5
local count=0

if command -v pgrep >/dev/null 2>&1 && pgrep -x "$pid_ok" >/dev/null 2>&1; then
log_bootstrap "$name already running (pid $(pgrep -x "$pid_ok" 2>/dev/null | head -1))"
return 0
fi

log_bootstrap "Starting $name..."
while [[ $count -lt $retries ]]; do
eval "$start_cmd" >> "$BOOTSTRAP_LOG" 2>&1
_safe_sleep 1
if command -v pgrep >/dev/null 2>&1 && pgrep -x "$pid_ok" >/dev/null 2>&1; then
log_bootstrap "$name started successfully"
return 0
fi
count=$((count + 1))
done
log_bootstrap "WARNING: $name may not have started after $retries attempts"
return 1
}

if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
log_bootstrap "systemd detected, starting services via systemctl"
systemctl start polkit 2>/dev/null || true
systemctl start pamac-daemon >/dev/null 2>&1 || true
else
log_bootstrap "Non-systemd environment, starting services manually"
ensure_service "dbus-daemon" "dbus-daemon" 'mkdir -p /run/dbus; dbus-daemon --system --fork 2>/dev/null'
ensure_service "polkitd" "polkitd" 'if [[ -x /usr/lib/polkit-1/polkitd ]]; then /usr/lib/polkit-1/polkitd --no-debug & fi'
ensure_service "pamac-daemon" "pamac-daemon" '/usr/bin/pamac-daemon &'
fi
BOOTSTRAP
chmod +x /usr/local/bin/pamac-session-bootstrap.sh
echo "Bootstrap helper installed."

echo "Installing fake systemd-run wrapper for non-systemd AUR builds..."
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl show-environment >/dev/null 2>&1; then
cat > /usr/local/sbin/systemd-run << 'SYSTEMD_RUN_FAKE'
#!/bin/bash
DYNAMIC_USER=false
CACHE_DIR=""
WORK_DIR=""
SKIP_NEXT=false
CMD_ARGS=()
for arg in "$@"; do
if $SKIP_NEXT; then
SKIP_NEXT=false
continue
fi
case "$arg" in
--service-type=*) continue ;;
--service-type) SKIP_NEXT=true; continue ;;
--pipe|--wait|--pty|-q|--quiet|--no-block) continue ;;
--property=DynamicUser=yes) DYNAMIC_USER=true; continue ;;
--property=CacheDirectory=*) CACHE_DIR="${arg#--property=CacheDirectory=}"; continue ;;
--property=WorkingDirectory=*) WORK_DIR="${arg#--property=WorkingDirectory=}"; continue ;;
--property=*) continue ;;
--property) SKIP_NEXT=true; continue ;;
--user|--uid=*|--gid=*|--setenv=*) continue ;;
--user|--setenv) SKIP_NEXT=true; continue ;;
*) CMD_ARGS+=("$arg") ;;
esac
done
if [[ ${#CMD_ARGS[@]} -eq 0 ]]; then exit 1; fi
if [[ -n "$WORK_DIR" ]]; then
mkdir -p "$WORK_DIR" 2>/dev/null || true
if $DYNAMIC_USER; then chown HOST_USER_PLACEHOLDER:HOST_USER_PLACEHOLDER "$WORK_DIR" 2>/dev/null || true; fi
fi
if [[ -n "$CACHE_DIR" ]]; then
CACHE_FULL="/var/cache/$CACHE_DIR"
mkdir -p "$CACHE_FULL" 2>/dev/null || true
if $DYNAMIC_USER; then chown -R HOST_USER_PLACEHOLDER:HOST_USER_PLACEHOLDER "$CACHE_FULL" 2>/dev/null || true; fi
fi
if $DYNAMIC_USER && [[ "$(id -u)" -eq 0 ]]; then
BUILD_USER="HOST_USER_PLACEHOLDER"
if ! id "$BUILD_USER" >/dev/null 2>&1; then BUILD_USER="nobody"; fi
if [[ -n "$WORK_DIR" ]]; then
exec sudo -u "$BUILD_USER" -H -- bash -c "cd '$WORK_DIR' 2>/dev/null; exec ${CMD_ARGS[*]}"
else
exec sudo -u "$BUILD_USER" -H -- "${CMD_ARGS[@]}"
fi
else
if [[ -n "$WORK_DIR" ]] && [[ -d "$WORK_DIR" ]]; then cd "$WORK_DIR" 2>/dev/null || true; fi
exec "${CMD_ARGS[@]}"
fi
SYSTEMD_RUN_FAKE
chmod +x /usr/local/sbin/systemd-run
sed -i "s/HOST_USER_PLACEHOLDER/$HOST_USER/g" /usr/local/sbin/systemd-run
echo "Fake systemd-run installed at /usr/local/sbin/systemd-run."

printf '%s\n' '#!/bin/bash' \
'/usr/local/bin/pamac-session-bootstrap.sh 2>/dev/null &' > /etc/profile.d/pamac-daemon.sh
chmod +x /etc/profile.d/pamac-daemon.sh
echo "Non-systemd bootstrap profile hook installed."
else
echo "Functional systemd detected. Pamac daemon can be started with systemctl."
fi

echo "Creating D-Bus system policy for pamac-daemon..."
mkdir -p /usr/share/dbus-1/system.d
cat > /usr/share/dbus-1/system.d/org.manjaro.pamac.daemon.conf << 'DBUS_CONF'
<!DOCTYPE busconfig PUBLIC
"-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
"http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>

<policy user="root">
<allow own="org.manjaro.pamac.daemon"/>
<allow send_destination="org.manjaro.pamac.daemon"/>
</policy>

<policy at_console="true">
<allow send_destination="org.manjaro.pamac.daemon"/>
</policy>

<policy context="default">
<allow send_destination="org.manjaro.pamac.daemon"/>
</policy>

</busconfig>
DBUS_CONF
echo "D-Bus system policy for pamac-daemon created."

echo "Critical helpers setup finished."
CRITICAL_EOF

if ! exec_container_script "$critical_script" "critical-helpers" "$CURRENT_USER"; then
log_warn "Critical helpers setup had issues, retrying..."
container_start 2>/dev/null || true
sleep 3
if container_is_usable; then
if ! exec_container_script "$critical_script" "critical-helpers-retry" "$CURRENT_USER"; then
log_warn "Critical helpers retry also failed. Will verify and repair after base setup."
_ok=false
fi
else
log_warn "Container not usable for critical helpers retry. Will verify and repair later."
_ok=false
fi
fi

if [[ "$_ok" == "true" ]]; then
log_success "Container base environment configured."
else
log_warn "Container base setup completed with some errors."
fi
}

ensure_critical_helpers() {
log_info "Verifying critical helper files in container..."

local missing_items=()

 local systemd_run_check
 systemd_run_check=$(container_root_exec test -x /usr/local/sbin/systemd-run && echo "ok" || echo "missing" 2>/dev/null)
 local has_systemd
 has_systemd=$(container_root_exec bash -c "command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null)
 if [[ "$systemd_run_check" != "ok" ]]; then
 if [[ "$has_systemd" == "yes" ]]; then
 log_debug "Fake systemd-run wrapper not present, but systemd is functional in container — not needed."
 else
 log_warn "Fake systemd-run wrapper is MISSING from container (and systemd is not functional)."
 missing_items+=("systemd-run")
 fi
 fi

local dbus_conf_check
dbus_conf_check=$(container_root_exec test -f /usr/share/dbus-1/system.d/org.manjaro.pamac.daemon.conf && echo "ok" || echo "missing" 2>/dev/null)
if [[ "$dbus_conf_check" != "ok" ]]; then
log_warn "D-Bus daemon policy config is MISSING from container."
missing_items+=("dbus-daemon-conf")
fi

local bootstrap_check
bootstrap_check=$(container_root_exec test -x /usr/local/bin/pamac-session-bootstrap.sh && echo "ok" || echo "missing" 2>/dev/null)
if [[ "$bootstrap_check" != "ok" ]]; then
log_warn "Pamac bootstrap helper is MISSING from container."
missing_items+=("bootstrap")
fi

if [[ ${#missing_items[@]} -eq 0 ]]; then
log_success "All critical helpers verified present."
return 0
fi

log_info "Repairing ${#missing_items[@]} missing critical item(s): ${missing_items[*]}"

local repair_script
read -r -d '' repair_script <<'REPAIR_EOF' || true
set -uo pipefail

HOST_USER="$1"

repaired=0

if [[ ! -x /usr/local/bin/pamac-session-bootstrap.sh ]]; then
echo "Repairing: pamac-session-bootstrap.sh..."
cat > /usr/local/bin/pamac-session-bootstrap.sh << 'BOOTSTRAP'
#!/bin/bash
set +e
BOOTSTRAP_LOG="/tmp/pamac-bootstrap.log"
touch "$BOOTSTRAP_LOG" 2>/dev/null && chmod 666 "$BOOTSTRAP_LOG" 2>/dev/null

_safe_sleep() {
if ! sleep "$1" 2>/dev/null; then
read -t "$1" -r _ 2>/dev/null || true
fi
}

log_bootstrap() {
echo "[$(date '+%H:%M:%S')] $*" >> "$BOOTSTRAP_LOG" 2>/dev/null || true
}

ensure_service() {
local name="$1"
local pid_ok="$2"
local start_cmd="$3"
local retries=5
local count=0

if command -v pgrep >/dev/null 2>&1 && pgrep -x "$pid_ok" >/dev/null 2>&1; then
log_bootstrap "$name already running (pid $(pgrep -x "$pid_ok" 2>/dev/null | head -1))"
return 0
fi

log_bootstrap "Starting $name..."
while [[ $count -lt $retries ]]; do
eval "$start_cmd" >> "$BOOTSTRAP_LOG" 2>&1
_safe_sleep 1
if command -v pgrep >/dev/null 2>&1 && pgrep -x "$pid_ok" >/dev/null 2>&1; then
log_bootstrap "$name started successfully"
return 0
fi
count=$((count + 1))
done
log_bootstrap "WARNING: $name may not have started after $retries attempts"
return 1
}

if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
log_bootstrap "systemd detected, starting services via systemctl"
systemctl start polkit 2>/dev/null || true
systemctl start pamac-daemon >/dev/null 2>&1 || true
else
log_bootstrap "Non-systemd environment, starting services manually"
ensure_service "dbus-daemon" "dbus-daemon" 'mkdir -p /run/dbus; dbus-daemon --system --fork 2>/dev/null'
ensure_service "polkitd" "polkitd" 'if [[ -x /usr/lib/polkit-1/polkitd ]]; then /usr/lib/polkit-1/polkitd --no-debug & fi'
ensure_service "pamac-daemon" "pamac-daemon" '/usr/bin/pamac-daemon &'
fi
BOOTSTRAP
chmod +x /usr/local/bin/pamac-session-bootstrap.sh
repaired=$((repaired + 1))
echo "Bootstrap helper repaired."
fi

if [[ ! -x /usr/local/sbin/systemd-run ]]; then
echo "Repairing: fake systemd-run wrapper..."
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl show-environment >/dev/null 2>&1; then
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/systemd-run << 'SYSTEMD_RUN_FAKE'
#!/bin/bash
DYNAMIC_USER=false
CACHE_DIR=""
WORK_DIR=""
SKIP_NEXT=false
CMD_ARGS=()
for arg in "$@"; do
if $SKIP_NEXT; then
SKIP_NEXT=false
continue
fi
case "$arg" in
--service-type=*) continue ;;
--service-type) SKIP_NEXT=true; continue ;;
--pipe|--wait|--pty|-q|--quiet|--no-block) continue ;;
--property=DynamicUser=yes) DYNAMIC_USER=true; continue ;;
--property=CacheDirectory=*) CACHE_DIR="${arg#--property=CacheDirectory=}"; continue ;;
--property=WorkingDirectory=*) WORK_DIR="${arg#--property=WorkingDirectory=}"; continue ;;
--property=*) continue ;;
--property) SKIP_NEXT=true; continue ;;
--user|--uid=*|--gid=*|--setenv=*) continue ;;
--user|--setenv) SKIP_NEXT=true; continue ;;
*) CMD_ARGS+=("$arg") ;;
esac
done
if [[ ${#CMD_ARGS[@]} -eq 0 ]]; then exit 1; fi
if [[ -n "$WORK_DIR" ]]; then
mkdir -p "$WORK_DIR" 2>/dev/null || true
if $DYNAMIC_USER; then chown HOST_USER_PLACEHOLDER:HOST_USER_PLACEHOLDER "$WORK_DIR" 2>/dev/null || true; fi
fi
if [[ -n "$CACHE_DIR" ]]; then
CACHE_FULL="/var/cache/$CACHE_DIR"
mkdir -p "$CACHE_FULL" 2>/dev/null || true
if $DYNAMIC_USER; then chown -R HOST_USER_PLACEHOLDER:HOST_USER_PLACEHOLDER "$CACHE_FULL" 2>/dev/null || true; fi
fi
if $DYNAMIC_USER && [[ "$(id -u)" -eq 0 ]]; then
BUILD_USER="HOST_USER_PLACEHOLDER"
if ! id "$BUILD_USER" >/dev/null 2>&1; then BUILD_USER="nobody"; fi
if [[ -n "$WORK_DIR" ]]; then
exec sudo -u "$BUILD_USER" -H -- bash -c "cd '$WORK_DIR' 2>/dev/null; exec ${CMD_ARGS[*]}"
else
exec sudo -u "$BUILD_USER" -H -- "${CMD_ARGS[@]}"
fi
else
if [[ -n "$WORK_DIR" ]] && [[ -d "$WORK_DIR" ]]; then cd "$WORK_DIR" 2>/dev/null || true; fi
exec "${CMD_ARGS[@]}"
fi
SYSTEMD_RUN_FAKE
chmod +x /usr/local/sbin/systemd-run
sed -i "s/HOST_USER_PLACEHOLDER/$HOST_USER/g" /usr/local/sbin/systemd-run
repaired=$((repaired + 1))
echo "Fake systemd-run repaired."

if [[ ! -f /etc/profile.d/pamac-daemon.sh ]]; then
printf '%s\n' '#!/bin/bash' \
'/usr/local/bin/pamac-session-bootstrap.sh 2>/dev/null &' > /etc/profile.d/pamac-daemon.sh
chmod +x /etc/profile.d/pamac-daemon.sh
echo "Bootstrap profile hook repaired."
fi
else
echo "Functional systemd detected, skipping fake systemd-run."
fi
fi

if [[ ! -f /usr/share/dbus-1/system.d/org.manjaro.pamac.daemon.conf ]]; then
echo "Repairing: D-Bus system policy for pamac-daemon..."
mkdir -p /usr/share/dbus-1/system.d
cat > /usr/share/dbus-1/system.d/org.manjaro.pamac.daemon.conf << 'DBUS_CONF'
<!DOCTYPE busconfig PUBLIC
"-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
"http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>

<policy user="root">
<allow own="org.manjaro.pamac.daemon"/>
<allow send_destination="org.manjaro.pamac.daemon"/>
</policy>

<policy at_console="true">
<allow send_destination="org.manjaro.pamac.daemon"/>
</policy>

<policy context="default">
<allow send_destination="org.manjaro.pamac.daemon"/>
</policy>

</busconfig>
DBUS_CONF
repaired=$((repaired + 1))
echo "D-Bus daemon policy repaired."
fi

echo "Repaired $repaired critical item(s)."
REPAIR_EOF

local repair_ok=false
for attempt in 1 2 3; do
if exec_container_script "$repair_script" "critical-helpers-repair-attempt-$attempt" "$CURRENT_USER"; then
repair_ok=true
break
fi
log_warn "Critical helpers repair attempt $attempt failed, restarting container..."
container_start 2>/dev/null || true
sleep 3
if ! container_is_usable; then
log_error "Container not usable for critical helpers repair."
return 1
fi
done

if [[ "$repair_ok" == "true" ]]; then
log_success "Critical helpers repaired successfully."
else
log_error "Failed to repair critical helpers after 3 attempts."
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
  set -uo pipefail

  rm -f /var/lib/pacman/db.lck

  echo "Installing reflector..."
if ! pacman -S --noconfirm --needed reflector; then
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

    if ! echo "$mirror_script" | exec_container_pipe "mirror-optimization"; then
        log_warn "Mirror optimization had issues. Continuing with default mirrors."
    fi
}

configure_multilib() {
    if [[ "$ENABLE_MULTILIB" == "true" ]]; then
        log_step "Enabling multilib (32-bit) support"

        local multilib_script
  read -r -d '' multilib_script << 'EOF' || true
  set -uo pipefail

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

        if ! echo "$multilib_script" | exec_container_pipe "multilib-setup"; then
            log_warn "Failed to enable multilib support. 32-bit packages may not be available."
        fi
    fi
}

install_aur_helper() {
    log_step "Installing AUR helper (yay)"

    if container_user_exec bash -c "command -v yay >/dev/null 2>&1" 2>/dev/null; then
        log_info "AUR helper 'yay' is already installed."
        return 0
    fi

	log_info "Verifying build dependencies (git, base-devel, go) are present..."
	local verify_script
	read -r -d '' verify_script <<'VERIFY_EOF' || true
set -uo pipefail

rm -f /var/lib/pacman/db.lck

_missing=""
command -v git >/dev/null 2>&1 || _missing="$_missing git"
pacman -Q base-devel >/dev/null 2>&1 || _missing="$_missing base-devel"
command -v go >/dev/null 2>&1 || _missing="$_missing go"

if [[ -n "$_missing" ]]; then
	echo "Missing build dependencies:$_missing — installing..."
	safe_install() {
		local attempt=0
		local max_attempts=3
		local rc=0
		while [[ $attempt -lt $max_attempts ]]; do
			rm -f /var/lib/pacman/db.lck
			if pacman -S --noconfirm --needed "$@"; then
				ldconfig 2>/dev/null || true
				return 0
			fi
			rc=$?
			attempt=$((attempt + 1))
			if [[ $attempt -lt $max_attempts ]]; then
				echo "Install failed (attempt $attempt/$max_attempts, exit=$rc), repairing DB..."
				if [[ $rc -eq 137 ]]; then
					echo "Exit code 137 indicates OOM kill. Syncing and retrying..."
					sync 2>/dev/null || true
					_safe_sleep 3
				fi
				pacman -Dk 2>/dev/null || true
				pacman -Syy --noconfirm 2>/dev/null || true
				_safe_sleep 3
			fi
		done
		return $rc
	}

	for pkg in $_missing; do
		if [[ "$pkg" == "base-devel" ]]; then
			BASE_DEVEL_BATCHES=(
				"m4 autoconf automake binutils"
				"bison debugedit diffutils fakeroot"
				"flex"
				"gcc"
				"gettext groff"
				"gzip libtool make patch"
				"pkgconf sed texinfo which"
			)
			for batch in "${BASE_DEVEL_BATCHES[@]}"; do
				echo "Installing batch: $batch"
				sync 2>/dev/null || true
				_safe_sleep 1
				if ! safe_install $batch; then
					echo "Warning: batch install failed for: $batch"
				fi
			done
			if ! pacman -Q base-devel >/dev/null 2>&1 && ! safe_install base-devel; then
				echo "Warning: base-devel group meta-package could not be installed."
			fi
		else
			echo "Installing $pkg..."
			if ! safe_install "$pkg"; then
				echo "Failed to install $pkg."
				exit 1
			fi
		fi
	done
	echo "Missing dependencies installed."
else
	echo "All build dependencies already present."
fi
VERIFY_EOF

	if ! exec_container_script "$verify_script" "yay-deps-verify"; then
		if ! container_is_usable; then
			log_warn "Container not usable. Restarting..."
			container_start 2>/dev/null || true
			wait_for_container || {
				log_error "Container unrecoverable."
				return 1
			}
			log_info "Retrying build dependency verification..."
			if ! exec_container_script "$verify_script" "yay-deps-verify-retry"; then
				log_error "Failed to verify/install build dependencies."
				return 1
			fi
		else
			log_error "Failed to verify/install build dependencies."
			return 1
		fi
	fi

    log_info "Stage 2/2: Building yay from AUR..."
    local build_script
    read -r -d '' build_script <<'BUILD_EOF' || true
set -uo pipefail

current_user="$1"

rm -f /var/lib/pacman/db.lck

echo "Cloning and building yay from AUR..."
rm -rf /tmp/yay

echo "Ensuring CA certificates are available for HTTPS..."
pacman -S --noconfirm --needed ca-certificates-mozilla 2>/dev/null || true

clone_retry=0
max_clone_retries=3
while [[ $clone_retry -lt $max_clone_retries ]]; do
    if sudo -Hu "$current_user" git clone "https://aur.archlinux.org/yay.git" /tmp/yay 2>/tmp/yay_clone_err; then
        break
    fi
    clone_err=$(cat /tmp/yay_clone_err 2>/dev/null || true)
    clone_retry=$((clone_retry + 1))
    if [[ $clone_retry -lt $max_clone_retries ]]; then
        if echo "$clone_err" | grep -qi "SSL\|TLS\|certificate"; then
            echo "TLS error detected, retrying with SSL verification disabled..."
            if sudo -Hu "$current_user" env GIT_SSL_NO_VERIFY=true git clone "https://aur.archlinux.org/yay.git" /tmp/yay 2>/tmp/yay_clone_err; then
                break
            fi
        fi
wait_time=$((2 ** clone_retry))
echo "Clone failed (attempt $clone_retry/$max_clone_retries). Retrying in ${wait_time}s..."
_safe_sleep "$wait_time"
    else
        echo "Clone failed after $max_clone_retries attempts."
        cat /tmp/yay_clone_err 2>/dev/null || true
        echo "AUR clone failed. Trying to download yay from GitHub..."
        rm -rf /tmp/yay
        if sudo -Hu "$current_user" git clone --depth=1 "https://github.com/Jguer/yay.git" /tmp/yay 2>/tmp/yay_gh_err; then
            echo "Successfully cloned yay from GitHub."
        else
            echo "GitHub clone also failed."
            cat /tmp/yay_gh_err 2>/dev/null || true
            exit 1
        fi
    fi
done

chown -R "$current_user:$current_user" /tmp/yay
sudo -Hu "$current_user" bash -lc "cd /tmp/yay && makepkg -si --noconfirm --clean"
BUILD_EOF

    if ! exec_container_script "$build_script" "yay-build" "$CURRENT_USER"; then
        log_error "Failed to build yay from AUR."
        return 1
    fi

    log_success "AUR helper yay installed."
}

install_pamac() {
    log_step "Installing Pamac package manager"

    if container_user_exec bash -c "command -v pamac-manager >/dev/null 2>&1 && command -v pamac >/dev/null 2>&1" 2>/dev/null; then
        log_info "Pamac is already installed (manager + CLI)."
        return 0
    fi

    log_info "Stage 1/2: Installing pamac-aur from AUR..."
    local pamac_install
read -r -d '' pamac_install <<'PAMAC_INSTALL_EOF' || true
set -uo pipefail

current_user="$1"

rm -f /var/lib/pacman/db.lck

echo "Installing pamac-aur from AUR..."
pamac_installed=false
for attempt in 1 2 3; do
    if sudo -Hu "$current_user" bash -lc "yay -S --noconfirm --needed --noprogressbar pamac-aur"; then
        pamac_installed=true
        break
    fi
    echo "yay install attempt $attempt failed. Retrying in 5 seconds..."
    _safe_sleep 5
    sudo -Hu "$current_user" bash -lc "yay -Y --gendb" 2>/dev/null || true
    rm -f /var/lib/pacman/db.lck
done

if [[ "$pamac_installed" != "true" ]]; then
    echo "Error: pamac-aur install failed after 3 attempts."
    exit 1
fi

if ! command -v pamac >/dev/null 2>&1; then
    echo "pamac CLI not found after yay reported success. Retrying without --needed..."
    rm -f /var/lib/pacman/db.lck
    sudo -Hu "$current_user" bash -lc "yay -S --noconfirm --noprogressbar pamac-aur" || true
fi

if ! command -v pamac-manager >/dev/null 2>&1; then
    echo "Error: pamac-manager not found after install."
    exit 1
fi
if ! command -v pamac >/dev/null 2>&1; then
    echo "Error: pamac CLI not found after install."
    exit 1
fi
echo "pamac-manager and pamac CLI installed successfully."
PAMAC_INSTALL_EOF

    if ! exec_container_script "$pamac_install" "pamac-install" "$CURRENT_USER"; then
        if ! container_is_usable; then
            log_warn "Container not usable after pamac install. Restarting..."
            container_start 2>/dev/null || true
            wait_for_container || {
                log_error "Container unrecoverable."
                return 1
            }
            log_info "Retrying pamac install..."
            if ! exec_container_script "$pamac_install" "pamac-install-retry" "$CURRENT_USER"; then
                log_error "Failed to install Pamac after retry."
                return 1
            fi
        else
            log_error "Failed to install Pamac."
            return 1
        fi
    fi

if ! container_user_exec bash -c "command -v pamac-manager >/dev/null 2>&1" 2>/dev/null; then
    log_error "pamac-manager not found after installation. Disk or network issue?"
    return 1
fi

if ! container_user_exec bash -c "command -v pamac >/dev/null 2>&1" 2>/dev/null; then
    log_error "pamac CLI not found after installation. pamac-aur may not have installed correctly."
    return 1
fi

    log_info "Stage 2/2: Configuring Pamac..."
    local pamac_cfg
    read -r -d '' pamac_cfg <<'PAMAC_CFG_EOF' || true
set -uo pipefail

current_user="$1"

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

echo "Setting BuildDirectory for AUR builds (writable by non-root)..."
if grep -q '^BuildDirectory' /etc/pamac.conf; then
sed -i 's|^BuildDirectory.*|BuildDirectory = /home/'"$current_user"'/\.pamac-build|' /etc/pamac.conf
else
echo "BuildDirectory = /home/$current_user/.pamac-build" >> /etc/pamac.conf
fi
mkdir -p "/home/$current_user/.pamac-build"
chown "$current_user:$current_user" "/home/$current_user/.pamac-build" 2>/dev/null || true
echo "BuildDirectory set to /home/$current_user/.pamac-build"

echo "Patching polkit policy for non-interactive authorization..."
pamac_policy="/usr/share/polkit-1/actions/org.manjaro.pamac.policy"
if [[ -f "$pamac_policy" ]]; then
sed -i 's|<allow_any>auth_admin_keep</allow_any>|<allow_any>yes</allow_any>|' "$pamac_policy"
sed -i 's|<allow_inactive>auth_admin_keep</allow_inactive>|<allow_inactive>yes</allow_inactive>|' "$pamac_policy"
sed -i 's|<allow_active>auth_admin_keep</allow_active>|<allow_active>yes</allow_active>|' "$pamac_policy"
echo "Polkit policy patched: allow_any=yes, allow_inactive=yes, allow_active=yes"
else
echo "Warning: pamac polkit policy file not found at $pamac_policy"
fi
else
echo "Warning: /etc/pamac.conf not found. Creating minimal config."
mkdir -p /etc
printf 'EnableAUR\nCheckAURUpdates\nCheckAURVCSUpdates\nBuildDirectory = /home/'"$current_user"'/.pamac-build\n' > /etc/pamac.conf
mkdir -p "/home/$current_user/.pamac-build"
chown "$current_user:$current_user" "/home/$current_user/.pamac-build" 2>/dev/null || true
fi

    echo "Syncing package database..."
if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
systemctl start polkit 2>/dev/null || true
systemctl enable --now pamac-daemon 2>/dev/null || echo "Note: pamac-daemon service could not be enabled"
else
/usr/local/bin/pamac-session-bootstrap.sh 2>/dev/null || true
fi
pacman -Sy --noconfirm >/dev/null 2>&1 || echo "Note: package database sync failed"

if command -v pamac-manager >/dev/null 2>&1; then
    echo "Pamac installed successfully."
    pamac --version 2>/dev/null || echo "Pamac version info not available"
else
    echo "Error: Pamac installation verification failed."
    exit 1
fi
PAMAC_CFG_EOF

    exec_container_script "$pamac_cfg" "pamac-config" "$CURRENT_USER" || log_warn "Pamac configuration had minor issues."
}

install_gaming_packages() {
    if [[ "$ENABLE_GAMING_PACKAGES" != "true" ]]; then
        log_info "Skipping gaming packages (use --enable-gaming to include them)."
        return
    fi

    log_step "Installing gaming packages"

    local gaming_script
    read -r -d '' gaming_script << 'EOF' || true
set -uo pipefail

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

    if ! echo "$gaming_script" | exec_container_pipe "gaming-packages" "$CURRENT_USER" "$ENABLE_MULTILIB"; then
        log_warn "Gaming package installation encountered errors."
    fi
}

configure_ssh_environment() {
    log_step "Configuring SSH environment for nested commands"

    if ! grep -qi steamos /etc/os-release 2>/dev/null; then
        log_info "Not SteamOS, skipping SSH environment setup."
        return 0
    fi

    local ssh_dir="$HOME/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    if [[ ! -f "$ssh_dir/environment" ]] || ! grep -q '^PATH=' "$ssh_dir/environment" 2>/dev/null; then
        echo "PATH=/home/$CURRENT_USER/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin" > "$ssh_dir/environment"
        chmod 644 "$ssh_dir/environment"
        log_info "Created $ssh_dir/environment with clean PATH"
    fi

    local sshd_conf_dir="/etc/ssh/sshd_config.d"
    local permit_env_conf="$sshd_conf_dir/permit-user-env.conf"
    if [[ ! -f "$permit_env_conf" ]]; then
        if mkdir -p "$sshd_conf_dir" 2>/dev/null; then
            echo "PermitUserEnvironment yes" | run_command tee "$permit_env_conf" > /dev/null 2>&1
            if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
                run_command systemctl restart sshd 2>/dev/null || true
            else
                run_command pkill -HUP sshd 2>/dev/null || true
            fi
            log_info "Enabled PermitUserEnvironment in sshd"
        else
log_warn "Could not create sshd config directory (need sudo)"
if command -v sudo >/dev/null 2>&1; then
if sudo -n true 2>/dev/null; then
sudo -n mkdir -p "$sshd_conf_dir" 2>/dev/null || true
echo "PermitUserEnvironment yes" | sudo -n tee "$permit_env_conf" > /dev/null 2>&1 || true
sudo -n pkill -HUP sshd 2>/dev/null || true
log_info "Enabled PermitUserEnvironment via sudo (NOPASSWD)"
else
log_warn "sudo requires a password and this step cannot proceed non-interactively. To enable SSH PermitUserEnvironment manually, run:"
log_warn "  sudo mkdir -p $sshd_conf_dir && echo 'PermitUserEnvironment yes' | sudo tee $permit_env_conf && sudo pkill -HUP sshd"
fi
fi
        fi
    fi

    local profile_d_file="/etc/profile.d/deck-local-bin.sh"
    if [[ ! -f "$profile_d_file" ]]; then
        echo 'export PATH="/home/'"$CURRENT_USER"'/.local/bin:$PATH"' | run_command tee "$profile_d_file" > /dev/null 2>&1 || true
if [[ ! -f "$profile_d_file" ]]; then
if command -v sudo >/dev/null 2>&1; then
if sudo -n true 2>/dev/null; then
echo 'export PATH="/home/'"$CURRENT_USER"'/.local/bin:$PATH"' | sudo -n tee "$profile_d_file" > /dev/null 2>&1 || true
else
log_warn "sudo requires a password and this step cannot proceed non-interactively. To create $profile_d_file manually, run:"
log_warn "  echo 'export PATH=\"/home/$CURRENT_USER/.local/bin:\$PATH\"' | sudo tee $profile_d_file"
fi
fi
fi
        if [[ -f "$profile_d_file" ]]; then
            chmod 644 "$profile_d_file" 2>/dev/null || true
            log_info "Created $profile_d_file"
        else
            log_warn "Could not create $profile_d_file"
        fi
    fi

    local bashrc_file="$HOME/.bashrc"
    if [[ -f "$bashrc_file" ]]; then
        if ! grep -q '^export HOME=' "$bashrc_file" 2>/dev/null || ! grep -q '^export PATH=.*\.local/bin' "$bashrc_file" 2>/dev/null; then
            local bashrc_header
            bashrc_header='#\n# ~/.bashrc\n#\nexport HOME="/home/'"$CURRENT_USER"'"\nexport PATH="/home/'"$CURRENT_USER"'/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin"\n'
            if grep -q '^\[\[ \$- != \*i\* \]\]' "$bashrc_file" 2>/dev/null || grep -q '^\[\[ \$- !=' "$bashrc_file" 2>/dev/null; then
                run_command sed -i "1i\\${bashrc_header}" "$bashrc_file" 2>/dev/null || true
            else
                { echo -e "$bashrc_header"; cat "$bashrc_file"; } > "$bashrc_file.tmp" 2>/dev/null && mv "$bashrc_file.tmp" "$bashrc_file" 2>/dev/null || true
            fi
            if grep -q '^export HOME=' "$bashrc_file" 2>/dev/null; then
                log_info "Patched .bashrc with HOME/PATH exports before non-interactive check"
            else
                log_warn "Could not patch .bashrc automatically"
            fi
        fi
    fi

    log_success "SSH environment configured for nested commands"
}

export_pamac_to_host() {
    log_step "Exporting Pamac to host system"

    local current_user="$CURRENT_USER"
    local desktop_dir="$HOME/.local/share/applications"
    local icon_svg_dir="$HOME/.local/share/icons/hicolor/scalable/apps"
    local icon_png48_dir="$HOME/.local/share/icons/hicolor/48x48/apps"
    mkdir -p "$icon_svg_dir" "$icon_png48_dir"

    log_info "Copying pamac icons from container to host..."

    local icon_copied=false
    local svg_sources=(
        /usr/share/icons/hicolor/scalable/apps/pamac-manager.svg
        /usr/share/icons/hicolor/scalable/apps/org.manjaro.pamac.manager.svg
        /usr/share/icons/hicolor/scalable/apps/system-software-install.svg
        /usr/share/icons/hicolor/48x48/apps/system-software-install.svg
        /usr/share/icons/hicolor/32x32/apps/system-software-install.svg
        /usr/share/icons/hicolor/16x16/apps/system-software-install.svg
        /usr/share/pixmaps/pamac-manager.svg
    )
    for src_icon in "${svg_sources[@]}"; do
        if container_cp_from "$src_icon" "$icon_svg_dir/pamac-manager.svg"; then
            if [[ -s "$icon_svg_dir/pamac-manager.svg" ]]; then
                log_info "Copied SVG icon from $src_icon"
                icon_copied=true
                break
            else
                rm -f "$icon_svg_dir/pamac-manager.svg"
            fi
        fi
    done

    local png_sources=(
        /usr/share/icons/hicolor/48x48/apps/pamac-manager.png
        /usr/share/icons/hicolor/48x48/apps/org.manjaro.pamac.manager.png
        /usr/share/icons/hicolor/48x48/apps/system-software-install.png
        /usr/share/icons/hicolor/64x64/apps/pamac-manager.png
        /usr/share/icons/hicolor/64x64/apps/system-software-install.png
        /usr/share/icons/AdwaitaLegacy/48x48/legacy/system-software-install.png
        /usr/share/icons/AdwaitaLegacy/32x32/legacy/system-software-install.png
        /usr/share/pixmaps/pamac-manager.png
    )
    for src_icon in "${png_sources[@]}"; do
        if container_cp_from "$src_icon" "$icon_png48_dir/pamac-manager.png"; then
            if [[ -s "$icon_png48_dir/pamac-manager.png" ]]; then
                log_info "Copied PNG icon from $src_icon"
                icon_copied=true
                break
            else
                rm -f "$icon_png48_dir/pamac-manager.png"
            fi
        fi
    done

    if [[ "$icon_copied" == "false" ]]; then
        log_info "Pamac icons not found in container. Using system default icon."
    fi

    command -v gtk-update-icon-cache >/dev/null 2>&1 && \
        gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" -f 2>/dev/null || true

    log_info "Creating pamac-manager launch wrapper inside container..."
    printf '%s\n' '#!/bin/bash' \
        'set +e' \
        '/usr/local/bin/pamac-session-bootstrap.sh >/dev/null 2>&1 || true' \
        'exec pamac-manager "$@"' \
        | container_root_exec tee /usr/local/bin/pamac-manager-wrapper > /dev/null
    container_root_exec chmod +x /usr/local/bin/pamac-manager-wrapper
    log_info "pamac-manager-wrapper created inside container."

    printf '%s\n' '#!/bin/bash' \
        'set +e' \
        '/usr/local/bin/pamac-session-bootstrap.sh >/dev/null 2>&1 || true' \
        'exec pamac "$@"' \
        | container_root_exec tee /usr/local/bin/pamac-cli-wrapper > /dev/null
    container_root_exec chmod +x /usr/local/bin/pamac-cli-wrapper

    log_info "Exporting Pamac application using distrobox-export..."
    local distrobox_export_ok=false
	if run_command distrobox-enter "$CONTAINER_NAME" -- env XDG_DATA_DIRS="/usr/local/share:/usr/share" XDG_DATA_HOME="/home/${CURRENT_USER}/.local/share" distrobox-export --container "$CONTAINER_NAME" --app pamac-manager; then
        log_success "Pamac exported via distrobox-export."
        distrobox_export_ok=true
    fi

    mkdir -p "$desktop_dir"
    local exported_desktop=""

    local possible_files=(
        "$desktop_dir/${CONTAINER_NAME}-org.manjaro.pamac.manager.desktop"
        "$desktop_dir/${CONTAINER_NAME}-pamac-manager.desktop"
    )
    for f in "${possible_files[@]}"; do
        if [[ -f "$f" ]]; then
            exported_desktop="$f"
            break
        fi
    done

    if [[ -z "$exported_desktop" ]] && [[ "$distrobox_export_ok" == "true" ]]; then
        exported_desktop=$(find "$desktop_dir" -maxdepth 1 -type f -name "${CONTAINER_NAME}-*.desktop" 2>/dev/null | head -1)
    fi

    if [[ -z "$exported_desktop" ]]; then
        log_warn "distrobox-export did not produce a desktop file. Creating manually..."
        exported_desktop="$desktop_dir/${CONTAINER_NAME}-org.manjaro.pamac.manager.desktop"
        cat > "$exported_desktop" << DESKTOP_EOF
[Desktop Entry]
Name=Add/Remove Software (on ${CONTAINER_NAME})
Comment=Manage packages inside the ${CONTAINER_NAME} distrobox
Exec=distrobox enter ${CONTAINER_NAME} -- pamac-manager-wrapper %U
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;PackageManager;Settings;
Keywords=package;manager;software;arch;aur;
StartupNotify=true
StartupWMClass=pamac-manager
Actions=uninstall;
X-SteamOS-Pamac-Managed=true
X-SteamOS-Pamac-Container=${CONTAINER_NAME}
X-SteamOS-Pamac-SourceApp=pamac-manager
X-SteamOS-Pamac-SourceDesktop=org.manjaro.pamac.manager.desktop
X-SteamOS-Pamac-SourcePackage=pamac-aur

[Desktop Action uninstall]
Name=Uninstall Packages
Exec=${HOME}/.local/bin/steamos-pamac-uninstall --desktop-file ${CONTAINER_NAME}-org.manjaro.pamac.manager.desktop
Icon=edit-delete
DESKTOP_EOF
        chmod +x "$exported_desktop"
        log_success "Created manual desktop entry: $exported_desktop"
    fi

    if [[ -z "$exported_desktop" ]]; then
        exported_desktop="$desktop_dir/${CONTAINER_NAME}-org.manjaro.pamac.manager.desktop"
    fi

    log_info "Writing clean pamac-manager desktop entry with proper integration markers..."
    cat > "$exported_desktop" << DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=Add/Remove Software (on ${CONTAINER_NAME})
Comment=Manage packages inside the ${CONTAINER_NAME} distrobox
Exec=distrobox enter ${CONTAINER_NAME} -- pamac-manager-wrapper %U
Icon=system-software-install
Terminal=false
Categories=System;PackageManager;Settings;
Keywords=package;manager;software;arch;aur;
StartupNotify=true
StartupWMClass=pamac-manager
NoDisplay=false
DBusActivatable=false
Actions=uninstall;
X-SteamOS-Pamac-Managed=true
X-SteamOS-Pamac-Container=${CONTAINER_NAME}
X-SteamOS-Pamac-SourceApp=pamac-manager
X-SteamOS-Pamac-SourceDesktop=org.manjaro.pamac.manager.desktop
X-SteamOS-Pamac-SourcePackage=pamac-aur

[Desktop Action uninstall]
Name=Uninstall Packages
Exec=${HOME}/.local/bin/steamos-pamac-uninstall --desktop-file "${CONTAINER_NAME}-org.manjaro.pamac.manager.desktop"
Icon=edit-delete
DESKTOP_EOF
    chmod +x "$exported_desktop"
    log_success "Pamac desktop entry written: $exported_desktop"

    if [[ ! -f "$exported_desktop" ]]; then
        log_error "Failed to create desktop entry."
        return 1
    fi

    mkdir -p "$HOME/.local/share/steamos-pamac/$CONTAINER_NAME"
    printf '%s\n' "$exported_desktop" > "$HOME/.local/share/steamos-pamac/$CONTAINER_NAME/exported-apps.list"
    rm -f "$HOME/.local/share/applications/${CONTAINER_NAME}.desktop" 2>/dev/null || true

    if command -v update-desktop-database >/dev/null 2>&1; then
        run_command update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    fi

    local bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"
    local cli_wrapper="$bin_dir/pamac-${CONTAINER_NAME}"

cat > "$cli_wrapper" << WRAPPER_EOF
#!/bin/bash
exec distrobox enter "${CONTAINER_NAME}" -- pamac-cli-wrapper "\$@"
WRAPPER_EOF
chmod +x "$cli_wrapper"
log_info "Created CLI wrapper: $cli_wrapper"

local uninstall_helper="$bin_dir/steamos-pamac-uninstall"
cat > "$uninstall_helper" << UNINSTALL_EOF
#!/bin/bash
set +e
export HOME="/home/${current_user}"
export PATH="/home/${current_user}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin"
CONTAINER_NAME="${CONTAINER_NAME}"
CONTAINER_MANAGER="${DISTROBOX_CONTAINER_MANAGER:-podman}"
APP_DIR="\$HOME/.local/share/applications"
STATE_DIR="\$HOME/.local/share/steamos-pamac/\$CONTAINER_NAME"
LOG_FILE="\$STATE_DIR/uninstall-helper.log"

mkdir -p "\$STATE_DIR"

_log() {
echo "\$(date): \$*" >> "\$LOG_FILE"
}

_setup_display_env() {
[[ -n "\$DISPLAY" ]] || export DISPLAY=":0"
[[ -n "\$XDG_RUNTIME_DIR" ]] || export XDG_RUNTIME_DIR="/run/user/\$(id -u)"
[[ -n "\$DBUS_SESSION_BUS_ADDRESS" ]] || export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$(id -u)/bus"

if [[ -z "\$WAYLAND_DISPLAY" ]]; then
if [[ -e /run/user/\$(id -u)/wayland-0 ]]; then
export WAYLAND_DISPLAY="wayland-0"
elif [[ -S /run/user/\$(id -u)/wayland-0 ]]; then
export WAYLAND_DISPLAY="wayland-0"
fi
fi

if [[ -n "\$XDG_RUNTIME_DIR" && ! -d "\$XDG_RUNTIME_DIR" ]]; then
mkdir -p "\$XDG_RUNTIME_DIR" 2>/dev/null
fi
}

_log "=== steamos-pamac-uninstall invoked: \$* ==="
 _log "HOME=\$HOME PATH=\$PATH USER=\$(whoami 2>/dev/null || id -un)"
 _log "container manager=\$(command -v \"\$CONTAINER_MANAGER\" 2>/dev/null || echo NOT_FOUND)"

 show_help() {
    echo "Usage: steamos-pamac-uninstall [options]"
    echo "Options:"
    echo "  --desktop-file FILE   Uninstall the package associated with the given desktop file"
    echo "  --package PKG         Uninstall a package by name from the container"
 echo " --list List all pamac-managed applications"
    echo "  --help                Show this help"
}

 uninstall_package() {
 local pkg="\$1"
 if [[ -z "\$pkg" ]]; then
 echo "Error: No package specified." >&2
 _log "Error: No package specified"
 exit 1
 fi
 echo "Uninstalling \$pkg from \$CONTAINER_NAME..."
 _log "Uninstalling \$pkg from \$CONTAINER_NAME..."

 if ! command -v "\$CONTAINER_MANAGER" >/dev/null 2>&1; then
 _log "Error: \$CONTAINER_MANAGER not found in PATH"
 echo "Error: \$CONTAINER_MANAGER not found in PATH" >&2
 exit 1
 fi

 _log "Starting container if stopped..."
 "\$CONTAINER_MANAGER" start "\$CONTAINER_NAME" 2>/dev/null || true

 if ! "\$CONTAINER_MANAGER" inspect "\$CONTAINER_NAME" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
echo "Error: Container \$CONTAINER_NAME is not running and could not be started" >&2
_log "Error: Container not running and could not be started"
exit 1
fi

_log "Removing \$pkg via pacman -Rns (as root, no D-Bus needed)..."
local remove_output
 remove_output=\$("\$CONTAINER_MANAGER" exec -u 0 "\$CONTAINER_NAME" bash -c "
rm -f /var/lib/pacman/db.lck 2>/dev/null
pacman -Rns --noconfirm \"\$pkg\" 2>&1
" </dev/null 2>&1)
local rc=\$?
_log "pacman -Rns exit code: \$rc"
_log "pacman output: \${remove_output:0:500}"

if [[ \$rc -eq 0 ]]; then
echo "Successfully uninstalled \$pkg"
_log "Successfully uninstalled \$pkg"
_setup_display_env
update-desktop-database "\$APP_DIR" 2>/dev/null || true
kbuildsycoca6 2>/dev/null || true
qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.refreshCurrentShell 2>/dev/null || true
_log "Plasma menu refresh triggered"
else
echo "Failed to uninstall \$pkg (exit code: \$rc)" >&2
_log "Failed to uninstall \$pkg (exit code: \$rc)"
exit \$rc
fi
 }

list_apps() {
    if [[ -f "\$STATE_DIR/exported-apps.list" ]]; then
    while IFS= read -r desktop_path; do
        [[ -f "\$desktop_path" ]] || continue
        local pkg
        pkg=\$(grep '^X-SteamOS-Pamac-SourcePackage=' "\$desktop_path" 2>/dev/null | cut -d= -f2)
        local name
        name=\$(grep '^Name=' "\$desktop_path" 2>/dev/null | head -1 | cut -d= -f2)
        if [[ -n "\$pkg" ]]; then
            echo "\$name [\$pkg]"
        fi
    done < "\$STATE_DIR/exported-apps.list"
    else
        echo "No pamac-managed applications found."
    fi
}

if [[ \$# -eq 0 ]]; then
show_help
exit 0
fi

case "\$1" in
--desktop-file)
shift
desktop_file="\$1"
if [[ -z "\$desktop_file" ]]; then
echo "Error: --desktop-file requires a file name argument" >&2
exit 1
fi
full_path="\$APP_DIR/\$desktop_file"
if [[ ! -f "\$full_path" ]]; then
echo "Error: Desktop file not found: \$full_path" >&2
exit 1
fi
pkg=\$(grep '^X-SteamOS-Pamac-SourcePackage=' "\$full_path" 2>/dev/null | cut -d= -f2)
if [[ -z "\$pkg" ]]; then
echo "Error: No X-SteamOS-Pamac-SourcePackage marker found in \$full_path" >&2
exit 1
fi
uninstall_package "\$pkg"
;;
--package)
    shift
    pkg="\$1"
    if [[ -z "\$pkg" ]]; then
        echo "Error: --package requires a package name argument" >&2
        exit 1
    fi
    uninstall_package "\$pkg"
 ;;
 --list)
list_apps
;;
--help|-h)
show_help
;;
*)
echo "Error: Unknown option \$1" >&2
show_help
exit 1
;;
esac
UNINSTALL_EOF
    chmod +x "$uninstall_helper"
    log_info "Created uninstall helper: $uninstall_helper"

local appstream_handler="$bin_dir/steamos-pamac-appstream-handler"
cat > "$appstream_handler" << APPSTREAM_EOF
#!/bin/bash
set +e
export HOME="/home/${current_user}"
export PATH="/home/${current_user}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin"

APP_DIR="\$HOME/.local/share/applications"
STATE_DIR="\$HOME/.local/share/steamos-pamac/${CONTAINER_NAME}"
UNINSTALL_HELPER="\$HOME/.local/bin/steamos-pamac-uninstall"
LOG_FILE="\$STATE_DIR/appstream-handler.log"

mkdir -p "\$STATE_DIR"

log_msg() {
echo "\$(date): \$*" >> "\$LOG_FILE"
}

_setup_display_env() {
[[ -n "\$DISPLAY" ]] || export DISPLAY=":0"
[[ -n "\$XDG_RUNTIME_DIR" ]] || export XDG_RUNTIME_DIR="/run/user/$(id -u)"
[[ -n "\$DBUS_SESSION_BUS_ADDRESS" ]] || export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"

if [[ -z "\$WAYLAND_DISPLAY" ]]; then
if [[ -e /run/user/$(id -u)/wayland-0 ]]; then
export WAYLAND_DISPLAY="wayland-0"
elif [[ -S /run/user/$(id -u)/wayland-0 ]]; then
export WAYLAND_DISPLAY="wayland-0"
fi
fi

if [[ -n "\$XDG_RUNTIME_DIR" && ! -d "\$XDG_RUNTIME_DIR" ]]; then
mkdir -p "\$XDG_RUNTIME_DIR" 2>/dev/null
fi
}

log_msg "=== appstream-handler invoked: \$* ==="
log_msg "Initial env: DISPLAY=\$DISPLAY WAYLAND=\$WAYLAND_DISPLAY XDG=\$XDG_RUNTIME_DIR DBUS=\$DBUS_SESSION_BUS_ADDRESS"

_setup_display_env

log_msg "After setup: DISPLAY=\$DISPLAY WAYLAND=\$WAYLAND_DISPLAY XDG=\$XDG_RUNTIME_DIR DBUS=\$DBUS_SESSION_BUS_ADDRESS"

APPSTREAM_URL="\$1"

if [[ -z "\$APPSTREAM_URL" ]]; then
log_msg "Error: No URL argument provided, falling through to Discover"
exec plasma-discover "\$@"
fi

COMPONENT_ID="\${APPSTREAM_URL#appstream://}"

if [[ -z "\$COMPONENT_ID" ]]; then
log_msg "Error: Empty component ID, falling through to Discover"
exec plasma-discover "\$@"
fi

log_msg "Component ID: \$COMPONENT_ID"

FOUND_DESKTOP=""

for desktop_file in "\$APP_DIR"/${CONTAINER_NAME}-*.desktop; do
[[ -f "\$desktop_file" ]] || continue

SOURCE_DESKTOP=\$(grep '^X-SteamOS-Pamac-SourceDesktop=' "\$desktop_file" 2>/dev/null | cut -d= -f2)

if [[ "\$SOURCE_DESKTOP" == "\$COMPONENT_ID" ]]; then
FOUND_DESKTOP="\$desktop_file"
log_msg "Found matching pamac-managed app: \$desktop_file (source: \$SOURCE_DESKTOP)"
break
fi

BASENAME=\$(basename "\$desktop_file" .desktop)
ENTRY_NAME="\${BASENAME#${CONTAINER_NAME}-}"
if [[ "\$ENTRY_NAME" == "\${COMPONENT_ID%.desktop}" ]]; then
FOUND_DESKTOP="\$desktop_file"
log_msg "Found matching pamac-managed app by entry name: \$desktop_file"
break
fi
done

if [[ -n "\$FOUND_DESKTOP" ]]; then
log_msg "Routing to pamac uninstall handler for: \$(basename "\$FOUND_DESKTOP")"

SOURCE_PKG=\$(grep '^X-SteamOS-Pamac-SourcePackage=' "\$FOUND_DESKTOP" 2>/dev/null | cut -d= -f2)
APP_NAME=\$(grep '^Name=' "\$FOUND_DESKTOP" 2>/dev/null | head -1 | cut -d= -f2)
DESKTOP_BASENAME=\$(basename "\$FOUND_DESKTOP")

CONFIRMED=false
if command -v kdialog >/dev/null 2>&1; then
log_msg "Attempting kdialog confirmation..."
kdialog --yesno "Remove \$APP_NAME? This was installed via Pamac (AUR)." --title "Uninstall" 2>>"\$LOG_FILE"
KDIALOG_RC=\$?
log_msg "kdialog exit code: \$KDIALOG_RC"
if [[ \$KDIALOG_RC -eq 0 ]]; then
CONFIRMED=true
else
log_msg "User cancelled uninstall (kdialog rc=\$KDIALOG_RC)"
exit 0
fi
else
log_msg "kdialog not found, proceeding without confirmation"
CONFIRMED=true
fi

if \$CONFIRMED; then
log_msg "Starting uninstall for \$DESKTOP_BASENAME..."
UNINSTALL_LOG="\$STATE_DIR/uninstall-\$(date +%s).log"

systemd-run --user --scope -u "steamos-pamac-uninstall-\$(date +%s)" \\
bash -c "
export HOME=/home/${current_user}
export PATH=/home/${current_user}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
export DISPLAY=\$DISPLAY
export WAYLAND_DISPLAY=\$WAYLAND_DISPLAY
export XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR
export DBUS_SESSION_BUS_ADDRESS=\$DBUS_SESSION_BUS_ADDRESS

'\$UNINSTALL_HELPER' --desktop-file '\$DESKTOP_BASENAME' > '\$UNINSTALL_LOG' 2>&1
rc=\\\$?
echo \\\"Exit code: \\\$rc\\\" >> '\$UNINSTALL_LOG'

if [ \\\$rc -eq 0 ]; then
update-desktop-database '\$APP_DIR' 2>/dev/null
kbuildsycoca6 2>/dev/null
qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.refreshCurrentShell 2>/dev/null || true
notify-send -i edit-delete 'Uninstalled' '\$APP_NAME has been removed.' 2>/dev/null
else
notify-send -i dialog-error 'Uninstall Failed' 'Could not remove \$APP_NAME. See log for details.' 2>/dev/null
fi
" &>/dev/null &

disown
log_msg "Uninstall launched in background scope"
fi
exit 0
else
log_msg "No pamac-managed app found for component: \$COMPONENT_ID, passing to Discover"
exec plasma-discover "\$@"
fi
APPSTREAM_EOF
chmod +x "$appstream_handler"
log_info "Created appstream handler: $appstream_handler"

    local appstream_handler_desktop="$desktop_dir/steamos-pamac-appstream-handler.desktop"
cat > "$appstream_handler_desktop" << HANDLER_DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=SteamOS Pamac AppStream Handler
NoDisplay=true
MimeType=x-scheme-handler/appstream;
Exec=${appstream_handler} %U
InitialPreference=10
HANDLER_DESKTOP_EOF
chmod 644 "$appstream_handler_desktop"
log_info "Created appstream handler desktop: $appstream_handler_desktop"

xdg-mime default steamos-pamac-appstream-handler.desktop x-scheme-handler/appstream 2>/dev/null || true
log_info "Registered appstream handler as default for x-scheme-handler/appstream"

rm -f "$HOME/.local/share/plasma/kickeractions/steamos-pamac-uninstall.desktop" 2>/dev/null || true

    if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
        log_info "Add '$bin_dir' to your PATH to use the CLI wrapper directly."
    fi
}

setup_post_install_hooks() {
    log_step "Setting up post-install hooks for desktop integration"

    local hook_script
    read -r -d '' hook_script <<'HOOK_EOF' || true
set -uo pipefail

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
STATE_DIR="/home/${current_user}/.local/share/steamos-pamac/${container_name}"
STATE_FILE="\$STATE_DIR/exported-apps.list"
EXPORT_LOG="\$STATE_DIR/export-hook.log"
EXPLICIT_FILE="\$(mktemp)"
NEW_STATE_FILE="\$(mktemp)"
echo "\$(date): Hook triggered" > "\$EXPORT_LOG"
mkdir -p "\$APP_DIR" "\$STATE_DIR"
trap 'rm -f "\$EXPLICIT_FILE" "\$NEW_STATE_FILE"' EXIT

pacman -Qeq > "\$EXPLICIT_FILE" 2>/dev/null || true

should_export_desktop() {
    local desktop_file="\$1"
    local app_name="\$2"
    local owner_pkg="\$3"

    [[ -f "\$desktop_file" ]] || return 1
    grep -qi '^NoDisplay=true' "\$desktop_file" && return 1
    grep -qi '^Hidden=true' "\$desktop_file" && return 1
    grep -qi '^TerminalOnly=true' "\$desktop_file" && return 1
    if grep -qi '^Type=' "\$desktop_file" && ! grep -qi '^Type=Application$' "\$desktop_file"; then
        return 1
    fi

    case "\$app_name" in
        "${container_name}"|distrobox*)
            return 1
            ;;
        pamac-installer|pamac-tray)
            return 1
            ;;
    esac

    [[ -n "\$owner_pkg" ]] || return 1
    grep -Fxq "\$owner_pkg" "\$EXPLICIT_FILE"
}

get_exec_binary() {
  local desktop_file="\$1"
  grep '^Exec=' "\$desktop_file" 2>/dev/null | head -1 | sed 's/^Exec=//' | sed 's/ .*//' | sed 's|^.*/||'
}

_fix_desktop_permissions() {
  local desktop_file="\$1"
  if [[ "\$(id -u)" -eq 0 ]]; then
    local _host_uid
    _host_uid="\$(id -u ${current_user} 2>/dev/null || echo 1000)"
    chown "\$_host_uid:\$_host_uid" "\$desktop_file" 2>/dev/null || true
  fi
  chmod 644 "\$desktop_file" 2>/dev/null || true
}

annotate_desktop() {
    local desktop_file="\$1"
    local app_name="\$2"
    local export_name="\$3"
    local owner_pkg="\$4"

    [[ -f "\$desktop_file" ]] || return 1

    _fix_desktop_permissions "\$desktop_file"
    cp -f "\$desktop_file" "\$desktop_file.bak" 2>/dev/null || true

  if [[ "\$app_name" == "org.manjaro.pamac.manager" ]]; then
    cat > "\$desktop_file" << PAMAC_DESKTOP
[Desktop Entry]
Type=Application
Name=Add/Remove Software (on ${container_name})
Comment=Manage packages inside the ${container_name} distrobox
Exec=distrobox enter ${container_name} -- pamac-manager-wrapper %U
Icon=system-software-install
Terminal=false
Categories=System;PackageManager;Settings;
Keywords=package;manager;software;arch;aur;
StartupNotify=true
StartupWMClass=pamac-manager
NoDisplay=false
DBusActivatable=false
Actions=uninstall;
X-SteamOS-Pamac-Managed=true
X-SteamOS-Pamac-Container=${container_name}
X-SteamOS-Pamac-SourceApp=pamac-manager
X-SteamOS-Pamac-SourceDesktop=org.manjaro.pamac.manager.desktop
X-SteamOS-Pamac-SourcePackage=pamac-aur

[Desktop Action uninstall]
Name=Uninstall Packages
Exec=/home/${current_user}/.local/bin/steamos-pamac-uninstall --desktop-file ${container_name}-org.manjaro.pamac.manager.desktop
Icon=edit-delete
PAMAC_DESKTOP
    _fix_desktop_permissions "\$desktop_file"
    return 0
  fi

local tmp_file
tmp_file="\$(mktemp)"
local existing_actions=""
{
local in_action=false
while IFS= read -r line || [[ -n "\$line" ]]; do
case "\$line" in
'X-SteamOS-Pamac-Managed='*) continue ;;
'X-SteamOS-Pamac-Container='*) continue ;;
'X-SteamOS-Pamac-SourceApp='*) continue ;;
'X-SteamOS-Pamac-SourceDesktop='*) continue ;;
'X-SteamOS-Pamac-SourcePackage='*) continue ;;
'Actions='*)
existing_actions="\${line#Actions=}"
continue
;;
'[Desktop Action uninstall]')
in_action=true
continue
;;
esac
 if \$in_action; then
 case "\$line" in
 'Name=Uninstall'|'Name=Uninstall '*|'Exec='*steamos-pamac-uninstall*|'Icon=edit-delete'|'['*)
 if [[ "\$line" == '['* ]]; then
 in_action=false
 printf '%s\n' "\$line"
 fi
 continue
 ;;
 esac
 fi
 if [[ "\$line" == '['Desktop\ Action* ]]; then
 in_action=true
 fi
 if \$in_action; then
 case "\$line" in
 'StartupWMClass='*) continue ;;
 esac
 fi
 printf '%s\n' "\$line"
done < "\$desktop_file"
} > "\$tmp_file"
mv "\$tmp_file" "\$desktop_file"

	local combined_actions=""
	if [[ -n "\$existing_actions" ]]; then
		local stripped="\${existing_actions%%;}"
		combined_actions="\${stripped};uninstall;"
	else
		combined_actions="uninstall;"
	fi

	desktop_basename="\$(basename "\$desktop_file")"

	# Insert Actions= key into [Desktop Entry] section (before first [Desktop Action...])
	# and append X-SteamOS markers + [Desktop Action uninstall] at the end
	local actions_inserted=false
	tmp_file="\$(mktemp)"
	{
		while IFS= read -r line || [[ -n "\$line" ]]; do
			if ! \$actions_inserted && [[ "\$line" == '[Desktop Action'* ]]; then
				printf 'Actions=%s\n' "\$combined_actions"
				printf 'X-SteamOS-Pamac-Managed=true\n'
				printf 'X-SteamOS-Pamac-Container=%s\n' "${container_name}"
				printf 'X-SteamOS-Pamac-SourceApp=%s\n' "\$export_name"
				printf 'X-SteamOS-Pamac-SourceDesktop=%s.desktop\n' "\$app_name"
				printf 'X-SteamOS-Pamac-SourcePackage=%s\n' "\$owner_pkg"
				printf '\n'
				actions_inserted=true
			fi
			printf '%s\n' "\$line"
		done < "\$desktop_file"

		if ! \$actions_inserted; then
			printf 'Actions=%s\n' "\$combined_actions"
			printf 'X-SteamOS-Pamac-Managed=true\n'
			printf 'X-SteamOS-Pamac-Container=%s\n' "${container_name}"
			printf 'X-SteamOS-Pamac-SourceApp=%s\n' "\$export_name"
			printf 'X-SteamOS-Pamac-SourceDesktop=%s.desktop\n' "\$app_name"
			printf 'X-SteamOS-Pamac-SourcePackage=%s\n' "\$owner_pkg"
		fi

		printf '\n[Desktop Action uninstall]\nName=Uninstall\nExec=/home/${current_user}/.local/bin/steamos-pamac-uninstall --desktop-file %s\nIcon=edit-delete\n' "\$desktop_basename"
	} > "\$tmp_file"
	mv "\$tmp_file" "\$desktop_file"
  _fix_desktop_permissions "\$desktop_file"
}

run_distrobox_export() {
  local app_name="\$1"
  local fallback_name="\${2:-}"

  local xdg_data_dirs="\${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  local xdg_data_home="\${XDG_DATA_HOME:-/home/${current_user}/.local/share}"
  local user_path="\${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

  _do_export() {
    local name="\$1"
    if [[ "\$(id -u)" -eq 0 ]]; then
		sudo -Hu "${current_user}" \
			env HOME="/home/${current_user}" \
			XDG_DATA_DIRS="\$xdg_data_dirs" \
			XDG_DATA_HOME="\$xdg_data_home" \
			PATH="\$user_path" \
			distrobox-export --container "${container_name}" --app "\$name" 2>/dev/null
    else
		export HOME="/home/${current_user}"
		export XDG_DATA_DIRS="\$xdg_data_dirs"
		export XDG_DATA_HOME="\$xdg_data_home"
		distrobox-export --container "${container_name}" --app "\$name" 2>/dev/null
    fi
  }

  if _do_export "\$app_name"; then
    return 0
  fi

  if [[ -n "\$fallback_name" && "\$fallback_name" != "\$app_name" ]]; then
    echo "distrobox-export --app \$app_name failed, trying fallback: \$fallback_name" >> "\$EXPORT_LOG" 2>/dev/null
    if _do_export "\$fallback_name"; then
      return 0
    fi
  fi

  return 1
}

if command -v distrobox-export >/dev/null 2>&1; then
  exported=0
  for desktop in /usr/share/applications/*.desktop; do
    [[ -f "\$desktop" ]] || continue
    app_name="\$(basename "\$desktop" .desktop)"
    export_name="\$app_name"
    [[ "\$app_name" == "org.manjaro.pamac.manager" ]] && export_name="pamac-manager"
    owner_pkg="\$(pacman -Qoq "\$desktop" 2>/dev/null || true)"
    should_export_desktop "\$desktop" "\$app_name" "\$owner_pkg" || continue

  exec_binary="\$(get_exec_binary "\$desktop")"

  if run_distrobox_export "\$export_name" "\$exec_binary"; then
    host_desktop=""
    for candidate in "\$APP_DIR/${container_name}-\${app_name}.desktop" "\$APP_DIR/${container_name}-\${export_name}.desktop" "\$APP_DIR/${container_name}-\${exec_binary}.desktop"; do
      if [[ -f "\$candidate" ]]; then
        _fix_desktop_permissions "\$candidate"
        host_desktop="\$candidate"
        break
      fi
    done
    if [[ -z "\$host_desktop" ]]; then
      host_desktop="\$(find "\$APP_DIR" -maxdepth 1 -name "${container_name}-*.desktop" -newer "\$EXPLICIT_FILE" -print -quit 2>/dev/null)"
      if [[ -n "\$host_desktop" ]]; then
        _fix_desktop_permissions "\$host_desktop"
      fi
    fi
    if [[ -n "\$host_desktop" && -f "\$host_desktop" ]]; then
      annotate_desktop "\$host_desktop" "\$app_name" "\$export_name" "\$owner_pkg" || true
        printf '%s\n' "\$host_desktop" >> "\$NEW_STATE_FILE"
      fi
      exported=\$((exported + 1))
    else
      echo "Failed to export \$app_name (tried: \$export_name, \$exec_binary)" >> "\$EXPORT_LOG"
    fi
  done
  echo "\$(date): Exported \$exported apps" >> "\$EXPORT_LOG"
fi

rm -f "\$APP_DIR/${container_name}.desktop" 2>/dev/null || true

for f in "\$APP_DIR"/${container_name}-*.desktop; do
  [[ -f "\$f" ]] || continue
  _fix_desktop_permissions "\$f"
done

if [[ -f "\$STATE_FILE" ]]; then
  while IFS= read -r old_export; do
    [[ -n "\$old_export" ]] || continue
    if [[ ! -f "\$old_export" ]]; then
      echo "Removing state entry for missing file: \$old_export" >> "\$EXPORT_LOG"
      continue
    fi
    local_source_pkg="\$(grep '^X-SteamOS-Pamac-SourcePackage=' "\$old_export" 2>/dev/null | cut -d= -f2-)"
    if [[ -n "\$local_source_pkg" ]]; then
      if ! pacman -Q "\$local_source_pkg" >/dev/null 2>&1; then
        echo "Removing stale export (package \$local_source_pkg uninstalled): \$old_export" >> "\$EXPORT_LOG"
        rm -f "\$old_export"
        continue
      fi
      if ! grep -Fxq "\$local_source_pkg" "\$EXPLICIT_FILE" 2>/dev/null; then
        echo "Removing dependency export (package \$local_source_pkg not explicitly installed): \$old_export" >> "\$EXPORT_LOG"
        rm -f "\$old_export"
        continue
      fi
    fi
    printf '%s\n' "\$old_export" >> "\$NEW_STATE_FILE"
  done < "\$STATE_FILE"
fi

while IFS= read -r existing_export; do
  [[ -n "\$existing_export" ]] || continue
  if grep -q '^X-SteamOS-Pamac-SourceApp=pamac-manager$' "\$existing_export" 2>/dev/null; then
    echo "Preserving pamac-manager export: \$existing_export" >> "\$EXPORT_LOG"
    printf '%s\n' "\$existing_export" >> "\$NEW_STATE_FILE"
    continue
  fi
  existing_source_pkg="\$(grep '^X-SteamOS-Pamac-SourcePackage=' "\$existing_export" 2>/dev/null | cut -d= -f2-)"
  if [[ -n "\$existing_source_pkg" ]]; then
    if ! pacman -Q "\$existing_source_pkg" >/dev/null 2>&1; then
      echo "Removing orphaned export (package \$existing_source_pkg uninstalled): \$existing_export" >> "\$EXPORT_LOG"
      rm -f "\$existing_export"
      continue
    fi
    if ! grep -Fxq "\$existing_source_pkg" "\$EXPLICIT_FILE" 2>/dev/null; then
      echo "Removing dependency export (package \$existing_source_pkg not explicitly installed): \$existing_export" >> "\$EXPORT_LOG"
      rm -f "\$existing_export"
      continue
    fi
  fi
  if ! grep -Fxq "\$existing_export" "\$NEW_STATE_FILE" 2>/dev/null; then
    echo "Removing stale container export: \$existing_export" >> "\$EXPORT_LOG"
    rm -f "\$existing_export"
  fi
done < <(find "\$APP_DIR" -maxdepth 1 -type f -name "${container_name}-*.desktop" ! -name "${container_name}.desktop" 2>/dev/null | sort)

sort -u "\$NEW_STATE_FILE" > "\$STATE_FILE"

if command -v update-desktop-database >/dev/null 2>&1 && [[ -d "\$APP_DIR" ]]; then
update-desktop-database "\$APP_DIR" 2>/dev/null || true
fi

KICKERACTION_DIR="/home/${current_user}/.local/share/plasma/kickeractions"
rm -f "\$KICKERACTION_DIR/steamos-pamac-uninstall.desktop" 2>/dev/null
echo "\$(date): Removed kickeraction file (using appstream intercept instead)" >> "\$EXPORT_LOG"

APPSTREAM_HANDLER_DIR="/home/${current_user}/.local/share/applications"
APPSTREAM_HANDLER_DESKTOP="\$APPSTREAM_HANDLER_DIR/steamos-pamac-appstream-handler.desktop"
APPSTREAM_HANDLER_BIN="/home/${current_user}/.local/bin/steamos-pamac-appstream-handler"

if [[ ! -f "\$APPSTREAM_HANDLER_DESKTOP" ]]; then
mkdir -p "\$APPSTREAM_HANDLER_DIR"
cat > "\$APPSTREAM_HANDLER_DESKTOP" << HANDLER_EOF
[Desktop Entry]
Type=Application
Name=SteamOS Pamac AppStream Handler
NoDisplay=true
MimeType=x-scheme-handler/appstream;
Exec=\$APPSTREAM_HANDLER_BIN %U
InitialPreference=10
HANDLER_EOF
echo "\$(date): Deployed appstream handler desktop file" >> "\$EXPORT_LOG"
fi

if [[ -f "\$APPSTREAM_HANDLER_BIN" ]]; then
chmod +x "\$APPSTREAM_HANDLER_BIN" 2>/dev/null
fi
HOOKSCRIPT

chmod +x "/usr/local/bin/distrobox-export-hook.sh"
echo "Post-install hook configured."
HOOK_EOF

    if ! echo "$hook_script" | exec_container_pipe "post-install-hooks" "$CURRENT_USER" "$CONTAINER_NAME"; then
        log_warn "Failed to set up post-install hooks. Newly installed apps may not auto-appear in menu."
    fi
}

export_existing_apps() {
  log_step "Exporting existing desktop applications from container"

  if distrobox-enter "$CONTAINER_NAME" -- env XDG_DATA_DIRS="/usr/local/share:/usr/share" XDG_DATA_HOME="/home/${CURRENT_USER}/.local/share" /usr/local/bin/distrobox-export-hook.sh >> "$LOG_FILE" 2>&1; then
    log_success "Existing explicit desktop applications exported to host menu."
  else
    log_warn "Some applications could not be exported to host."
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

  run_pre_flight_checks || exit 1
  ensure_podman
  detect_init_support

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${BOLD}${BLUE}Steam Deck Pamac Setup v${SCRIPT_VERSION}${NC} ${BOLD}${YELLOW}(DRY RUN)${NC}"
        echo
        log_success "Pre-flight checks passed. Dry run complete."
        log_info "No actual changes were made."
        exit 0
    fi

    echo -e "${BOLD}${BLUE}Steam Deck Pamac Setup v${SCRIPT_VERSION}${NC}"
    echo

    log_info "Checking available system resources..."
    check_memory_ok 262144 "container creation" || {
        log_warn "Low memory detected. Some operations may be skipped to avoid OOM kills."
        if [[ "$ENABLE_GAMING_PACKAGES" == "true" ]]; then
            log_warn "Disabling gaming packages to conserve memory."
            ENABLE_GAMING_PACKAGES="false"
        fi
    }

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
        "stopping"|"paused"|"dead"|"exited"|"stopped"|"improper")
            if [[ "$CONTAINER_HAS_INIT" == "false" ]] && [[ "$existing_status" == "exited" || "$existing_status" == "stopped" ]]; then
                log_info "Container in '$existing_status' state (normal for non-init). Starting..."
                container_start 2>/dev/null || true
                sleep 3
                if container_is_usable; then
                    log_success "Using existing container (restarted): $CONTAINER_NAME"
                else
                    log_warn "Container not usable after restart, recreating..."
                    force_remove_container "$CONTAINER_NAME"
                    sleep 2
                    create_container || exit 1
                fi
        else
          log_warn "Container in '$existing_status' state - removing and recreating"
          force_remove_container "$CONTAINER_NAME"
          sleep 2
          create_container || exit 1
        fi
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

    check_memory_ok 262144 "base setup" || log_warn "Low memory may cause OOM kills during base setup."

	if ! configure_container_base; then
		log_warn "Container base setup had errors. Checking container health..."
		_ensure_healthy_or_recreate "base setup recovery" || exit 1
	fi

	_ensure_healthy_or_recreate "before critical helpers check" || exit 1
	ensure_critical_helpers

	_ensure_healthy_or_recreate "before mirror optimization" || exit 1
	optimize_pacman_mirrors

	_ensure_healthy_or_recreate "before multilib setup" || exit 1
	configure_multilib

	_ensure_healthy_or_recreate "after base setup" || exit 1

	check_memory_ok 524288 "AUR helper build" || log_warn "Low memory may cause OOM kills during yay compilation."

	if ! install_aur_helper; then
		if _ensure_healthy_or_recreate "aur helper recovery"; then
			log_info "Retrying AUR helper install..."
			install_aur_helper || exit 1
		else
			exit 1
		fi
	fi

	_ensure_healthy_or_recreate "after aur helper" || exit 1

	if ! install_pamac; then
		if _ensure_healthy_or_recreate "pamac install recovery"; then
			log_info "Retrying Pamac install..."
			install_pamac || exit 1
		else
			exit 1
		fi
	fi

	_ensure_healthy_or_recreate "after pamac install" || exit 1
ensure_critical_helpers

install_gaming_packages

    export_pamac_to_host

    setup_post_install_hooks
    export_existing_apps

    configure_ssh_environment

    show_completion_message
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
