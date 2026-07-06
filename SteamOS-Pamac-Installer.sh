#!/bin/bash

set -euo pipefail
set -E

# ERR trap for better error tracing in deeply nested calls (subshells, pipes, sub-functions)
_err_trap() {
    local _exit_code=$?
    local _line=$1
    local _cmd=$2
    log_error "Error at line $_line (exit $_code): $_cmd"
}
trap '_err_trap $LINENO "$BASH_COMMAND"' ERR

# Heredoc quoting convention:
#   <<'EOF'  — no host variable expansion; content runs inside container
#   <<EOF    — host variables expand at write-time; use \$ for literal $

readonly SCRIPT_VERSION="5.2.1"
readonly DEFAULT_CONTAINER_NAME="arch-pamac"
readonly LOG_FILE="$HOME/distrobox-pamac-setup.log"
readonly REQUIRED_TOOLS=("distrobox")
CONTAINER_HAS_INIT="unknown"

readonly ARCHLINUX_IMAGE="${ARCHLINUX_IMAGE:-archlinux:base-20260628.0.549485}"

# Track temp files for cleanup on interrupt
_TEMP_FILES=()
_cleanup_temp_files() {
    for f in "${_TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null || true
    done
}
CONTAINER_NAME="${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}"

CURRENT_USER=$(whoami)

ENABLE_MULTILIB="${ENABLE_MULTILIB:-true}"
ENABLE_BUILD_CACHE="${ENABLE_BUILD_CACHE:-true}"
ENABLE_GAMING_PACKAGES="${ENABLE_GAMING_PACKAGES:-false}"
ENABLE_EXTRA_REPOS="${ENABLE_EXTRA_REPOS:-true}"
FORCE_REBUILD="${FORCE_REBUILD:-false}"
OPTIMIZE_MIRRORS="${OPTIMIZE_MIRRORS:-true}"
ALLOW_SUDO_FALLBACK="${ALLOW_SUDO_FALLBACK:-false}"

: "${DISTROBOX_CONTAINER_MANAGER:=podman}"

DRY_RUN="${DRY_RUN:-false}"
CHECK_ONLY="${CHECK_ONLY:-false}"
STATUS="${STATUS:-false}"
UNINSTALL="${UNINSTALL:-false}"
UPDATE="${UPDATE:-false}"
EXPORT_ONLY="${EXPORT_ONLY:-false}"
LOG_LEVEL="${LOG_LEVEL:-normal}"
PAMAC_VERSION="${PAMAC_VERSION:-}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

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
        echo "Features: MULTILIB=$ENABLE_MULTILIB GAMING=$ENABLE_GAMING_PACKAGES EXTRA_REPOS=$ENABLE_EXTRA_REPOS BUILD_CACHE=$ENABLE_BUILD_CACHE OPTIMIZE_MIRRORS=$OPTIMIZE_MIRRORS NON_INTERACTIVE=$NON_INTERACTIVE"
        echo "=========================================="
    } > "$LOG_FILE"

    trap 'exit_code=$?; _cleanup_temp_files; echo "=== Run finished: $(date) - Exit: $exit_code ===" >> "$LOG_FILE"' EXIT
}

_log() {
    local level="$1" color="$2" message="$3"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    local plain_message
    plain_message=$(printf '%s' "$message" | sed 's/\x1B\[[0-9;]*[A-Za-z]//g') || plain_message="$message"

    echo "[$timestamp] $level: $plain_message" >> "$LOG_FILE"

    case "$LOG_LEVEL" in
        "quiet") if [[ "$level" == "ERROR" ]]; then printf '%b\n' "${color}${message}${NC}"; fi ;;
        "normal") if [[ "$level" != "DEBUG" ]]; then printf '%b\n' "${color}${message}${NC}"; fi ;;
        "verbose") printf '%b\n' "${color}${message}${NC}" ;;
    esac
}

log_step()   { _log "STEP"    "$BLUE"   "\n${BOLD}==> $1${NC}"; }
log_info()   { _log "INFO"    ""        "$1"; }
log_success(){ _log "SUCCESS" "$GREEN"  "✓ $1"; }
log_warn()   { _log "WARN"    "$YELLOW" "⚠ $1"; }
log_error()  { _log "ERROR"   "$RED"    "✗ $1"; }
log_debug()  { _log "DEBUG"   ""        "$1"; }

_filter_verbose_output() {
    # Filter verbose container output to avoid overwhelming the user.
    # Always pass through: errors, warnings, key operation markers, final status lines.
    # Filter out: repetitive download progress, package resolution noise, blank lines.
    grep -v -E '^\s*$|^resolving dependencies|^looking for conflicting|^checking (keyring|package|group|database|^$)|^::(synchronizing|debug:|warning:|info:)|^:: Proceed|^:: Run|^warning:.*downgrading|^warning:.*removing' || cat
}

run_command() {
    log_debug "Executing: $*"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY RUN] Would execute: $*"
        return 0
    fi

    local status=0
    set +e
    if [[ "$LOG_LEVEL" == "verbose" ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE" | _filter_verbose_output; status=${PIPESTATUS[0]}
    else
        "$@" >> "$LOG_FILE" 2>&1; status=$?
    fi
    set -e

    [[ $status -ne 0 ]] && log_debug "Command failed with exit code: $status"
    return "$status"
}

container_runtime() {
    local mgr="${DISTROBOX_CONTAINER_MANAGER:-podman}"
    if [[ "$mgr" == "docker" ]]; then
        docker "$@"
    else
        podman "$@"
    fi
}

# Use sudo only for privileged operations (create, rm, system) when rootless is broken.
# SECURITY: Running as host root significantly weakens container isolation.
# PODMAN_SUDO_FALLBACK is only set by ensure_podman() when --allow-sudo-fallback is passed.
_SUDO_VERIFIED=""
container_runtime_privileged() {
    local mgr="${DISTROBOX_CONTAINER_MANAGER:-podman}"
    if [[ "${PODMAN_SUDO_FALLBACK:-}" == "true" ]]; then
        # Defense-in-depth: refuse if explicit opt-in wasn't given
        if [[ "$ALLOW_SUDO_FALLBACK" != "true" ]]; then
            log_error "PODMAN_SUDO_FALLBACK is set but --allow-sudo-fallback was not passed. Refusing sudo."
            container_runtime "$@"
            return $?
        fi
        if [[ "$_SUDO_VERIFIED" != "ok" ]]; then
            if sudo -n true 2>/dev/null; then
                _SUDO_VERIFIED="ok"
            else
                log_warn "sudo -n true failed (password may be required). Falling back to rootless podman."
                unset PODMAN_SUDO_FALLBACK
                container_runtime "$@"
                return $?
            fi
        fi
        if [[ "$mgr" == "docker" ]]; then
            sudo docker "$@"
        else
            sudo podman "$@"
        fi
    else
        container_runtime "$@"
    fi
}

container_root_exec() {
  if ! container_is_usable; then
    container_start 2>/dev/null || true
    if ! container_is_usable; then
      log_warn "Container not usable before root exec. Attempting anyway..."
    fi
  fi
  container_runtime_privileged exec -i -u 0 -e HOME="/root" "$CONTAINER_NAME" "$@"
}

container_user_exec() {
  if ! container_is_usable; then
    container_start 2>/dev/null || true
    if ! container_is_usable; then
      log_warn "Container not usable before user exec. Attempting anyway..."
    fi
  fi
  container_runtime_privileged exec -i -u "$CURRENT_USER" \
    -e HOME="/home/${CURRENT_USER}" \
    -e XDG_DATA_DIRS="/usr/local/share:/usr/share" \
    -e XDG_DATA_HOME="/home/${CURRENT_USER}/.local/share" \
    -e PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$CONTAINER_NAME" "$@"
}

container_cp_from() {
    local src="$1" dst="$2"
    log_debug "Copying from container: $src -> $dst"
    if ! container_is_usable; then
        container_start 2>/dev/null || true
    fi
    if container_runtime_privileged cp "$CONTAINER_NAME:$src" "$dst" 2>/dev/null; then
        log_debug "Copied $src from container."
        return 0
    else
        log_debug "Failed to copy $src from container."
        return 1
    fi
}

container_start() {
  container_runtime_privileged start "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
}

container_is_running() {
  local _running
  _running=$(container_runtime_privileged inspect "$CONTAINER_NAME" --format '{{.State.Running}}' 2>/dev/null || echo "false")
  [[ "$_running" == "true" ]]
}

container_get_status() {
  container_runtime_privileged inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "not_found"
}

container_is_usable() {
  container_start 2>/dev/null || true
  local _output
  _output=$(timeout 15 container_runtime_privileged exec -i -u 0 -e HOME="/root" "$CONTAINER_NAME" bash -c "echo ok" </dev/null 2>/dev/null || echo "")
  [[ "$_output" == *"ok"* ]]
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
				if ! force_remove_container "$CONTAINER_NAME"; then
					log_warn "force_remove_container may not have fully removed '$CONTAINER_NAME'. Checking..."
				fi
				sleep 1
				if container_runtime_privileged inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					log_error "Container '$CONTAINER_NAME' still exists after force_remove. Manual intervention required."
					log_info "Try: podman rm -f $CONTAINER_NAME && distrobox rm -f $CONTAINER_NAME"
					return 1
				fi
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
        if [[ ${_RECREATE_COUNT:-0} -ge ${_MAX_RECREATES:-2} ]]; then
            log_error "Container recreated $_MAX_RECREATES times without success. Aborting."
            _RECREATE_COUNT=0
            return 1
        fi
        _RECREATE_COUNT=$((_RECREATE_COUNT + 1))
        log_info "Container signaled for recreation ($desc), attempt $_RECREATE_COUNT/$_MAX_RECREATES. Recreating..."
        if ! force_remove_container "$CONTAINER_NAME"; then
            log_warn "force_remove_container returned non-zero. Container may still exist."
            if container_runtime_privileged inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
                log_error "Container '$CONTAINER_NAME' still exists after force removal. Cannot recreate."
                _RECREATE_COUNT=0
                return 1
            fi
        fi
        sleep 2
        local saved_guard="${_CREATE_RECREATION_GUARD:-}"
        unset _CREATE_RECREATION_GUARD
        if ! create_container; then
            _CREATE_RECREATION_GUARD="$saved_guard"
            log_error "Failed to recreate container after '$desc' recovery."
            return 1
        fi
        _CREATE_RECREATION_GUARD="$saved_guard"
        if ! container_is_usable; then
            log_error "Container recreated but not usable after '$desc' recovery."
            return 1
        fi
        log_success "Container recreated successfully after '$desc' issue."
        _RECREATE_COUNT=0
        return 0
    else
        _RECREATE_COUNT=0
        return 1
    fi
}

force_remove_container() {
  local name="$1"

  if ! container_runtime_privileged inspect "$name" >/dev/null 2>&1; then
    return
  fi

  local status
  status=$(container_runtime_privileged inspect "$name" --format '{{.State.Status}}' 2>/dev/null || echo "not_found")
  if [[ "$status" == "not_found" ]]; then
    return
  fi

  if [[ "$status" == "stopping" || "$status" == "stopped" || "$status" == "improper" ]]; then
    log_debug "Container '$name' in '$status' state - killing container processes"
    local pid
    pid=$(container_runtime_privileged inspect "$name" --format '{{.State.Pid}}' 2>/dev/null || echo "0")
    if [[ "$pid" -gt 0 ]]; then
      kill -9 "$pid" 2>/dev/null || true
    fi
    local conmon_pid_file
    conmon_pid_file=$(container_runtime_privileged inspect "$name" --format '{{.ConmonPidFile}}' 2>/dev/null || true)
    if [[ -n "$conmon_pid_file" && -f "$conmon_pid_file" ]]; then
      local cpid
      cpid=$(cat "$conmon_pid_file" 2>/dev/null || echo "0")
      if [[ "$cpid" -gt 0 ]]; then
        kill -9 "$cpid" 2>/dev/null || true
      fi
    fi
    sleep 1
  fi

  container_runtime_privileged rm -f "$name" 2>/dev/null || true

  if container_runtime_privileged inspect "$name" >/dev/null 2>&1; then
    log_debug "podman rm -f did not remove '$name'. Retrying with --time 0 (immediate SIGKILL)..."
    container_runtime_privileged rm -f --time 0 "$name" 2>/dev/null || true
  fi

	if container_runtime_privileged inspect "$name" >/dev/null 2>&1; then
		log_warn "podman rm -f --time 0 still failed for '$name'. The container engine may be corrupted."
		log_warn ""
		log_warn "IMPORTANT: A full 'podman system reset --force' would destroy ALL containers,"
		log_warn "images, and volumes — not just this one. This script will NOT do that"
		log_warn "automatically because it can destroy other distroboxes and podman workloads."
		log_warn ""

		local other_containers
		other_containers=$(container_runtime_privileged ps -a --format '{{.Names}}' 2>/dev/null | grep -v "^${name}$" || true)
		if [[ -n "$other_containers" ]]; then
			log_warn "Other containers that would be destroyed by 'podman system reset':"
			while IFS= read -r oc; do
				log_warn "  - $oc"
			done <<< "$other_containers"
			log_warn ""
		fi

		log_warn "Manual recovery options (in order of safety):"
		log_warn "  1. podman rm -f --time 0 '$name'  (immediate SIGKILL, no grace period)"
		log_warn "  2. podman stop '$name' && podman rm '$name'  (stop then remove)"
		log_warn "  3. systemctl --user restart podman  (restart the engine)"
		log_warn "  4. podman system reset --force     (DESTRUCTIVE: removes ALL containers)"

		if [[ "$NON_INTERACTIVE" == "true" ]]; then
			log_warn "Non-interactive mode (--non-interactive) — skipping podman system reset to avoid data loss."
			log_info "Run this script without --non-interactive to approve, or try: podman system reset --force"
			return
		fi

		if [[ -t 0 ]]; then
			echo -ne "${RED}${BOLD}Type 'reset' to run 'podman system reset --force' (destroys ALL containers), or anything else to skip: ${NC}" >&2
			local cleanup_confirm
			read -r cleanup_confirm
			if [[ "$cleanup_confirm" != "reset" ]]; then
				log_warn "User declined podman system reset. Skipping."
				log_info "Try manually: podman rm -f '$name' or podman system reset --force"
				return
			fi
		else
			log_warn "Non-interactive session — skipping podman system reset to avoid data loss."
			log_info "Run this script interactively to approve, or try: podman system reset --force"
			return
		fi

		log_warn "Running 'podman system reset --force' — this will destroy ALL containers, images, and volumes."
		container_runtime_privileged system reset --force 2>&1 | while IFS= read -r line; do
			log_warn "  $line"
		done || true

		if container_runtime_privileged inspect "$name" >/dev/null 2>&1; then
			log_error "Container '$name' still exists after system reset. Manual intervention required."
			log_info "Try: sudo podman rm -f '$name' or reboot the system."
			return 1
		fi
  fi

  if container_runtime_privileged inspect "$name" >/dev/null 2>&1; then
    return 1
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

    return 0
}

check_memory_ok() {
    local min_avail_kb="${1:-524288}"
    local desc="${2:-operation}"
    local critical_kb="${3:-262144}"

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

    if [[ "$mem_avail_kb" -lt "$critical_kb" ]]; then
        local mem_avail_mb=$(( mem_avail_kb / 1024 ))
        local critical_mb=$(( critical_kb / 1024 ))
        log_error "Critically low memory: ${mem_avail_mb}MB available (minimum ${critical_mb}MB required for $desc)."
        log_error "Aborting to prevent OOM kills and data loss."
        return 1
    fi

    if [[ "$mem_avail_kb" -lt "$min_avail_kb" ]]; then
        local mem_avail_mb=$(( mem_avail_kb / 1024 ))
        local min_avail_mb=$(( min_avail_kb / 1024 ))
        log_warn "Low available memory: ${mem_avail_mb}MB (need at least ${min_avail_mb}MB for $desc)."
        log_warn "The operation may be killed by OOM. Consider closing other applications."
    else
        log_debug "Memory check OK: $(( mem_avail_kb / 1024 ))MB available for $desc."
    fi

    return 0
}

check_battery_power() {
    local power_supply_dir="/sys/class/power_supply"
    if [[ ! -d "$power_supply_dir" ]]; then
        log_debug "No /sys/class/power_supply directory found, skipping battery check."
        return 0
    fi

    local battery_found=false
    local low_battery=false

    for bat_dir in "$power_supply_dir"/*/; do
        local type_file="$bat_dir/type"
        [[ -f "$type_file" ]] || continue

        local ps_type
        ps_type=$(cat "$type_file" 2>/dev/null || true)
        [[ "$ps_type" == "Battery" ]] || continue

        battery_found=true
        local bat_name
        bat_name=$(basename "$bat_dir")

        local capacity_file="$bat_dir/capacity"
        local status_file="$bat_dir/status"
        local capacity=-1
        local status="Unknown"

        if [[ -f "$capacity_file" ]]; then
            capacity=$(cat "$capacity_file" 2>/dev/null || echo "-1")
        fi
        if [[ -f "$status_file" ]]; then
            status=$(cat "$status_file" 2>/dev/null || echo "Unknown")
        fi

        if [[ "$capacity" -lt 0 || "$capacity" -gt 100 ]]; then
            log_debug "Battery '$bat_name': capacity unreadable ($capacity%), skipping."
            continue
        fi

        log_debug "Battery '$bat_name': ${capacity}% (${status})"

        if [[ "$capacity" -lt 20 && "$status" != "Charging" && "$status" != "Full" ]]; then
            low_battery=true
            log_warn "Battery '${bat_name}' is at ${capacity}% (${status})."
        fi
    done

    if [[ "$battery_found" == "false" ]]; then
        log_debug "No batteries detected (desktop/AC system). Skipping battery check."
        return 0
    fi

    if [[ "$low_battery" == "true" ]]; then
        log_warn "Battery is below 20% and not charging. Compiling yay and parsing"
        log_warn "heavy AUR packages can drain the battery quickly. Connect a"
        log_warn "charger or ensure the system is plugged in before continuing."
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            log_warn "Non-interactive mode (--non-interactive) — continuing despite low battery."
        elif [[ -t 0 ]]; then
            echo -ne "${YELLOW}${BOLD}Continue with low battery? (y/N): ${NC}" >&2
            local bat_confirm
            read -r bat_confirm
            if [[ "$bat_confirm" != "y" && "$bat_confirm" != "Y" ]]; then
                log_info "Aborted by user due to low battery."
                return 1
            fi
        else
            log_warn "Non-interactive session — continuing despite low battery."
        fi
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

    if command -v podman >/dev/null 2>&1; then
        local subuid_ok=true
        if ! grep -q "^$(whoami):" /etc/subuid 2>/dev/null; then
            log_warn "No subuid mapping for $(whoami). Rootless podman may fail."
            log_info "Fix: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(whoami)"
            subuid_ok=false
        fi
        if ! grep -q "^$(whoami):" /etc/subgid 2>/dev/null; then
            log_warn "No subgid mapping for $(whoami). Rootless podman may fail."
            log_info "Fix: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(whoami)"
            subuid_ok=false
        fi
        if [[ "$subuid_ok" == "true" ]]; then
            log_success "subuid/subgid mappings present."
        fi

        if [[ -z "${XDG_RUNTIME_DIR:-}" ]] || [[ ! -d "${XDG_RUNTIME_DIR:-/nonexistent}" ]]; then
            log_warn "XDG_RUNTIME_DIR is unset or missing. Rootless podman may fail."
            log_info "Fix: sudo loginctl enable-linger $(whoami), then log out and back in."
        fi
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
    log_step "Attempting rootless podman repair..."

    # Step 1: Check and fix XDG_RUNTIME_DIR (required for rootless podman socket)
    local runtime_dir="${XDG_RUNTIME_DIR:-}"
    if [[ -z "$runtime_dir" ]]; then
        runtime_dir="/run/user/$(id -u)"
        export XDG_RUNTIME_DIR="$runtime_dir"
        log_warn "XDG_RUNTIME_DIR was unset. Set to: $runtime_dir"
    fi
    if [[ ! -d "$runtime_dir" ]]; then
        log_warn "XDG_RUNTIME_DIR ($runtime_dir) does not exist. Creating..."
        mkdir -p "$runtime_dir" 2>/dev/null || true
        chmod 0700 "$runtime_dir" 2>/dev/null || true
    fi
    if [[ ! -w "$runtime_dir" ]]; then
        log_error "XDG_RUNTIME_DIR ($runtime_dir) is not writable."
        log_info "This usually means your user session is not properly set up."
        log_info "Try: loginctl enable-linger $(whoami)"
        log_info "Or log out and back in to regenerate the user session."
    fi

    # Step 2: Check subuid/subgid mappings (required for rootless container UIDs)
    local subuid_entry subgid_entry
    subuid_entry=$(grep "^$(whoami):" /etc/subuid 2>/dev/null || true)
    subgid_entry=$(grep "^$(whoami):" /etc/subgid 2>/dev/null || true)
    if [[ -z "$subuid_entry" ]]; then
        log_warn "No subuid mapping found for $(whoami) in /etc/subuid."
        log_info "Rootless podman needs subuid/subgid mappings to run containers."
        log_info "To fix: add to /etc/subuid:  $(whoami):100000:65536"
        log_info "And:     to /etc/subgid:  $(whoami):100000:65536"
        log_info "Then run: podman system reset --force && podman pull $ARCHLINUX_IMAGE"
        log_info "On SteamOS, subuid/subgid are usually created automatically when podman is installed."
        log_info "If missing, try: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(whoami)"
    else
        log_debug "subuid entry: $subuid_entry"
        log_debug "subgid entry: $subgid_entry"
    fi

    # Step 3: Start podman socket
    log_info "Checking rootless podman socket..."
    local socket_path="${runtime_dir}/podman/podman.sock"
    if [[ -S "$socket_path" ]]; then
        log_debug "Podman socket exists at $socket_path"
    else
        log_warn "Podman socket not found. Trying to start podman socket..."
        if systemctl --user start podman.socket 2>/dev/null; then
            log_info "Started podman user socket."
            sleep 2
        else
            log_debug "systemctl --user start podman.socket failed (may not have systemd user session)."
        fi
    fi

    if podman info >/dev/null 2>&1; then
        log_success "Podman is now functional."
        return 0
    fi

    # Step 4: Clean stale lock files
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

    # Step 5: Fix storage directory permissions
    log_info "Checking storage directory permissions..."
    if [[ -d "$podman_root" ]]; then
        local storage_ok=true
        # Check if key subdirectories are accessible
        for subdir in "$podman_root"/{overlay,vfs-images,vfs-layers,db} tmp; do
            if [[ -d "$subdir" ]] && [[ ! -w "$subdir" ]]; then
                log_warn "Storage subdirectory not writable: $subdir"
                storage_ok=false
            fi
        done
        if [[ "$storage_ok" == "false" ]]; then
            log_info "Fixing storage directory permissions..."
            chmod -R u+rwX "$podman_root" 2>/dev/null || true
            sleep 1
            if podman info >/dev/null 2>&1; then
                log_success "Podman recovered after permission fix."
                return 0
            fi
        fi
    fi

    # Step 6: Check for corrupted storage by examining the database
    log_info "Checking podman storage database integrity..."
    local storage_conf="$podman_root/storage.conf"
    local bolt_db="$podman_root/db/sqlite/podman-true.db"
    if [[ -f "$bolt_db" ]]; then
        local db_size
        db_size=$(stat -c%s "$bolt_db" 2>/dev/null || echo "0")
        if [[ "$db_size" -eq 0 ]]; then
            log_warn "Podman database file is empty (0 bytes). Removing to force rebuild..."
            rm -f "$bolt_db" 2>/dev/null || true
            rm -f "${bolt_db}"-* 2>/dev/null || true
            sleep 1
            if podman info >/dev/null 2>&1; then
                log_success "Podman recovered after removing empty database."
                return 0
            fi
        fi
    fi

    # Step 7: System reset (destructive, requires user confirmation)
    log_warn "Podman database may be corrupted. A full system reset is required but is DESTRUCTIVE."
    log_warn "WARNING: 'podman system reset --force' will remove ALL containers, images, and volumes — not just the Pamac container. Any other distroboxes or podman workloads will be lost."
    local existing_containers
    existing_containers=$(podman ps -aq 2>/dev/null || true)
    local container_count=0
    if [[ -n "$existing_containers" ]]; then
        container_count=$(echo "$existing_containers" | wc -l)
        log_warn "The following $container_count container(s) currently exist and will ALL be destroyed:"
        while IFS= read -r ec; do
            [[ -n "$ec" ]] && log_warn "  - $ec"
        done <<< "$existing_containers"
    fi
    local skip_reset=false
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        log_warn "Non-interactive mode (--non-interactive) — skipping automatic podman system reset to avoid data loss."
        log_info "Run this script without --non-interactive to approve, or try: podman system reset --force"
        skip_reset=true
    elif [[ -t 0 ]]; then
        echo -ne "${RED}${BOLD}Type 'reset' to proceed with podman system reset (destroys ALL containers), or anything else to skip: ${NC}" >&2
        local reset_confirm
        read -r reset_confirm
        if [[ "$reset_confirm" != "reset" ]]; then
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
        reset_output=$(container_runtime_privileged system reset --force 2>&1) && rc=0 || rc=$?
        log_debug "podman system reset: $reset_output"
    fi

    if [[ "$skip_reset" != "true" ]] && podman info >/dev/null 2>&1; then
        log_success "Podman recovered after system reset."
        return 0
    fi

    # Step 8: Storage migration
    log_info "Attempting to migrate podman storage..."
    podman system migrate 2>/dev/null || true

    if podman info >/dev/null 2>&1; then
        log_success "Podman recovered after storage migration."
        return 0
    fi

    # Step 9: All automated repairs failed. Diagnose and report.
    log_error "All automated rootless podman repairs have failed."
    log_error ""
    log_error "Rootless podman cannot run containers. This is required for secure"
    log_error "isolation — running containers as host root via sudo is INSECURE."
    log_error ""
    log_error "Common causes and manual fixes:"
    log_error "  1. Missing subuid/subgid mappings:"
    log_error "     sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(whoami)"
    log_error "     Then log out and back in."
    log_error "  2. Corrupted podman storage (nuclear option — destroys ALL podman data):"
    log_error "     podman system reset --force"
    log_error "  3. Missing XDG_RUNTIME_DIR (user session issue):"
    log_error "     sudo loginctl enable-linger $(whoami)"
    log_error "     Then log out and back in."
    log_error "  4. SteamOS read-only rootfs blocking storage:"
    log_error "     Ensure /home is writable (it should be by default on Steam Deck)."
    log_error ""
    log_error "After fixing, try running this script again."
    log_error "As a LAST RESORT (INSECURE), you may use --allow-sudo-fallback"
    log_error "to run the container as host root, but this weakens security significantly."
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
            # Rootless podman is broken and automated repairs failed.
            # Check if sudo fallback is explicitly allowed.
            if [[ "$ALLOW_SUDO_FALLBACK" == "true" ]] || [[ "${PODMAN_SUDO_FALLBACK:-}" == "true" ]]; then
                log_warn "Attempting sudo podman fallback (explicitly allowed via --allow-sudo-fallback)..."
                if sudo podman info >/dev/null 2>&1; then
                    log_warn "SECURITY: Running as host root via sudo. Container isolation is weakened."
                    log_warn "A malicious AUR package could more easily compromise your host system."
                    export PODMAN_SUDO_FALLBACK=true
                    export DISTROBOX_CONTAINER_MANAGER=podman
                    return 0
                fi
                log_error "Even sudo podman is not functional."
            fi
            if command -v docker >/dev/null 2>&1; then
                log_warn "Podman repair failed. Falling back to docker."
                export DISTROBOX_CONTAINER_MANAGER=docker
                return 0
            fi
            log_error "No working container runtime available. Install podman or docker."
            log_error "Run with --allow-sudo-fallback to try sudo podman (INSECURE)."
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
  --allow-sudo-fallback     Allow rootless Podman sudo fallback (INSECURE: see security note)
  --force-rebuild           Rebuild existing container if it exists
  --enable-multilib         Enable 32-bit package support (default)
  --disable-multilib        Explicitly disable 32-bit package support
  --pamac-version VERSION    Pin pamac-aur to a specific AUR version/commit
                             (default: latest; use "latest" for automatic)
  --enable-gaming            Install extra gaming packages
  --disable-gaming           Do not install gaming packages (default)
  --enable-extra-repos       Enable popular third-party repositories (default)
  --disable-extra-repos      Do not add third-party repositories
  --enable-build-cache      Enable persistent build cache for yay (default)
  --disable-build-cache     Disable persistent build cache for yay
  --optimize-mirrors        Select fastest Pacman mirrors (default)
  --no-optimize-mirrors     Do not change default Pacman mirrors
  --uninstall               Remove container and all related files
  --update                  Update packages (pacman -Syu + yay -Syu) without full rebuild
  --status                  Check container health, Pamac installation, and export status
  --export-only              Re-export apps to host menu without running full setup
  --non-interactive          Skip all interactive prompts (safe for automation)
  --check                   Perform system checks and exit without installing
  --dry-run                 Show what would be done without making changes
  --verbose                 Show detailed output, including command logs
  --quiet                   Only show errors
  --version                 Show version information
  -h, --help                Show this help message

ENVIRONMENT VARIABLES:
  CONTAINER_NAME            Override default container name (default: arch-pamac)
  ARCHLINUX_IMAGE           Container base image (default: archlinux:base-20260628.0.549485)
                            Override with 'latest' or any other tag for different versions.
  FORCE_REBUILD            Set to 'true' to force-rebuild existing container
  ENABLE_GAMING_PACKAGES   Set to 'true' to install gaming packages
  PAMAC_VERSION            Specific pamac-aur version/commit to install (AUR fallback)
  ALLOW_SUDO_FALLBACK      Set to 'true' to allow sudo podman fallback (INSECURE:
                           runs container as host root instead of subuid/subgid,
                           reducing isolation if a malicious AUR package is installed)
  NON_INTERACTIVE          Set to 'true' to skip all interactive prompts (safe for
                           background tools, automated installers, and cron jobs)
  CHAOTIC_AUR_KEY_ID       Override the Chaotic-AUR signing key fingerprint
  ARCHLINUXCN_KEY_ID       Override the archlinuxcn signing key fingerprint
  ENDEAVOUROS_KEY_ID       Override the EndeavourOS signing key fingerprint

EXAMPLES:
  $0                                       # Basic setup
  $0 --enable-gaming --no-optimize-mirrors # Gaming setup, skip mirror optimization
  $0 --pamac-version v11.0.2              # Pin pamac-aur to a specific release tag
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
            --allow-sudo-fallback) ALLOW_SUDO_FALLBACK="true"; shift ;;
            --force-rebuild) FORCE_REBUILD="true"; shift ;;
            --enable-multilib) ENABLE_MULTILIB="true"; shift ;;
            --disable-multilib) ENABLE_MULTILIB="false"; shift ;;
--enable-gaming) ENABLE_GAMING_PACKAGES="true"; shift ;;
        --disable-gaming) ENABLE_GAMING_PACKAGES="false"; shift ;;
        --enable-extra-repos) ENABLE_EXTRA_REPOS="true"; shift ;;
        --disable-extra-repos) ENABLE_EXTRA_REPOS="false"; shift ;;
            --enable-build-cache) ENABLE_BUILD_CACHE="true"; shift ;;
            --disable-build-cache) ENABLE_BUILD_CACHE="false"; shift ;;
            --optimize-mirrors) OPTIMIZE_MIRRORS="true"; shift ;;
            --no-optimize-mirrors) OPTIMIZE_MIRRORS="false"; shift ;;
            --pamac-version)
                [[ -z "${2:-}" ]] && { log_error "pamac-version cannot be empty"; exit 1; }
                if [[ ! "$2" =~ ^[a-zA-Z0-9._-]+$ ]]; then
                    log_error "Invalid pamac-version: '$2' (only alphanumerics, dots, hyphens, underscores allowed)"
                    exit 1
                fi
                PAMAC_VERSION="$2"
                shift 2
                ;;
            --uninstall) UNINSTALL="true"; shift ;;
            --status) STATUS="true"; shift ;;
            --update) UPDATE="true"; shift ;;
            --export-only) EXPORT_ONLY="true"; shift ;;
            --non-interactive) NON_INTERACTIVE="true"; shift ;;
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
                if grep -Eq "X-SteamOS-Pamac-Container=${CONTAINER_NAME}|distrobox[- ]+enter.*${CONTAINER_NAME}|\b${CONTAINER_NAME}\b.*\.desktop" "$df" >/dev/null 2>&1; then
                    rm -f "$df" 2>/dev/null || true
                    cleaned=$((cleaned + 1))
                fi
            done < <(find "$app_dir" -maxdepth 1 -type f -name "*.desktop" -print0 2>/dev/null)
            find "$app_dir" -maxdepth 1 -type f \( -name "${CONTAINER_NAME}-*.desktop" -o -name "*-${CONTAINER_NAME}.desktop" \) -delete 2>/dev/null || true
            find "$app_dir" -maxdepth 1 -type f -name "*.desktop" -exec grep -l "X-SteamOS-Pamac-Container=${CONTAINER_NAME}" {} + 2>/dev/null | while IFS= read -r marked_df; do
                rm -f "$marked_df" 2>/dev/null || true
            done
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

_restore_errexit() {
  [[ "${_SAVED_ERREXIT:-}" == "on" ]] && set -e || true
}

wait_for_container() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "[DRY RUN] Would wait for container '$CONTAINER_NAME'"
    return 0
  fi
  local max_attempts=30
  local attempt=0
  _SAVED_ERREXIT=$(shopt -o -q errexit && echo "on" || echo "off")
  log_info "Waiting for container '$CONTAINER_NAME' to become ready..."

  set +e
  trap '_restore_errexit' RETURN

  while true; do
    attempt=$((attempt + 1))

    local status
    status=$(container_get_status)
    log_debug "Container status: $status (attempt $attempt/$max_attempts)"

    case "$status" in
      "running")
        if container_root_exec bash -c "echo ready" 2>/dev/null | grep -q "ready"; then
          log_success "Container is ready." || true
          return 0
        fi
        ;;
      "stopping"|"paused"|"stopped"|"improper")
        if [[ $attempt -le 5 ]]; then
          log_debug "Container in '$status' state, waiting..."
        else
          log_warn "Container stuck in '$status' state - removing and recreating" || true
          force_remove_container "$CONTAINER_NAME" || true
          return 2
        fi
        ;;
  "exited")
    if [[ "$CONTAINER_HAS_INIT" == "false" ]]; then
      log_debug "Container exited (normal in non-init mode). Restarting..." || true
      container_start || true
      sleep 3
      if container_is_usable; then
        log_success "Container restarted and ready (non-init mode)." || true
        return 0
      fi
      if [[ $attempt -gt 5 ]]; then
        log_warn "Non-init container not responding after restart. Removing and recreating." || true
        force_remove_container "$CONTAINER_NAME" || true
        return 2
      fi
    elif [[ $attempt -le 2 ]]; then
      log_debug "Container exited. Attempting restart (attempt $attempt)..." || true
      container_start || true
    elif [[ $attempt -le 5 ]]; then
      local exit_code
      exit_code=$(container_runtime_privileged inspect "$CONTAINER_NAME" --format '{{.State.ExitCode}}' 2>/dev/null || echo "unknown")
      log_warn "Container keeps exiting (exit code: $exit_code). Inspecting..." || true
      case "$exit_code" in
        137) log_error "Container was OOM-killed (exit 137). Not enough memory available." || true ;;
        139) log_error "Container segfaulted (exit 139). Possible kernel or image incompatibility." || true ;;
        1) log_warn "Container exited with code 1 (general error)." || true ;;
      esac
      log_debug "Waiting longer before next restart attempt..." || true
    else
      log_warn "Container stuck in 'exited' state - removing and recreating" || true
      force_remove_container "$CONTAINER_NAME" || true
      return 2
    fi
    ;;
      "not_found")
        log_error "Container '$CONTAINER_NAME' not found." || true
        return 1
        ;;
      "created")
        log_debug "Container in 'created' state, attempting start..." || true
        container_start || true
        ;;
    esac

    if [[ $attempt -gt $max_attempts ]]; then
      log_error "Container failed to become ready after $((max_attempts * 2)) seconds." || true
      log_info "Try removing with: podman rm -f $CONTAINER_NAME" || true
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

    if ! { read -r _pid1_comm < /proc/1/comm 2>/dev/null; } || [[ "$_pid1_comm" != "systemd" ]]; then
        CONTAINER_HAS_INIT="false"
        log_info "Host init is not systemd - using non-init container mode."
        return
    fi

    local init_binary=""
    local mgr="${DISTROBOX_CONTAINER_MANAGER:-podman}"
    if [[ "$mgr" == "docker" ]]; then
        init_binary=$(docker info --format '{{.Host.InitPath}}' 2>/dev/null || echo "")
    else
        init_binary=$(container_runtime_privileged info --format '{{.Host.InitPath}}' 2>/dev/null || echo "")
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
        --image "$ARCHLINUX_IMAGE"
        --yes
    )

    log_info "Pulling ${ARCHLINUX_IMAGE} image..."
    if ! run_command container_runtime pull "$ARCHLINUX_IMAGE"; then
        log_warn "Image pull failed, proceeding with cached image."
    fi

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

  if [[ -n "${_CREATE_RECREATION_GUARD:-}" ]]; then
    log_error "Container creation already attempted recreation internally - refusing nested retry."
    return 1
  fi
  _CREATE_RECREATION_GUARD=1

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
    force_remove_container "$CONTAINER_NAME"
    sleep 2
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
            pkg_base=$(grep -A1 "^%NAME%$" "$db_dir/desc" 2>/dev/null | grep -v '^%NAME%$' | head -1)
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

_CONTAINER_PREAMBLE='_safe_sleep() { if ! sleep "$1" 2>/dev/null; then read -t "$1" -r _ </dev/null 2>/dev/null || true; fi; }
_atomic_sed_inplace() {
    local _target="$1"; shift
    local _tmp; _tmp=$(mktemp "${_target}.atomic.XXXXXX") || { echo "FATAL: mktemp failed for atomic sed on $_target"; return 1; }
    cp -f "$_target" "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    for _expr in "$@"; do sed -i "$_expr" "$_tmp"; done
    sync "$_tmp" 2>/dev/null || sync 2>/dev/null || true
    mv -f "$_tmp" "$_target"
}
_calc_makepkg_jobs() {
    local ram_per_job_kb=768000
    local mem_avail_kb=0
    local ncpu
    ncpu=$(nproc 2>/dev/null || echo "1")
    if [[ -f /proc/meminfo ]]; then
        mem_avail_kb=$(awk "/^MemAvailable:/{print \$2}" /proc/meminfo 2>/dev/null || echo "0")
    fi
    if [[ "$mem_avail_kb" -gt 0 ]]; then
        local jobs=$(( mem_avail_kb / ram_per_job_kb ))
        [[ "$jobs" -lt 1 ]] && jobs=1
        [[ "$jobs" -gt "$ncpu" ]] && jobs="$ncpu"
        echo "$jobs"
    else
        local safe_ncpu=$(( ncpu > 4 ? 4 : ncpu ))
        echo "$safe_ncpu"
    fi
}
_set_makepkg_jobs() {
    local jobs
    jobs=$(_calc_makepkg_jobs)
    export MAKEFLAGS="-j${jobs}"
    echo "MAKEFLAGS set to -j${jobs} (RAM-constrained build parallelism)"
}
safe_install() {
    local attempt=0 max_attempts=3 rc=0
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
            _safe_sleep 2
        fi
    done
    return $rc
}
_assert_installed() {
    local _pkg="$1" _desc="${2:-$_pkg}"
    if ! pacman -Q "$_pkg" >/dev/null 2>&1; then
        echo "FATAL: $_desc ($_pkg) is not installed. Aborting."
        return 1
    fi
    echo "Verified: $_desc ($_pkg) installed."
}
install_base_devel_batched() {
    echo "Installing base-devel in smaller batches to avoid OOM..."
    local _failed_critical=false
    local BASE_DEVEL_BATCHES=(
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
            echo "ERROR: batch install failed for: $batch"
            for pkg in $batch; do
                if ! pacman -Q "$pkg" >/dev/null 2>&1; then
                    echo "  Missing from failed batch: $pkg"
                    case "$pkg" in
                        gcc|binutils|make|fakeroot|pkgconf)
                            echo "FATAL: Critical build tool '\''$pkg'\'' missing. Cannot continue."
                            _failed_critical=true
                            ;;
                    esac
                fi
            done
        fi
    done
    if [[ "$_failed_critical" == "true" ]]; then
        echo "FATAL: Critical base-devel components failed to install. Aborting."
        return 1
    fi
    if ! pacman -Qg base-devel >/dev/null 2>&1 && ! safe_install base-devel; then
        echo "Warning: base-devel group meta-package could not be installed (individual packages verified above)."
    fi
}
'

exec_container_script() {
    local _script="$1"
    local _desc="$2"
    shift 2
    if [[ -z "$_script" ]]; then
        log_error "Internal error: container script '$_desc' is empty (heredoc delimiter may be missing/misfound). Aborting stage."
        return 1
    fi
    local _rc=0
    local _script_file
    local _preamble="$_CONTAINER_PREAMBLE"

    _script_file=$(mktemp --tmpdir pamac-script-XXXXXXXX)
    _TEMP_FILES+=("$_script_file")
    printf '%s\n' "${_preamble}${_script}" > "$_script_file"

    local _marker="PAMAC_SCRIPT_OK_$(head -c 16 /dev/urandom 2>/dev/null | base64 2>/dev/null || echo "$$_$(date +%s)")"
  printf '\necho "%s"\n' "$_marker" >> "$_script_file"

  set +e
  local _output=""
  if [[ "$LOG_LEVEL" == "verbose" ]]; then
    _output=$(container_root_exec bash -s "$@" < "$_script_file" 2>&1 | tee -a "$LOG_FILE" | _filter_verbose_output)
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
        if [[ $_rc -eq 100 ]]; then
            log_error "Fatal keyring/security error in script '$_desc'. Last 20 lines of output:"
            echo "$_output" | tail -20 | while IFS= read -r line; do
                log_error "  $line"
            done
        elif [[ $_rc -eq 137 ]]; then
            log_error "Script '$_desc' killed (OOM/signal). Last 20 lines of output:"
            echo "$_output" | tail -20 | while IFS= read -r line; do
                log_error "  $line"
            done
        else
            local _tail
            _tail=$(echo "$_output" | tail -20)
            if [[ -n "$_tail" ]]; then
                log_warn "Last 20 lines of script output:"
                echo "$_tail" | while IFS= read -r line; do
                    log_warn "  $line"
                done
            fi
        fi
        container_root_exec bash -c "rm -f /var/lib/pacman/db.lck; pkill -9 gpg-agent 2>/dev/null || true" 2>/dev/null || true
        container_start 2>/dev/null || true
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
    local _marker="PAMAC_PIPE_OK_$(head -c 16 /dev/urandom 2>/dev/null | base64 2>/dev/null || echo "$$_$(date +%s)")"
    local _preamble="$_CONTAINER_PREAMBLE"

    _script_file=$(mktemp --tmpdir pamac-pipe-XXXXXXXX)
    _TEMP_FILES+=("$_script_file")
    printf '%s' "$_preamble" > "$_script_file"
    cat >> "$_script_file"
    local _piped_size
    _piped_size=$(wc -c < "$_script_file" 2>/dev/null || echo "0")
    if [[ "$_piped_size" -le ${#_preamble} ]]; then
        log_error "Internal error: piped script '$_desc' is empty (heredoc delimiter may be missing/misfound). Aborting stage."
        rm -f "$_script_file"
        return 1
    fi
    printf '\necho "%s"\n' "$_marker" >> "$_script_file"

    set +e
    local _output=""
    if [[ "$LOG_LEVEL" == "verbose" ]]; then
        _output=$(container_root_exec bash -s "$@" < "$_script_file" 2>&1 | tee -a "$LOG_FILE" | _filter_verbose_output)
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
        if [[ $_rc -eq 100 ]]; then
            log_error "Fatal keyring/security error in piped script '$_desc'. Last 20 lines of output:"
            echo "$_output" | tail -20 | while IFS= read -r line; do
                log_error "  $line"
            done
        elif [[ $_rc -eq 137 ]]; then
            log_error "Piped script '$_desc' killed (OOM/signal). Last 20 lines of output:"
            echo "$_output" | tail -20 | while IFS= read -r line; do
                log_error "  $line"
            done
        else
            local _tail
            _tail=$(echo "$_output" | tail -20)
            if [[ -n "$_tail" ]]; then
                log_warn "Last 20 lines of piped script output:"
                echo "$_tail" | while IFS= read -r line; do
                    log_warn "  $line"
                done
            fi
        fi
        container_root_exec bash -c "rm -f /var/lib/pacman/db.lck; pkill -9 gpg-agent 2>/dev/null || true" 2>/dev/null || true
        container_start 2>/dev/null || true
        repair_pacman_db
        return $_rc
    fi
    return 0
}

configure_container_base() {
    log_step "Configuring container base environment"

    local _ok=true

    log_info "Stage 1/7: Initializing pacman keyring and signature verification..."
    local keyring_script
    read -r -d '' keyring_script <<'KEYRING_EOF' || true
set -uo pipefail

rm -f /var/lib/pacman/db.lck

# Atomic pacman.conf writer: avoids sed -i which is non-atomic and can corrupt
# the file if the process is killed mid-write (power loss, SIGKILL).
# Writes to a temp file, fsyncs, then atomically renames over the target.
_atomic_write_pacman_conf() {
    local target="/etc/pacman.conf"
    local new_siglevel="$1"
    local tmp
    tmp=$(mktemp "${target}.atomic.XXXXXX") || { echo "FATAL: mktemp failed"; return 1; }
    cp -f "$target" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    sed -i "s/^[[:space:]]*SigLevel.*/SigLevel = ${new_siglevel}/" "$tmp"
    grep -q '^SigLevel' "$tmp" || printf 'SigLevel = %s\n' "$new_siglevel" >> "$tmp"
    sync "$tmp" 2>/dev/null || sync 2>/dev/null || true
    mv -f "$tmp" "$target"
}

echo "Step 0/5: Checking for leftover insecure SigLevel from previous crash..."
# The sentinel file marks that a TrustAll operation was in progress when the
# previous run was interrupted. It survives reboots and container restarts,
# unlike traps which only fire during the current process lifetime.
_SIGLEVEL_SENTINEL="/etc/pacman.conf.siglevel-pending"
_SIGLEVEL_BACKUP="/etc/pacman.conf.siglevel-backup"
if [[ -f "$_SIGLEVEL_SENTINEL" ]] || grep -q '^SigLevel\s*=\s*TrustAll' /etc/pacman.conf 2>/dev/null; then
    if [[ -f "$_SIGLEVEL_BACKUP" ]]; then
        echo "WARNING: Found SigLevel=TrustAll from a previous interrupted run. Restoring from backup."
        cp -f "$_SIGLEVEL_BACKUP" /etc/pacman.conf
    else
        echo "WARNING: Found SigLevel=TrustAll with no backup. Forcing restore to safe default."
        _atomic_write_pacman_conf "Required DatabaseOptional"
    fi
    rm -f "$_SIGLEVEL_SENTINEL" "$_SIGLEVEL_BACKUP" 2>/dev/null || true
fi

# Crash-safe SigLevel restoration: if this script is killed, restore the backup.
# The sentinel file is also checked on next boot for defense-in-depth.
_rollback_siglevel() {
    local exit_code=$?
    if [[ -f "$_SIGLEVEL_BACKUP" ]] && grep -q '^SigLevel\s*=\s*TrustAll' /etc/pacman.conf 2>/dev/null; then
        echo "Trap: Restoring SigLevel from backup (exit code $exit_code)..."
        cp -f "$_SIGLEVEL_BACKUP" /etc/pacman.conf
    fi
    if [[ $exit_code -eq 0 ]] && [[ -f "$_SIGLEVEL_BACKUP" ]]; then
        rm -f "$_SIGLEVEL_BACKUP" "$_SIGLEVEL_SENTINEL" 2>/dev/null || true
    fi
}
trap _rollback_siglevel EXIT

echo "Step 1/5: Cleaning up stale GPG state..."
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

echo "Step 2/5: Attempting safe keyring recovery (no signature relaxation)..."

_KEYRING_SENTINEL="/etc/pacman.d/gnupg/.keyring-recovery-pending"
_safe_recovered=false

# Check if keyring recovery was already completed (persists across container restarts)
if [[ -f "$_KEYRING_SENTINEL" ]]; then
    echo "Found keyring recovery sentinel from previous run. Keyring recovery already completed."
    _safe_recovered=true
    rm -f "$_KEYRING_SENTINEL" 2>/dev/null || true
fi

# Method A: Refresh keys from keyservers (uses GnuPG's built-in HTTP client, no curl needed)
echo "Method A: Refreshing keys from keyservers..."
pkill -9 gpg-agent 2>/dev/null || true
pkill -9 dirmngr 2>/dev/null || true
_safe_sleep 1
for _ks in "hkps://keyserver.ubuntu.com" "hkps://keys.openpgp.org" "hkps://pgp.mit.edu"; do
    echo "  Trying keyserver: $_ks"
    if timeout 45 pacman-key --refresh-keys --keyserver "$_ks" 2>/dev/null; then
        echo "  Key refresh succeeded from $_ks."
        _safe_recovered=true
        break
    fi
    echo "  Keyserver $_ks failed or timed out."
done

# Method B: Download keyring package directly via HTTPS and import keys manually
if [[ "$_safe_recovered" != "true" ]] && command -v curl >/dev/null 2>&1; then
    echo "Method B: Attempting direct keyring package download via HTTPS..."
    _mirror_url="https://geo.mirror.pkgbuild.com/core/os/x86_64"
    _kr_pkg=$(curl -sLf --connect-timeout 10 --max-time 30 "${_mirror_url}/" 2>/dev/null | \
        grep -oP 'archlinux-keyring-[0-9]+-[0-9]+-any\.pkg\.tar\.zst' | sort -V | tail -1 || true)
    if [[ -n "$_kr_pkg" ]]; then
        echo "  Found keyring package: $_kr_pkg"
        _tmp_kr=$(mktemp /tmp/kr-XXXXXX.pkg.tar.zst)
        if curl -sLf --connect-timeout 10 --max-time 120 -o "$_tmp_kr" "${_mirror_url}/${_kr_pkg}" 2>/dev/null; then
            _tmp_kr_dir=$(mktemp -d /tmp/kr-extract-XXXXXX)
            if tar -xf "$_tmp_kr" -C "$_tmp_kr_dir" 2>/dev/null; then
                for _kr_file in "$_tmp_kr_dir"/usr/share/pacman/keyrings/archlinux*; do
                    [[ -f "$_kr_file" ]] && cp -f "$_kr_file" /etc/pacman.d/gnupg/ 2>/dev/null || true
                done
                echo "  Keyring files extracted. Populating..."
                if pacman-key --populate archlinux 2>/dev/null; then
                    echo "  Direct keyring import succeeded."
                    _safe_recovered=true
                else
                    echo "  Keyring populate failed after direct import."
                fi
            fi
            rm -rf "$_tmp_kr_dir"
        fi
        rm -f "$_tmp_kr"
    else
        echo "  Could not find keyring package on mirror."
    fi
fi

# Method C: Try standard database sync (works if keys are only slightly stale)
if [[ "$_safe_recovered" != "true" ]]; then
    echo "Method C: Attempting standard database sync and keyring update..."
    rm -f /var/lib/pacman/db.lck
    if pacman -Syy --noconfirm 2>/dev/null; then
        if pacman -S --noconfirm --needed archlinux-keyring gnupg 2>/dev/null; then
            echo "Standard sync and keyring update succeeded."
            _safe_recovered=true
        fi
    fi
fi

# No TrustAll fallback — skip repo if keyring recovery fails
if [[ "$_safe_recovered" == "true" ]]; then
    echo "Safe keyring recovery succeeded."
    # Persist recovery state across container restarts
    touch "$_KEYRING_SENTINEL" 2>/dev/null || true
else
    echo "FATAL: All safe recovery methods failed. Cannot proceed without valid keyring."
    echo "TrustAll is NOT used as it would disable all signature verification."
    echo "Try: pacman-key --init && pacman-key --populate archlinux"
    echo "Or: install archlinux-keyring from a trusted source manually."
    exit 100
fi

echo "Step 3/5: Updating keyring, GPG, and certificate packages..."
rm -f /var/lib/pacman/db.lck

if ! pacman -Syy --noconfirm 2>/dev/null; then
    echo "Warning: Initial database sync failed. Attempting repair with --overwrite..."
    pacman -Syy --noconfirm --overwrite '*' 2>/dev/null || true
fi

pacman -S --noconfirm --needed archlinux-keyring gnupg 2>/dev/null || {
    echo "Warning: Core keyring/GPG update failed, retrying..."
    pacman -S --noconfirm --needed archlinux-keyring gnupg 2>/dev/null || true
}
pacman -S --noconfirm --needed ca-certificates-mozilla ca-certificates-utils 2>/dev/null || {
    echo "Warning: Certificate package update failed, retrying..."
    pacman -S --noconfirm --needed ca-certificates-mozilla 2>/dev/null || true
}

echo "Step 4/5: Aggressively re-initializing pacman keyring..."
keyring_ok=false

for attempt in 1 2 3; do
    echo "Attempting pacman-key --init (attempt $attempt/3)..."
    pkill -9 gpg-agent 2>/dev/null || true
    pkill -9 dirmngr 2>/dev/null || true
    _safe_sleep 2
    rm -f /etc/pacman.d/gnupg/S.gpg-agent /etc/pacman.d/gnupg/S.gpg-agent.extra 2>/dev/null || true
    rm -f /etc/pacman.d/gnupg/S.gpg-agent.browser /etc/pacman.d/gnupg/S.gpg-agent.ssh 2>/dev/null || true
    rm -f /etc/pacman.d/gnupg/S.dirmngr 2>/dev/null || true

    if timeout 120 pacman-key --init 2>/dev/null; then
        echo "Keyring init succeeded."
        keyring_ok=true
        break
    else
        echo "Warning: pacman-key --init failed or timed out on attempt $attempt."
    fi
done

if [[ "$keyring_ok" == "true" ]]; then
    echo "Populating keyring with archlinux keys..."
    chmod 700 /etc/pacman.d/gnupg 2>/dev/null || true
    find /etc/pacman.d/gnupg -type f -exec chmod 600 {} \; 2>/dev/null || true
    find /etc/pacman.d/gnupg -type d -exec chmod 700 {} \; 2>/dev/null || true

    if timeout 60 pacman-key --populate archlinux 2>/dev/null; then
        echo "Keyring populated successfully."
    else
        echo "Warning: pacman-key --populate failed."
        keyring_ok=false
    fi
fi

echo "Step 5/5: Verifying keyring and restoring security settings..."

if [[ "$keyring_ok" == "true" ]]; then
    if pacman-key --list-sigs 2>/dev/null | grep -q "archlinux"; then
        echo "Keyring contains archlinux signatures."
    else
        echo "Warning: pacman-key --list-sigs did not confirm archlinux keys."
        keyring_ok=false
    fi
fi

if [[ "$keyring_ok" == "true" ]]; then
    echo "Restoring SigLevel to Required DatabaseOptional..."
    _atomic_write_pacman_conf "Required DatabaseOptional"

    # Remove the backup and sentinel since we've successfully restored
    rm -f "$_SIGLEVEL_BACKUP" "$_SIGLEVEL_SENTINEL" 2>/dev/null || true

    echo "Testing database sync with restored signature verification..."
    if pacman -Syy --noconfirm 2>/dev/null; then
        echo "Signature verification restored and functional."
    else
        echo "Warning: Database sync failed after restoring SigLevel."
        keyring_ok=false
    fi
fi

if [[ "$keyring_ok" != "true" ]]; then
    echo "FATAL: Pacman keyring could not be repaired. The container is in an unsecure state."
    echo "FATAL: Aborting installation to prevent running without signature verification."
    # Ensure we don't leave the container in a wide-open state
    _atomic_write_pacman_conf "Required DatabaseOptional" 2>/dev/null || \
        _atomic_sed_inplace /etc/pacman.conf 's/^[[:space:]]*SigLevel.*/SigLevel = Required DatabaseOptional/' 2>/dev/null || true
    rm -f "$_SIGLEVEL_BACKUP" "$_SIGLEVEL_SENTINEL" 2>/dev/null || true
    exit 100
fi

echo "Configuring pacman for low-memory environment..."
if grep -q '^ParallelDownloads' /etc/pacman.conf 2>/dev/null; then
    _atomic_sed_inplace '/etc/pacman.conf' 's/^ParallelDownloads.*/ParallelDownloads = 1/'
else
    echo 'ParallelDownloads = 1' >> /etc/pacman.conf
fi

echo "Keyring initialization and self-healing complete."
# Clean up recovery sentinel on successful completion
rm -f "$_KEYRING_SENTINEL" 2>/dev/null || true
KEYRING_EOF

    if ! exec_container_script "$keyring_script" "keyring-init"; then
        log_error "Keyring initialization and self-healing failed permanently."
        log_error "The container cannot operate securely without valid package signatures."
        log_error "This usually indicates a broken base image, missing network connectivity, or corrupted keyring."
        return 1
    fi

    if ! container_is_usable; then
        log_error "Container not usable after keyring init."
        return 1
    fi

    log_info "Stage 2/7: Performing system upgrade..."
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

CRITICAL_PKGS=(openssl glibc lib32-glibc systemd-libs pam)
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
SKIP_PKGS=(systemd systemd-sysvcompat)
exclude_args=()
for pkg in "${CRITICAL_PKGS[@]}" archlinux-keyring ca-certificates-mozilla "${SKIP_PKGS[@]}"; do
    exclude_args+=(--ignore "$pkg")
done
if ! pacman -Su --noconfirm --needed "${exclude_args[@]}" 2>/dev/null; then
    echo "Non-critical upgrade had issues, trying with conflict resolution..."
    pacman -Su --noconfirm --needed "${exclude_args[@]}" 2>/dev/null || echo "Warning: non-critical upgrade failed"
fi

verify_core_tools || {
    echo "FATAL: Core tools broken after non-critical upgrade. Cannot recover."
    exit 2
}

echo "Pass 3: Upgrading critical packages (openssl, glibc, systemd)..."
for pkg in "${CRITICAL_PKGS[@]}"; do
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

    log_info "Stage 3/7: Installing core system packages..."
    local core_script
    read -r -d '' core_script <<'CORE_EOF' || true
set -uo pipefail

rm -f /var/lib/pacman/db.lck

echo "Installing core packages (sudo, shadow, gnupg, jq)..."
if ! safe_install sudo shadow gnupg jq; then
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

    log_info "Stage 4/7: Installing development packages (batched to avoid OOM)..."
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

echo "Installing git..."
check_mem 262144 "git install"
if ! safe_install git; then
    echo "Failed to install git."
    exit 1
fi
_assert_installed git

check_mem 524288 "base-devel install"
if ! install_base_devel_batched; then
    echo "FATAL: base-devel batch install failed (critical tools missing)."
    exit 1
fi
_assert_installed gcc "C compiler"
_assert_installed make "build tool"

echo "Installing go..."
check_mem 262144 "go install"
sync 2>/dev/null || true
_safe_sleep 1
if ! safe_install go; then
    echo "Failed to install go."
    exit 1
fi
_assert_installed go "Go compiler"

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

    for _dep in git gcc go; do
        if ! container_root_exec bash -c "command -v $_dep >/dev/null 2>&1 || pacman -Q $_dep >/dev/null 2>&1" 2>/dev/null; then
            log_warn "Development dependency '$_dep' not found after install stage. Attempting recovery..."
            container_root_exec bash -c "rm -f /var/lib/pacman/db.lck; pacman -S --noconfirm --needed $_dep" 2>/dev/null || true
        fi
    done

    log_info "Stage 5/7: Creating user and configuring sudo..."
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

cat > /etc/sudoers.d/99-wheel-nopasswd <<'SUDOERS'
Cmnd_Alias PAMAC_CMDS = /usr/bin/pacman, \
    /usr/bin/pamac, \
    /usr/bin/pamac-manager, \
    /usr/bin/pamac-daemon, \
    /usr/bin/yay, \
    /usr/bin/makepkg, \
    /usr/bin/pacman-key, \
    /usr/bin/paccache, \
    /usr/bin/pacscripts, \
    /usr/bin/lsblk, \
    /usr/bin/blkid, \
    /usr/bin/findmnt

%wheel ALL=(ALL:ALL) NOPASSWD: PAMAC_CMDS
SUDOERS
chmod 0440 /etc/sudoers.d/99-wheel-nopasswd
if command -v visudo >/dev/null 2>&1; then
    if visudo -c -f /etc/sudoers.d/99-wheel-nopasswd 2>/dev/null; then
        echo "Configured strict sudo allowlist for package management only (validated with visudo)."
    else
        echo "Warning: sudoers syntax check failed. Removing potentially broken sudoers file."
        rm -f /etc/sudoers.d/99-wheel-nopasswd
    fi
else
    echo "Configured strict sudo allowlist for package management only (visudo not available for validation)."
fi
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
' var PAMAC_ACTIONS = [' \
'   "org.manjaro.pamac.install", ' \
'   "org.manjaro.pamac.remove", ' \
'   "org.manjaro.pamac.update", ' \
'   "org.manjaro.pamac.get-updates", ' \
'   "org.manjaro.pamac.refresh-cache"' \
' ];' \
' if (PAMAC_ACTIONS.indexOf(action.id) >= 0 &&' \
'   subject.isInGroup("wheel") &&' \
'   subject.local && subject.active) {' \
'   return polkit.Result.YES;' \
' }' \
'});' > "$polkit_dir/10-pamac-nopasswd.rules"
echo "polkit passwordless rule created for pamac operations (explicit allowlist, local+active only)."
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

echo "Leaving Pamac polkit policy at auth_admin_keep defaults."
echo "Passwordless package ops for wheel group are handled by 10-pamac-nopasswd.rules (overrides this policy file)."
pamac_policy="/usr/share/polkit-1/actions/org.manjaro.pamac.policy"
if [[ -f "$pamac_policy" ]]; then
    if grep -q '<allow_any>yes</allow_any>' "$pamac_policy"; then
        _atomic_sed_inplace "$pamac_policy" \
            's|<allow_any>yes</allow_any>|<allow_any>auth_admin_keep</allow_any>|' \
            's|<allow_inactive>yes</allow_inactive>|<allow_inactive>auth_admin_keep</allow_inactive>|' \
            's|<allow_active>yes</allow_active>|<allow_active>auth_admin_keep</allow_active>|'
        echo "Restored least-privilege polkit policy (was previously relaxed to allow_any=yes)."
    fi
else
    echo "Note: pamac polkit policy not yet installed (defaults are least-privilege)."
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
touch "$BOOTSTRAP_LOG" 2>/dev/null && chmod 644 "$BOOTSTRAP_LOG" 2>/dev/null

# Crash recovery: if the previous keyring-init run was killed (power loss, SIGKILL),
# the TrustAll SigLevel may be permanently set. The sentinel file persists across
# container restarts and reboots — check and restore on every shell entry.
if [[ -f /etc/pacman.conf.siglevel-pending ]] || grep -q '^SigLevel\s*=\s*TrustAll' /etc/pacman.conf 2>/dev/null; then
    if [[ -f /etc/pacman.conf.siglevel-backup ]]; then
        echo "[$(date '+%H:%M:%S')] CRASH RECOVERY: Restoring SigLevel from backup (sentinel found)" >> "$BOOTSTRAP_LOG" 2>/dev/null || true
        cp -f /etc/pacman.conf.siglevel-backup /etc/pacman.conf 2>/dev/null || true
    else
        echo "[$(date '+%H:%M:%S')] CRASH RECOVERY: SigLevel=TrustAll with no backup, forcing safe default" >> "$BOOTSTRAP_LOG" 2>/dev/null || true
        _tmp_pac=$(mktemp /etc/pacman.conf.atomic.XXXXXX) 2>/dev/null && {
            cp -f /etc/pacman.conf "$_tmp_pac" 2>/dev/null && {
                sed -i 's/^[[:space:]]*SigLevel.*/SigLevel = Required DatabaseOptional/' "$_tmp_pac" 2>/dev/null
                grep -q '^SigLevel' "$_tmp_pac" 2>/dev/null || echo 'SigLevel = Required DatabaseOptional' >> "$_tmp_pac"
                sync "$_tmp_pac" 2>/dev/null || sync 2>/dev/null || true
                mv -f "$_tmp_pac" /etc/pacman.conf 2>/dev/null
            } || rm -f "$_tmp_pac" 2>/dev/null
        } || sed -i 's/^[[:space:]]*SigLevel.*/SigLevel = Required DatabaseOptional/' /etc/pacman.conf 2>/dev/null || true
    fi
    rm -f /etc/pacman.conf.siglevel-pending /etc/pacman.conf.siglevel-backup 2>/dev/null || true
fi

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
local start_fn="$3"
local retries=5
local count=0

if command -v pgrep >/dev/null 2>&1 && pgrep -x "$pid_ok" >/dev/null 2>&1; then
log_bootstrap "$name already running (pid $(pgrep -x "$pid_ok" 2>/dev/null | head -1))"
return 0
fi

log_bootstrap "Starting $name..."
while [[ $count -lt $retries ]]; do
"$start_fn" >> "$BOOTSTRAP_LOG" 2>&1
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

start_dbus() {
mkdir -p /run/dbus
dbus-daemon --system --fork 2>/dev/null
}

start_polkitd() {
if [[ -x /usr/lib/polkit-1/polkitd ]]; then
/usr/lib/polkit-1/polkitd --no-debug &
fi
}

start_pamac_daemon() {
/usr/bin/pamac-daemon &
}

if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
log_bootstrap "systemd detected, starting services via systemctl"
systemctl start polkit 2>/dev/null || true
systemctl start pamac-daemon >/dev/null 2>&1 || true
else
log_bootstrap "Non-systemd environment, starting services manually"
ensure_service "dbus-daemon" "dbus-daemon" start_dbus
ensure_service "polkitd" "polkitd" start_polkitd
ensure_service "pamac-daemon" "pamac-daemon" start_pamac_daemon
fi
BOOTSTRAP
chmod +x /usr/local/bin/pamac-session-bootstrap.sh
echo "Bootstrap helper installed."

echo "Installing fake systemd-run wrapper for non-systemd AUR builds..."
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl show-environment >/dev/null 2>&1; then
cat > /usr/local/sbin/systemd-run << 'SYSTEMD_RUN_FAKE'
#!/bin/bash
# Fake systemd-run for non-systemd containers (Distrobox).
# Mimics the subset of systemd-run used by Pamac/makepkg for DynamicUser builds.
# Logs unrecognized arguments to /tmp/systemd-run-fake.log for diagnostics.
_DSR_LOG="/tmp/systemd-run-fake.log"
_log_dsr() { echo "[$(date '+%H:%M:%S')] $*" >> "$_DSR_LOG" 2>/dev/null; }

# Passthrough: --help and --version are not meaningful here
for _a in "$@"; do
    case "$_a" in
        --help|-h) echo "systemd-run (fake): Mimics systemd-run for DynamicUser AUR builds in non-systemd containers."; echo "Recognized options: --property=DynamicUser=yes, --property=CacheDirectory=*, --property=WorkingDirectory=*, --pipe, --wait, --quiet, --no-block, --description=*, --unit=*, --service-type=*, --user, --uid=*, --gid=*, --setenv=*, --"; exit 0 ;;
        --version) echo "systemd-run (fake) v1.0 (SteamOS-Pamac)"; exit 0 ;;
    esac
done

DYNAMIC_USER=false
CACHE_DIR=""
WORK_DIR=""
SKIP_NEXT=false
PIPE_MODE=false
WAIT_MODE=false
DESCRIPTION=""
UNRECOGNIZED_PROPS=()
CMD_ARGS=()
for arg in "$@"; do
if $SKIP_NEXT; then
SKIP_NEXT=false
continue
fi
case "$arg" in
--service-type=*) continue ;;
--service-type) SKIP_NEXT=true; continue ;;
--pipe) PIPE_MODE=true; continue ;;
--wait) WAIT_MODE=true; continue ;;
--pty|-q|--quiet|--no-block) continue ;;
--description=*) DESCRIPTION="${arg#--description=}"; continue ;;
--description) SKIP_NEXT=true; continue ;;
--unit=*) continue ;;
--unit) SKIP_NEXT=true; continue ;;
--property=DynamicUser=yes) DYNAMIC_USER=true; continue ;;
--property=CacheDirectory=*) CACHE_DIR="${arg#--property=CacheDirectory=}"; continue ;;
--property=WorkingDirectory=*) WORK_DIR="${arg#--property=WorkingDirectory=}"; continue ;;
--property=StateDirectory=*) continue ;;
--property=LogsDirectory=*) continue ;;
--property=RuntimeDirectory=*) continue ;;
--property=Type=*) continue ;;
--property=RemainAfterExit=*) continue ;;
--property=*) UNRECOGNIZED_PROPS+=("$arg"); _log_dsr "WARN: Unrecognized --property: $arg"; continue ;;
--property) SKIP_NEXT=true; continue ;;
--user|--uid=*|--gid=*|--setenv=*) continue ;;
--user|--setenv) SKIP_NEXT=true; continue ;;
--) shift; CMD_ARGS+=("$@"); break ;;
*) CMD_ARGS+=("$arg") ;;
esac
done
if [[ ${#CMD_ARGS[@]} -eq 0 ]]; then
    _log_dsr "ERROR: No command arguments found after parsing. Raw args: $*"
    exit 1
fi
if [[ ${#UNRECOGNIZED_PROPS[@]} -gt 0 ]]; then
    _log_dsr "INFO: Unrecognized properties were ignored (${#UNRECOGNIZED_PROPS[@]} total): ${UNRECOGNIZED_PROPS[*]}"
    _log_dsr "INFO: If AUR builds fail, check $_DSR_LOG for which properties Pamac now expects."
fi
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
_log_dsr "EXEC: sudo -u $BUILD_USER -- cd $WORK_DIR; ${CMD_ARGS[*]}"
exec sudo -u "$BUILD_USER" -H -- bash -c 'cd "$1" 2>/dev/null; shift; exec "$@"' _ "$WORK_DIR" "${CMD_ARGS[@]}"
else
_log_dsr "EXEC: sudo -u $BUILD_USER -- ${CMD_ARGS[*]}"
exec sudo -u "$BUILD_USER" -H -- "${CMD_ARGS[@]}"
fi
else
if [[ -n "$WORK_DIR" ]] && [[ -d "$WORK_DIR" ]]; then cd "$WORK_DIR" 2>/dev/null || true; fi
_log_dsr "EXEC: ${CMD_ARGS[*]}"
exec "${CMD_ARGS[@]}"
fi
SYSTEMD_RUN_FAKE
chmod +x /usr/local/sbin/systemd-run
_atomic_sed_inplace /usr/local/sbin/systemd-run "s/HOST_USER_PLACEHOLDER/$HOST_USER/g"
echo "Fake systemd-run installed at /usr/local/sbin/systemd-run."
echo "Unrecognized arguments will be logged to /tmp/systemd-run-fake.log for debugging."

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
 systemd_run_check=$( { container_root_exec test -x /usr/local/sbin/systemd-run && echo "ok" || echo "missing"; } 2>/dev/null)
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
dbus_conf_check=$( { container_root_exec test -f /usr/share/dbus-1/system.d/org.manjaro.pamac.daemon.conf && echo "ok" || echo "missing"; } 2>/dev/null)
if [[ "$dbus_conf_check" != "ok" ]]; then
log_warn "D-Bus daemon policy config is MISSING from container."
missing_items+=("dbus-daemon-conf")
fi

local bootstrap_check
bootstrap_check=$( { container_root_exec test -x /usr/local/bin/pamac-session-bootstrap.sh && echo "ok" || echo "missing"; } 2>/dev/null)
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
touch "$BOOTSTRAP_LOG" 2>/dev/null && chmod 644 "$BOOTSTRAP_LOG" 2>/dev/null

if [[ -f /etc/pacman.conf.siglevel-pending ]] || grep -q '^SigLevel\s*=\s*TrustAll' /etc/pacman.conf 2>/dev/null; then
    if [[ -f /etc/pacman.conf.siglevel-backup ]]; then
        echo "[$(date '+%H:%M:%S')] CRASH RECOVERY: Restoring SigLevel from backup (sentinel found)" >> "$BOOTSTRAP_LOG" 2>/dev/null || true
        cp -f /etc/pacman.conf.siglevel-backup /etc/pacman.conf 2>/dev/null || true
    else
        echo "[$(date '+%H:%M:%S')] CRASH RECOVERY: SigLevel=TrustAll with no backup, forcing safe default" >> "$BOOTSTRAP_LOG" 2>/dev/null || true
        _tmp_pac=$(mktemp /etc/pacman.conf.atomic.XXXXXX) 2>/dev/null && {
            cp -f /etc/pacman.conf "$_tmp_pac" 2>/dev/null && {
                sed -i 's/^[[:space:]]*SigLevel.*/SigLevel = Required DatabaseOptional/' "$_tmp_pac" 2>/dev/null
                grep -q '^SigLevel' "$_tmp_pac" 2>/dev/null || echo 'SigLevel = Required DatabaseOptional' >> "$_tmp_pac"
                sync "$_tmp_pac" 2>/dev/null || sync 2>/dev/null || true
                mv -f "$_tmp_pac" /etc/pacman.conf 2>/dev/null
            } || rm -f "$_tmp_pac" 2>/dev/null
        } || sed -i 's/^[[:space:]]*SigLevel.*/SigLevel = Required DatabaseOptional/' /etc/pacman.conf 2>/dev/null || true
    fi
    rm -f /etc/pacman.conf.siglevel-pending /etc/pacman.conf.siglevel-backup 2>/dev/null || true
fi

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
local start_fn="$3"
local retries=5
local count=0

if command -v pgrep >/dev/null 2>&1 && pgrep -x "$pid_ok" >/dev/null 2>&1; then
log_bootstrap "$name already running (pid $(pgrep -x "$pid_ok" 2>/dev/null | head -1))"
return 0
fi

log_bootstrap "Starting $name..."
while [[ $count -lt $retries ]]; do
"$start_fn" >> "$BOOTSTRAP_LOG" 2>&1
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

start_dbus() {
mkdir -p /run/dbus
dbus-daemon --system --fork 2>/dev/null
}

start_polkitd() {
if [[ -x /usr/lib/polkit-1/polkitd ]]; then
/usr/lib/polkit-1/polkitd --no-debug &
fi
}

start_pamac_daemon() {
/usr/bin/pamac-daemon &
}

if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
log_bootstrap "systemd detected, starting services via systemctl"
systemctl start polkit 2>/dev/null || true
systemctl start pamac-daemon >/dev/null 2>&1 || true
else
log_bootstrap "Non-systemd environment, starting services manually"
ensure_service "dbus-daemon" "dbus-daemon" start_dbus
ensure_service "polkitd" "polkitd" start_polkitd
ensure_service "pamac-daemon" "pamac-daemon" start_pamac_daemon
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
# Fake systemd-run for non-systemd containers (Distrobox).
# Mimics the subset of systemd-run used by Pamac/makepkg for DynamicUser builds.
# Logs unrecognized arguments to /tmp/systemd-run-fake.log for diagnostics.
_DSR_LOG="/tmp/systemd-run-fake.log"
_log_dsr() { echo "[$(date '+%H:%M:%S')] $*" >> "$_DSR_LOG" 2>/dev/null; }

# Passthrough: --help and --version are not meaningful here
for _a in "$@"; do
    case "$_a" in
        --help|-h) echo "systemd-run (fake): Mimics systemd-run for DynamicUser AUR builds in non-systemd containers."; echo "Recognized options: --property=DynamicUser=yes, --property=CacheDirectory=*, --property=WorkingDirectory=*, --pipe, --wait, --quiet, --no-block, --description=*, --unit=*, --service-type=*, --user, --uid=*, --gid=*, --setenv=*, --"; exit 0 ;;
        --version) echo "systemd-run (fake) v1.0 (SteamOS-Pamac)"; exit 0 ;;
    esac
done

DYNAMIC_USER=false
CACHE_DIR=""
WORK_DIR=""
SKIP_NEXT=false
PIPE_MODE=false
WAIT_MODE=false
DESCRIPTION=""
UNRECOGNIZED_PROPS=()
CMD_ARGS=()
for arg in "$@"; do
if $SKIP_NEXT; then
SKIP_NEXT=false
continue
fi
case "$arg" in
--service-type=*) continue ;;
--service-type) SKIP_NEXT=true; continue ;;
--pipe) PIPE_MODE=true; continue ;;
--wait) WAIT_MODE=true; continue ;;
--pty|-q|--quiet|--no-block) continue ;;
--description=*) DESCRIPTION="${arg#--description=}"; continue ;;
--description) SKIP_NEXT=true; continue ;;
--unit=*) continue ;;
--unit) SKIP_NEXT=true; continue ;;
--property=DynamicUser=yes) DYNAMIC_USER=true; continue ;;
--property=CacheDirectory=*) CACHE_DIR="${arg#--property=CacheDirectory=}"; continue ;;
--property=WorkingDirectory=*) WORK_DIR="${arg#--property=WorkingDirectory=}"; continue ;;
--property=StateDirectory=*) continue ;;
--property=LogsDirectory=*) continue ;;
--property=RuntimeDirectory=*) continue ;;
--property=Type=*) continue ;;
--property=RemainAfterExit=*) continue ;;
--property=*) UNRECOGNIZED_PROPS+=("$arg"); _log_dsr "WARN: Unrecognized --property: $arg"; continue ;;
--property) SKIP_NEXT=true; continue ;;
--user|--uid=*|--gid=*|--setenv=*) continue ;;
--user|--setenv) SKIP_NEXT=true; continue ;;
--) shift; CMD_ARGS+=("$@"); break ;;
*) CMD_ARGS+=("$arg") ;;
esac
done
if [[ ${#CMD_ARGS[@]} -eq 0 ]]; then
    _log_dsr "ERROR: No command arguments found after parsing. Raw args: $*"
    exit 1
fi
if [[ ${#UNRECOGNIZED_PROPS[@]} -gt 0 ]]; then
    _log_dsr "INFO: Unrecognized properties were ignored (${#UNRECOGNIZED_PROPS[@]} total): ${UNRECOGNIZED_PROPS[*]}"
    _log_dsr "INFO: If AUR builds fail, check $_DSR_LOG for which properties Pamac now expects."
fi
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
_log_dsr "EXEC: sudo -u $BUILD_USER -- cd $WORK_DIR; ${CMD_ARGS[*]}"
exec sudo -u "$BUILD_USER" -H -- bash -c 'cd "$1" 2>/dev/null; shift; exec "$@"' _ "$WORK_DIR" "${CMD_ARGS[@]}"
else
_log_dsr "EXEC: sudo -u $BUILD_USER -- ${CMD_ARGS[*]}"
exec sudo -u "$BUILD_USER" -H -- "${CMD_ARGS[@]}"
fi
else
if [[ -n "$WORK_DIR" ]] && [[ -d "$WORK_DIR" ]]; then cd "$WORK_DIR" 2>/dev/null || true; fi
_log_dsr "EXEC: ${CMD_ARGS[*]}"
exec "${CMD_ARGS[@]}"
fi
SYSTEMD_RUN_FAKE
chmod +x /usr/local/sbin/systemd-run
_atomic_sed_inplace /usr/local/sbin/systemd-run "s/HOST_USER_PLACEHOLDER/$HOST_USER/g"
repaired=$((repaired + 1))
echo "Fake systemd-run repaired."
echo "Unrecognized arguments will be logged to /tmp/systemd-run-fake.log for debugging."

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
    if [[ -s /etc/pacman.conf ]] && [[ "$(tail -c1 /etc/pacman.conf 2>/dev/null)" != "" ]]; then
        printf '\n' >> /etc/pacman.conf
    fi
    printf '[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
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

configure_extra_repos() {
    if [[ "$ENABLE_EXTRA_REPOS" != "true" ]]; then
        log_info "Skipping third-party repositories (use --enable-extra-repos to add them)."
        return
    fi

    log_step "Configuring third-party repositories for broader package availability"

    local repos_script
    read -r -d '' repos_script <<'REPOS_EOF' || true
set -uo pipefail

rm -f /var/lib/pacman/db.lck

# Crash recovery: detect leftover TrustAll from previous interrupted run
_EXTRA_REPOS_SENTINEL="/etc/pacman.conf.extrarepos-pending"
_EXTRA_REPOS_BACKUP="/etc/pacman.conf.extrarepos-backup"
if [[ -f "$_EXTRA_REPOS_SENTINEL" ]]; then
    if [[ -f "$_EXTRA_REPOS_BACKUP" ]]; then
        echo "CRASH RECOVERY: Restoring pacman.conf from backup (TrustAll was in progress)."
        cp -f "$_EXTRA_REPOS_BACKUP" /etc/pacman.conf
    else
        echo "CRASH RECOVERY: TrustAll sentinel found with no backup. Setting safe SigLevel."
        sed -i 's/^SigLevel\s*=\s*TrustAll/SigLevel = Required DatabaseOptional/' /etc/pacman.conf 2>/dev/null || true
    fi
    rm -f "$_EXTRA_REPOS_SENTINEL" "$_EXTRA_REPOS_BACKUP" 2>/dev/null || true
fi

# Crash-safe rollback for TrustAll fallback
_rollback_extra_repos() {
    local exit_code=$?
    if [[ -f "$_EXTRA_REPOS_BACKUP" ]]; then
        if grep -q 'SigLevel\s*=\s*TrustAll' /etc/pacman.conf 2>/dev/null; then
            echo "CRASH RECOVERY: Restoring pacman.conf from backup (exit code $exit_code)..."
            cp -f "$_EXTRA_REPOS_BACKUP" /etc/pacman.conf
        fi
        rm -f "$_EXTRA_REPOS_BACKUP" "$_EXTRA_REPOS_SENTINEL" 2>/dev/null || true
    fi
}
trap _rollback_extra_repos EXIT

_repo_already_enabled() {
    grep -q "^\[$1\]" /etc/pacman.conf
}

_import_key_with_retry() {
    local key_id="$1"
    shift
    local keyserver_urls=("$@")
    local max_attempts=3

    if [[ ${#keyserver_urls[@]} -eq 0 ]]; then
        keyserver_urls=("hkps://keyserver.ubuntu.com" "hkps://keys.openpgp.org" "hkps://pgp.mit.edu")
    fi

    for server in "${keyserver_urls[@]}"; do
        local attempt=1
        while [[ $attempt -le $max_attempts ]]; do
            if timeout 30 pacman-key --recv-key --keyserver "$server" "$key_id" 2>/dev/null; then
                local _verify_fp
                _verify_fp=$(GNUPGHOME=/etc/pacman.d/gnupg gpg --with-colons --list-keys "$key_id" 2>/dev/null \
                    | grep '^fpr' | head -1 | cut -d: -f10 || echo "")
                local _fp_len=${#_verify_fp}
                local _kid_len=${#key_id}
                if [[ -n "$_verify_fp" ]] && {
                    # Full fingerprint match (40 chars) — exact
                    [[ "$_verify_fp" == "$key_id" ]] ||
                    # Long ID (16+ chars) — require exact suffix match (no partial matches)
                    { [[ $_kid_len -ge 16 ]] && [[ "$_verify_fp" == *"$key_id" ]]; } ||
                    # Exact 40-char fingerprint provided by caller — verify full match
                    { [[ $_kid_len -eq 40 ]] && [[ "$_verify_fp" == "$key_id" ]]; }
                }; then
                    timeout 30 pacman-key --lsign-key "$_verify_fp" 2>/dev/null && return 0
                else
                    echo "Fingerprint verification failed for key $key_id (got $_verify_fp)."
                    echo "Short-ID or substring matches are rejected for security. Use full fingerprint (40 chars)."
                fi
            fi
            echo "Key import attempt $attempt/$max_attempts failed for $key_id from $server."
            attempt=$((attempt + 1))
            [[ $attempt -le $max_attempts ]] && sleep 2
        done
    done
    echo "Warning: Could not import key $key_id after ${max_attempts}x${#keyserver_urls[@]} attempts from ${#keyserver_urls[@]} keyservers."
    echo "The key may have been rotated. Try updating the keyring package or importing the key manually."
    return 1
}

_enable_repo_with_fallback() {
    local repo_name="$1"
    local keyring_pkg="$2"
    local default_key_id="$3"
    shift 3
    local mirror_urls=("$@")

    if _repo_already_enabled "$repo_name"; then
        echo "$repo_name repository is already enabled."
        return 0
    fi

    # Allow environment variable override for key ID (e.g. CHAOTIC_AUR_KEY_ID=NEWID)
    local env_var_name
    local _normalized="${repo_name//-/_}"
    env_var_name="${_normalized^^}_KEY_ID"
    local key_id="${!env_var_name:-$default_key_id}"

    echo "Adding repository [$repo_name] (key_id=$key_id)..."

    local server_lines=""
    for url in "${mirror_urls[@]}"; do
        server_lines="${server_lines}Server = $url\n"
    done

    local key_ok=false

    pacman -Sy --noconfirm 2>/dev/null || true

    # Step 1: Install keyring package from already-configured repos (best path)
    if pacman -S --noconfirm --needed "$keyring_pkg" 2>/dev/null; then
        echo "$repo_name keyring installed successfully from repos."
        key_ok=true
    fi

    # Step 2: Download and install keyring package directly from mirrors
    if [[ "$key_ok" != "true" ]]; then
        echo "Attempting direct keyring package download from mirrors..."
        local host_arch
        host_arch=$(uname -m 2>/dev/null || echo "x86_64")
        for url in "${mirror_urls[@]}"; do
            local direct_url="${url}"
            direct_url="${direct_url//\\\$arch/$host_arch}"
            direct_url="${direct_url//\$arch/$host_arch}"
            direct_url="${direct_url//\\\$repo/$repo_name}"
            direct_url="${direct_url//\$repo/$repo_name}"
            local pkg_url="${direct_url%/}/${keyring_pkg}.pkg.tar.zst"
            local pkg_sig_url="${pkg_url}.sig"
            if timeout 30 curl -fsSL --connect-timeout 10 -o "/tmp/${keyring_pkg}.pkg.tar.zst" "$pkg_url" 2>/dev/null; then
                # Verify package signature if available
                local _sig_ok=false
                if timeout 15 curl -fsSL --connect-timeout 5 -o "/tmp/${keyring_pkg}.pkg.tar.zst.sig" "$pkg_sig_url" 2>/dev/null; then
                    if gpg --verify "/tmp/${keyring_pkg}.pkg.tar.zst.sig" "/tmp/${keyring_pkg}.pkg.tar.zst" 2>/dev/null; then
                        _sig_ok=true
                        echo "$repo_name keyring package signature verified."
                    else
                        echo "Warning: $repo_name keyring package signature verification FAILED. Skipping this mirror."
                    fi
                else
                    echo "Warning: $repo_name keyring package has no signature file. Skipping this mirror."
                fi
                if [[ "$_sig_ok" == "true" ]]; then
                    if pacman -U --noconfirm "/tmp/${keyring_pkg}.pkg.tar.zst" 2>/dev/null; then
                        echo "$repo_name keyring installed from direct download: $pkg_url"
                        key_ok=true
                        rm -f "/tmp/${keyring_pkg}.pkg.tar.zst" "/tmp/${keyring_pkg}.pkg.tar.zst.sig"
                        break
                    fi
                fi
                rm -f "/tmp/${keyring_pkg}.pkg.tar.zst" "/tmp/${keyring_pkg}.pkg.tar.zst.sig"
            fi
        done
    fi

    # Step 3: Dynamically discover and import GPG key from repo mirrors
    # Tries to download the signing key directly from the repo's distribution
    # rather than relying on hardcoded fingerprints that may become stale after key rotations.
    if [[ "$key_ok" != "true" ]] && command -v pacman-key >/dev/null 2>&1; then
        echo "Attempting dynamic key discovery from repo mirrors..."
        local host_arch
        host_arch=$(uname -m 2>/dev/null || echo "x86_64")
        for url in "${mirror_urls[@]}"; do
            local direct_url="${url}"
            direct_url="${direct_url//\\\$arch/$host_arch}"
            direct_url="${direct_url//\$arch/$host_arch}"
            direct_url="${direct_url//\\\$repo/$repo_name}"
            direct_url="${direct_url//\$repo/$repo_name}"
            # Try common GPG key distribution filenames used by Arch repos
            for keyfile in "pub.gpg" "archlinuxcn.gpg" "key.gpg"; do
                local key_url="${direct_url%/}/$keyfile"
                local _tmp_key="/tmp/repo-key-discover-${repo_name}.gpg"
                if timeout 15 curl -fsSL --connect-timeout 5 -o "$_tmp_key" "$key_url" 2>/dev/null; then
                    if file "$_tmp_key" 2>/dev/null | grep -qi "GPG\|PGP"; then
                        echo "  Found GPG key at $key_url"
                        if timeout 30 pacman-key --import "$_tmp_key" 2>/dev/null; then
                            # Extract fingerprint and verify it was actually imported into keyring
                            local _imported_fp
                            _imported_fp=$(GNUPGHOME=/etc/pacman.d/gnupg gpg --with-colons --show-keys "$_tmp_key" 2>/dev/null \
                                | grep '^fpr' | head -1 | cut -d: -f10 || echo "")
                            if [[ -n "$_imported_fp" ]] && GNUPGHOME=/etc/pacman.d/gnupg gpg --list-keys "$_imported_fp" >/dev/null 2>&1; then
                                timeout 30 pacman-key --lsign-key "$_imported_fp" 2>/dev/null || true
                                echo "  Dynamically discovered key: ${_imported_fp: -8} (last 8 chars)"
                            fi
                            key_ok=true
                            rm -f "$_tmp_key"
                            break 2
                        fi
                    fi
                    rm -f "$_tmp_key"
                fi
            done
        done
        if [[ "$key_ok" != "true" ]]; then
            echo "  No GPG key found at common mirror paths. Trying keyserver fallback..."
        fi
    fi

    # Step 4: Import the signing key from keyservers as last resort (uses hardcoded fingerprint)
    if [[ "$key_ok" != "true" ]] && command -v pacman-key >/dev/null 2>&1; then
        echo "Attempting key import from keyservers (key_id=$key_id)..."
        echo "Note: If this fails, the key may have been rotated. Set ${env_var_name}=<NEW_KEY_ID> to override."
        if _import_key_with_retry "$key_id"; then
            key_ok=true
        fi
    fi

    # Step 5: Write the repo entry with appropriate SigLevel
    if [[ "$key_ok" == "true" ]]; then
        printf '\n[%s]\nSigLevel = TrustedOnly\n%b' "$repo_name" "$server_lines" >> /etc/pacman.conf
        echo "$repo_name repository configured (TrustedOnly)."
    else
        echo "Warning: All key setup methods failed for $repo_name (key_id=$key_id)."
        echo "SKIPPING $repo_name repository: signature verification cannot be guaranteed."
        echo "Consider manually importing the correct signing key later, or set"
        echo "  ${env_var_name}=<KEY_ID>  before running this script."
    fi

    return 0
}

echo "=== Configuring Chaotic-AUR repository ==="
_enable_repo_with_fallback \
    "chaotic-aur" "chaotic-keyring" "30565AC3868033CA" \
    "https://cdn-mirror.chaotic.cx/chaotic-aur/\$arch" \
    "https://geo-mirror.chaotic.cx/chaotic-aur/\$arch" \
    "https://mirror.chaotic.cx/chaotic-aur/\$arch"
echo "Note: Set CHAOTIC_AUR_KEY_ID=<FINGERPRINT> to override the default signing key."

echo "=== Configuring archlinuxcn repository ==="
_enable_repo_with_fallback \
    "archlinuxcn" "archlinuxcn-keyring" "11C2E2D1D43CF75C" \
    "https://repo.archlinuxcn.org/\$arch" \
    "https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/\$arch" \
    "https://mirror.sjtu.edu.cn/archlinuxcn/\$arch"
echo "Note: Set ARCHLINUXCN_KEY_ID=<FINGERPRINT> to override the default signing key."

echo "=== Configuring endeavouros repository ==="
_enable_repo_with_fallback \
    "endeavouros" "endeavouros-keyring" "F52611D11AFD4556" \
    "https://mirror.freedif.org/EndeavourOS/repo/\$repo/\$arch" \
    "https://mirror.endeavouros.com/EndeavourOS/repo/\$repo/\$arch" \
    "https://mirror.enderunix.org/endeavouros/repo/\$repo/\$arch"
echo "Note: Set ENDEAVOUROS_KEY_ID=<FINGERPRINT> to override the default signing key."

echo "=== Configuring mesa-git repository (disabled by default - can break GPU drivers) ==="
if ! _repo_already_enabled "mesa-git"; then
    echo "Skipping mesa-git repo (can break GPU drivers on Steam Deck)."
    echo "To enable manually, add to /etc/pacman.conf inside the container:"
    echo '  [mesa-git]'
    echo '  SigLevel = TrustedOnly'
    echo '  Server = https://cdn-mirror.chaotic.cx/chaotic-aur/mesa-git/$arch'
else
    echo "mesa-git already enabled."
fi

echo "=== Syncing package databases with new repositories ==="
pacman -Sy --noconfirm 2>/dev/null || echo "Warning: database sync with new repos had issues."

echo "Third-party repository configuration complete."
echo "Available additional repos: chaotic-aur, archlinuxcn, endeavouros"

# Clean up crash recovery files on successful completion
rm -f "$_EXTRA_REPOS_BACKUP" "$_EXTRA_REPOS_SENTINEL" 2>/dev/null || true
REPOS_EOF

    if ! exec_container_script "$repos_script" "extra-repos"; then
        log_warn "Third-party repository setup encountered errors."
        log_info "Individual repos may have failed due to key server or mirror issues."
        log_info "The script will continue — failed repos can be configured later via /etc/pacman.conf inside the container."
    fi
}

install_aur_helper() {
    log_step "Installing AUR helper (yay)"

    if container_user_exec bash -c "command -v yay >/dev/null 2>&1" 2>/dev/null; then
        log_info "AUR helper 'yay' is already installed."
        return 0
    fi

    log_info "Attempting to install yay from prebuilt repositories..."
    if container_root_exec bash -c 'rm -f /var/lib/pacman/db.lck; pacman -Sy --noconfirm 2>/dev/null; pacman -S --noconfirm --needed yay 2>/dev/null; command -v yay >/dev/null 2>&1 && echo __PREBUILT_OK__' 2>/dev/null | grep -q "__PREBUILT_OK__"; then
        log_success "AUR helper yay installed from prebuilt repository."
        return 0
    fi
    log_info "Prebuilt yay not available. Building from source..."

	log_info "Verifying build dependencies (git, base-devel, go) are present..."
	local verify_script
	read -r -d '' verify_script <<'VERIFY_EOF' || true
set -uo pipefail

rm -f /var/lib/pacman/db.lck

_missing=""
command -v git >/dev/null 2>&1 || _missing="$_missing git"
pacman -Qg base-devel >/dev/null 2>&1 || _missing="$_missing base-devel"
command -v go >/dev/null 2>&1 || _missing="$_missing go"

if [[ -n "$_missing" ]]; then
	echo "Missing build dependencies:$_missing — installing..."
	for pkg in $_missing; do
		if [[ "$pkg" == "base-devel" ]]; then
			if ! install_base_devel_batched; then
				echo "FATAL: base-devel installation failed."
				exit 1
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

_assert_installed git
_assert_installed gcc "C compiler"
_assert_installed go "Go compiler"
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
            echo "TLS error detected. Ensuring CA certificates are installed..."
            sudo -Hu "$current_user" bash -lc "pacman -S --noconfirm --needed ca-certificates-mozilla 2>/dev/null || true"
            echo "Retrying clone without disabling SSL verification..."
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
_set_makepkg_jobs
sudo -Hu "$current_user" bash -lc "cd /tmp/yay && makepkg -si --noconfirm --clean"
build_rc=$?

if [[ $build_rc -ne 0 ]]; then
    echo "ERROR: makepkg failed for yay (exit $build_rc)."
    exit 1
fi

if ! command -v yay >/dev/null 2>&1; then
    echo "FATAL: yay binary not found after successful makepkg. Installation may have failed silently."
    echo "Attempting direct reinstall from built package..."
    _yay_pkg=$(ls -t /tmp/yay/*.pkg.tar.* 2>/dev/null | head -1)
    if [[ -n "$_yay_pkg" ]]; then
        pacman -U --noconfirm "$_yay_pkg" || true
    fi
    if ! command -v yay >/dev/null 2>&1; then
        echo "FATAL: yay is still not available after build. Aborting."
        exit 1
    fi
fi
echo "yay verified installed: $(yay --version 2>/dev/null || echo 'unknown version')"
BUILD_EOF

    if ! exec_container_script "$build_script" "yay-build" "$CURRENT_USER"; then
        log_error "Failed to build yay from AUR."
        return 1
    fi

    log_success "AUR helper yay installed."
}

ensure_pamac_aur_compat() {
    log_step "Ensuring pamac-aur AUR compatibility with container pacman"

    local compat_script
    read -r -d '' compat_script <<'COMPAT_EOF' || true
set -uo pipefail

current_user="$1"
pamac_version_pin="${2:-}"

echo "=== pamac-aur AUR Compatibility Auto-Remediation ==="

installed_pacman_ver=""
if command -v pacman >/dev/null 2>&1; then
    installed_pacman_ver=$(pacman -Q pacman 2>/dev/null | awk '{print $2}' || echo "")
fi
echo "Installed pacman version: ${installed_pacman_ver:-unknown}"

if [[ -z "$installed_pacman_ver" ]]; then
    echo "WARN: Cannot determine pacman version. Skipping compatibility check."
    exit 0
fi

sanitize_version_component() {
    # Strip epoch (e.g. "6:5.2.0" -> "5.2.0"), then extract only leading digits.
    # Handles epochs, pre-release suffixes, and non-numeric characters.
    local ver="$1"
    ver="${ver#*:}"
    echo "$ver" | grep -oP '^[0-9]+' || echo "0"
}

pacman_major=$(echo "$installed_pacman_ver" | sanitize_version_component)
# For minor, strip epoch first, then get the second dot-separated component
_pacman_minor_raw=$(echo "$installed_pacman_ver" | sed 's/^[^:]*://')
_pacman_minor_raw=$(echo "$_pacman_minor_raw" | cut -d. -f2)
pacman_minor=$(echo "$_pacman_minor_raw" | grep -oP '^[0-9]*' || echo "0")
[[ -z "$pacman_minor" ]] && pacman_minor=0
echo "Parsed pacman version: major=$pacman_major minor=$pacman_minor (raw: $installed_pacman_ver)"

if [[ -n "$pamac_version_pin" && "$pamac_version_pin" != "latest" ]]; then
    echo "User specified --pamac-version=$pamac_version_pin. Attempting direct install..."
    rm -f /var/lib/pacman/db.lck
    if sudo -Hu "$current_user" bash -lc "yay -S --noconfirm --noprogressbar --clone --noedit 'pamac-aur=$pamac_version_pin'" 2>&1; then
        echo "SUCCESS: pamac-aur $pamac_version_pin installed via --pamac-version."
        exit 0
    fi
    echo "Direct version install failed. Trying git clone approach..."
    rm -rf /tmp/pamac-aur-compat
    if sudo -Hu "$current_user" bash -lc "git clone --depth 1 --branch '$pamac_version_pin' https://aur.archlinux.org/pamac-aur.git /tmp/pamac-aur-compat" 2>&1 || \
       sudo -Hu "$current_user" bash -lc "git clone --depth 1 https://aur.archlinux.org/pamac-aur.git /tmp/pamac-aur-compat && cd /tmp/pamac-aur-compat && git checkout '$pamac_version_pin'" 2>&1; then
        _set_makepkg_jobs
        if sudo -Hu "$current_user" bash -lc "cd /tmp/pamac-aur-compat && makepkg -si --noconfirm --clean" 2>&1; then
            echo "SUCCESS: pamac-aur $pamac_version_pin installed from git."
            rm -rf /tmp/pamac-aur-compat
            exit 0
        fi
    fi
    rm -rf /tmp/pamac-aur-compat
    echo "WARN: --pamac-version=$pamac_version_pin failed. Falling back to automatic detection..."
fi

echo "Fetching latest pamac-aur PKGBUILD from AUR..."

_AUR_CACHE_DIR="/var/cache/pamac-aur-compat"
_AUR_CACHE_FILE="$_AUR_CACHE_DIR/PKGBUILD"
_AUR_CACHE_META="$_AUR_CACHE_DIR/timestamp"
_AUR_CACHE_TTL=86400  # 24 hours

mkdir -p "$_AUR_CACHE_DIR" 2>/dev/null || true

_fetch_aur_pkgbuild() {
    local fetched=""

    # Method 1: AUR RPC v5 JSON API (most stable, no CGIT dependency)
    # Returns package metadata as JSON including Depends/MakeDepends arrays.
    # We format the output as PKGBUILD-like text so downstream grep parsing works.
    local _rpc_url="https://aur.archlinux.org/rpc/v5/info/pamac-aur"
    local _rpc_resp
    _rpc_resp=$(curl -sf --connect-timeout 10 --max-time 30 "$_rpc_url" 2>/dev/null || echo "")
    if [[ -n "$_rpc_resp" ]] && echo "$_rpc_resp" | grep -q '"resultcount":1'; then
        # Extract Depends array elements (handle empty arrays too)
        local _deps_raw _makedeps_raw
        _deps_raw=$(echo "$_rpc_resp" | sed -n 's/.*"Depends":\[\([^]]*\)\].*/\1/p' 2>/dev/null || echo "")
        _makedeps_raw=$(echo "$_rpc_resp" | sed -n 's/.*"MakeDepends":\[\([^]]*\)\].*/\1/p' 2>/dev/null || echo "")
        # Format as PKGBUILD-like lines for downstream grep compatibility
        if [[ -n "$_deps_raw" ]]; then
            _deps_formatted=$(echo "$_deps_raw" | sed 's/","/\n/g; s/"//g')
            echo "depends=($_deps_formatted)"
        fi
        if [[ -n "$_makedeps_raw" ]]; then
            _makedeps_formatted=$(echo "$_makedeps_raw" | sed 's/","/\n/g; s/"//g')
            echo "makedepends=($_makedeps_formatted)"
        fi
        # If we got at least one dependency line, RPC was successful
        if [[ -n "$_deps_raw" || -n "$_makedeps_raw" ]]; then
            echo "# Generated from AUR RPC v5 API"
            return 0
        fi
    fi

    # Method 2: CGIT web endpoint (may be rate-limited by Cloudflare)
    fetched=$(curl -sf --connect-timeout 10 --max-time 30 \
        "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=pamac-aur" 2>/dev/null || echo "")
    if [[ -n "$fetched" ]]; then
        echo "$fetched"
        return 0
    fi
    # Method 3: git clone to read PKGBUILD directly (bypasses web frontend)
    local _git_tmp
    _git_tmp=$(mktemp -d 2>/dev/null || echo "")
    if [[ -n "$_git_tmp" ]]; then
        if git clone --depth 1 --single-branch https://aur.archlinux.org/pamac-aur.git "$_git_tmp/pamac-aur" 2>/dev/null; then
            if [[ -f "$_git_tmp/pamac-aur/PKGBUILD" ]]; then
                cat "$_git_tmp/pamac-aur/PKGBUILD"
                rm -rf "$_git_tmp"
                return 0
            fi
        fi
        rm -rf "$_git_tmp"
    fi
    return 1
}

aur_pkgbuild=""
_cache_age=999999

# Check if a fresh cache exists
if [[ -f "$_AUR_CACHE_FILE" && -f "$_AUR_CACHE_META" ]]; then
    if [[ -r "$_AUR_CACHE_META" ]]; then
        _cached_ts=$(cat "$_AUR_CACHE_META" 2>/dev/null || echo "0")
        _now_ts=$(date +%s 2>/dev/null || echo "0")
        _cache_age=$(( _now_ts - _cached_ts ))
        if [[ $_cache_age -lt 0 ]]; then _cache_age=0; fi
    fi
    if [[ $_cache_age -lt $_AUR_CACHE_TTL ]]; then
        echo "Using cached PKGBUILD (${_cache_age}s old, TTL ${_AUR_CACHE_TTL}s)."
        aur_pkgbuild=$(cat "$_AUR_CACHE_FILE" 2>/dev/null || echo "")
    fi
fi

# Fetch fresh if cache was stale or missing
if [[ -z "$aur_pkgbuild" ]]; then
    echo "Fetching fresh PKGBUILD from AUR..."
    aur_pkgbuild=$(_fetch_aur_pkgbuild 2>/dev/null || echo "")
    if [[ -n "$aur_pkgbuild" ]]; then
        echo "$aur_pkgbuild" > "$_AUR_CACHE_FILE" 2>/dev/null || true
        date +%s > "$_AUR_CACHE_META" 2>/dev/null || true
        echo "PKGBUILD cached for future runs."
    fi
fi

# Stale cache fallback: use outdated cached copy rather than aborting
if [[ -z "$aur_pkgbuild" && -f "$_AUR_CACHE_FILE" ]]; then
    echo "WARN: AUR unreachable and fresh fetch failed. Using stale cached PKGBUILD (${_cache_age}s old)."
    aur_pkgbuild=$(cat "$_AUR_CACHE_FILE" 2>/dev/null || echo "")
fi

if [[ -z "$aur_pkgbuild" ]]; then
    echo "WARN: Could not fetch pamac-aur PKGBUILD from AUR (network issue?). Skipping check."
    exit 0
fi

aur_pacman_dep=$(echo "$aur_pkgbuild" | grep -E "^(depends|makedepends)\\+?=" | grep -oP "pacman[><= ]+[0-9.]+" | head -1 || echo "")
if [[ -z "$aur_pacman_dep" ]]; then
    echo "No explicit pacman version constraint found in pamac-aur PKGBUILD."
    echo "Compatibility assumed. Proceeding."
    exit 0
fi

echo "pamac-aur requires: $aur_pacman_dep"
req_version=$(echo "$aur_pacman_dep" | grep -oP "[0-9.]+" | head -1 || echo "")
req_op=$(echo "$aur_pacman_dep" | grep -oP "[><=]+" | head -1 || echo "")
echo "Required: pacman $req_op $req_version"

req_major=$(echo "$req_version" | sanitize_version_component)
_req_minor_raw=$(echo "$req_version" | cut -d. -f2)
req_minor=$(echo "$_req_minor_raw" | grep -oP '^[0-9]*' || echo "0")
[[ -z "$req_minor" ]] && req_minor=0

version_meets_requirement() {
    local cur_major="$1" cur_minor="$2" op="$3" rq_major="$4" rq_minor="${5:-0}"

    # Use vercmp when available (standard Arch Linux utility that correctly handles
    # epochs like "6:5.2.0", pre-release suffixes like "rc", and package revisions)
    if command -v vercmp >/dev/null 2>&1; then
        local cur_full="${cur_major}.${cur_minor}"
        local rq_full="${rq_major}.${rq_minor}"
        local cmp_result
        cmp_result=$(vercmp "$cur_full" "$rq_full" 2>/dev/null || echo "")
        if [[ -n "$cmp_result" && "$cmp_result" =~ ^-?[0-9]+$ ]]; then
            case "$op" in
                ">="|"="|"==")
                    [[ "$cmp_result" -ge 0 ]] && return 0 || return 1 ;;
                ">")
                    [[ "$cmp_result" -gt 0 ]] && return 0 || return 1 ;;
                "<=")
                    [[ "$cmp_result" -le 0 ]] && return 0 || return 1 ;;
                "<")
                    [[ "$cmp_result" -lt 0 ]] && return 0 || return 1 ;;
                *)
                    return 0 ;;
            esac
        fi
    fi

    # Fallback: manual major.minor comparison (when vercmp is unavailable)
    case "$op" in
        ">="|"="|"==")
            if [[ "$cur_major" -gt "$rq_major" ]]; then return 0; fi
            if [[ "$cur_major" -eq "$rq_major" && "$cur_minor" -ge "$rq_minor" ]]; then return 0; fi
            return 1
            ;;
        ">")
            if [[ "$cur_major" -gt "$rq_major" ]]; then return 0; fi
            if [[ "$cur_major" -eq "$rq_major" && "$cur_minor" -gt "$rq_minor" ]]; then return 0; fi
            return 1
            ;;
        "<=")
            if [[ "$cur_major" -lt "$rq_major" ]]; then return 0; fi
            if [[ "$cur_major" -eq "$rq_major" && "$cur_minor" -le "$rq_minor" ]]; then return 0; fi
            return 1
            ;;
        "<")
            if [[ "$cur_major" -lt "$rq_major" ]]; then return 0; fi
            if [[ "$cur_major" -eq "$rq_major" && "$cur_minor" -lt "$rq_minor" ]]; then return 0; fi
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

if version_meets_requirement "$pacman_major" "$pacman_minor" "$req_op" "$req_major" "$req_minor"; then
    echo "PASS: pacman $installed_pacman_ver satisfies requirement $aur_pacman_dep"
    exit 0
fi

echo "INCOMPATIBLE: pacman $installed_pacman_ver does NOT satisfy $aur_pacman_dep"
echo ""

can_upgrade_pacman=false
if command -v vercmp >/dev/null 2>&1; then
    # Use vercmp for accurate comparison (handles epochs, pre-release suffixes)
    _cmp_result=$(vercmp "$installed_pacman_ver" "$req_version" 2>/dev/null || echo "")
    if [[ -n "$_cmp_result" && "$_cmp_result" =~ ^-?[0-9]+$ ]] && [[ "$_cmp_result" -lt 0 ]]; then
        can_upgrade_pacman=true
    fi
else
    # Fallback: manual major.minor comparison
    if [[ "$req_major" -gt "$pacman_major" ]] || \
       { [[ "$req_major" -eq "$pacman_major" ]] && [[ "$req_minor" -gt "$pacman_minor" ]]; }; then
        can_upgrade_pacman=true
    fi
fi

if [[ "$can_upgrade_pacman" == "true" ]]; then
    echo ">>> Strategy A: Container pacman is TOO OLD (have $installed_pacman_ver, need $req_op $req_version)"
    echo ">>> Attempting to upgrade pacman inside the container to satisfy pamac-aur..."
    rm -f /var/lib/pacman/db.lck
    if pacman -Sy --noconfirm 2>&1 | tail -5; then
        echo "Database synced. Upgrading pacman and dependencies..."
        rm -f /var/lib/pacman/db.lck
        if pacman -S --noconfirm --needed pacman 2>&1 | tail -10; then
            new_ver=$(pacman -Q pacman 2>/dev/null | awk '{print $2}' || echo "")
            echo "Upgraded pacman to: $new_ver"
            new_major=$(echo "$new_ver" | sanitize_version_component)
            _new_minor_raw=$(echo "$new_ver" | sed 's/^[^:]*://' | cut -d. -f2)
            new_minor=$(echo "$_new_minor_raw" | grep -oP '^[0-9]*' || echo "0")
            [[ -z "$new_minor" ]] && new_minor=0
            if version_meets_requirement "$new_major" "$new_minor" "$req_op" "$req_major" "$req_minor"; then
                echo "SUCCESS: Upgraded pacman $new_ver now satisfies $aur_pacman_dep"
                ldconfig 2>/dev/null || true
                exit 0
            fi
            echo "WARNING: Upgraded pacman $new_ver still does not satisfy $aur_pacman_dep"
            echo "Attempting full system upgrade to pull in all dependencies..."
            rm -f /var/lib/pacman/db.lck
            pacman -Syu --noconfirm 2>&1 | tail -20 || true
            new_ver=$(pacman -Q pacman 2>/dev/null | awk '{print $2}' || echo "")
            echo "After full upgrade, pacman version: $new_ver"
            new_major=$(echo "$new_ver" | sanitize_version_component)
            _new_minor_raw2=$(echo "$new_ver" | sed 's/^[^:]*://' | cut -d. -f2)
            new_minor=$(echo "$_new_minor_raw2" | grep -oP '^[0-9]*' || echo "0")
            [[ -z "$new_minor" ]] && new_minor=0
            if version_meets_requirement "$new_major" "$new_minor" "$req_op" "$req_major" "$req_minor"; then
                echo "SUCCESS: Full upgrade brought pacman $new_ver which satisfies $aur_pacman_dep"
                ldconfig 2>/dev/null || true
                exit 0
            fi
        fi
    fi
    echo "WARNING: Could not upgrade pacman to satisfy pamac-aur. Falling back to Strategy B..."
fi

echo ">>> Strategy B: Finding older pamac-aur revision compatible with pacman $installed_pacman_ver..."

# Use git directly to iterate commits — this is frontend-agnostic and does not
# depend on the AUR web interface (CGIT, GitLab, Gitea, etc.).
_AUR_GIT_URL="https://aur.archlinux.org/pamac-aur.git"
_AUR_WORK="/tmp/pamac-aur-compat-history"
rm -rf "$_AUR_WORK"

echo "Cloning pamac-aur repository (shallow) for commit history..."
if ! git clone --depth=50 --single-branch "$_AUR_GIT_URL" "$_AUR_WORK" 2>/tmp/pamac_aur_clone_err; then
    echo "WARN: git clone of pamac-aur failed:"
    cat /tmp/pamac_aur_clone_err 2>/dev/null | tail -3
    rm -rf "$_AUR_WORK"
    echo "WARN: Falling back to Strategy C (build latest regardless of compatibility)."
    echo "COMPATIBLE_COMMIT=latest_anyway"
    exit 3
fi

_commits=$(git -C "$_AUR_WORK" log --format=%H -10 2>/dev/null || true)
if [[ -z "$_commits" ]]; then
    echo "WARN: git log returned no commits."
    rm -rf "$_AUR_WORK"
    echo "WARN: Falling back to Strategy C."
    echo "COMPATIBLE_COMMIT=latest_anyway"
    exit 3
fi

_commit_count=$(echo "$_commits" | wc -l)
echo "Found $_commit_count recent commits. Checking compatibility..."

for try_commit in $_commits; do
    echo "Checking commit: ${try_commit:0:12}..."
    old_pkgbuild=$(git -C "$_AUR_WORK" show "${try_commit}:PKGBUILD" 2>/dev/null || echo "")
    if [[ -z "$old_pkgbuild" ]]; then
        echo "  -> Could not read PKGBUILD at this commit, skipping..."
        continue
    fi

    old_dep=$(echo "$old_pkgbuild" | grep -E "^(depends|makedepends)\\+?=" | grep -oP "pacman[><= ]+[0-9.]+" | head -1 || echo "")
    if [[ -z "$old_dep" ]]; then
        echo "  -> No pacman constraint in this revision (likely compatible)"
        commit_date=$(git -C "$_AUR_WORK" log -1 --format=%ai "$try_commit" 2>/dev/null || echo "unknown date")
        echo "  -> $commit_date"
        rm -rf "$_AUR_WORK"
        echo "FOUND_COMPATIBLE_COMMIT=$try_commit"
        echo "FOUND_COMPATIBLE_REASON=no explicit pacman constraint"
        exit 2
    fi

    old_req_ver=$(echo "$old_dep" | grep -oP "[0-9.]+" | head -1 || echo "")
    old_req_major=$(echo "$old_req_ver" | grep -oP '^[0-9]+' || echo "0")
    old_req_minor=$(echo "$old_req_ver" | cut -d. -f2 | grep -oP '^[0-9]*' || echo "0")
    [[ -z "$old_req_major" ]] && old_req_major=0
    [[ -z "$old_req_minor" ]] && old_req_minor=0
    old_req_op=$(echo "$old_dep" | grep -oP "[><=]+" | head -1 || echo "")

    if version_meets_requirement "$pacman_major" "$pacman_minor" "$old_req_op" "$old_req_major" "$old_req_minor"; then
        echo "  -> Compatible: requires pacman $old_dep (have $installed_pacman_ver)"
        rm -rf "$_AUR_WORK"
        echo "FOUND_COMPATIBLE_COMMIT=$try_commit"
        echo "FOUND_COMPATIBLE_REASON=requires pacman $old_dep"
        exit 2
    fi
    echo "  -> Incompatible: requires pacman $old_dep"
done

rm -rf "$_AUR_WORK"

echo ""
echo "Strategy B exhausted: no compatible older pamac-aur revision found in recent history."
echo "Strategy C: Attempting installation anyway with --noconfirm (build may succeed despite version mismatch)..."
echo "COMPATIBLE_COMMIT=latest_anyway"
exit 3
COMPAT_EOF

    local _preamble="$_CONTAINER_PREAMBLE"

    local _compat_script_file
    _compat_script_file=$(mktemp --tmpdir pamac-compat-XXXXXXXX)
    _TEMP_FILES+=("$_compat_script_file")
    printf '%s\n' "${_preamble}${compat_script}" > "$_compat_script_file"

    local _compat_marker="COMPAT_CHECK_$(head -c 8 /dev/urandom 2>/dev/null | base64 2>/dev/null || echo "$$")"
    printf '\necho "%s"\n' "$_compat_marker" >> "$_compat_script_file"

    set +e
    local _compat_output=""
    if [[ "$LOG_LEVEL" == "verbose" ]]; then
        _compat_output=$(container_root_exec bash -s "$@" < "$_compat_script_file" 2>&1 | tee -a "$LOG_FILE" | _filter_verbose_output)
        _compat_rc=${PIPESTATUS[0]}
    else
        _compat_output=$(container_root_exec bash -s "$@" < "$_compat_script_file" 2>&1)
        _compat_rc=$?
        echo "$_compat_output" >> "$LOG_FILE"
    fi
    set -e

    rm -f "$_compat_script_file"

    _PAMAC_COMPAT_COMMIT=""
    _PAMAC_COMPAT_STRATEGY=""

    case $_compat_rc in
        0)
            if echo "$_compat_output" | grep -q "SUCCESS"; then
                log_success "pamac-aur compatibility resolved: $(echo "$_compat_output" | grep "SUCCESS" | head -1 | sed 's/^[^:]*: //')"
                _PAMAC_COMPAT_STRATEGY="ok"
            else
                log_info "pamac-aur compatibility check passed (no action needed)."
                _PAMAC_COMPAT_STRATEGY="ok"
            fi
            ;;
        2)
            _PAMAC_COMPAT_COMMIT=$(echo "$_compat_output" | grep "^FOUND_COMPATIBLE_COMMIT=" | tail -1 | cut -d= -f2 || echo "")
            local _compat_reason
            _compat_reason=$(echo "$_compat_output" | grep "^FOUND_COMPATIBLE_REASON=" | tail -1 | cut -d= -f2 || echo "")
            if [[ -n "$_PAMAC_COMPAT_COMMIT" ]]; then
                if [[ "$_PAMAC_COMPAT_COMMIT" == "latest_anyway" ]]; then
                    log_warn "No compatible older pamac-aur found. Will attempt latest build anyway."
                    _PAMAC_COMPAT_STRATEGY="try_latest"
                else
                    log_info "Found compatible older pamac-aur revision: ${_PAMAC_COMPAT_COMMIT:0:12}"
                    log_info "Reason: $_compat_reason"
                    _PAMAC_COMPAT_STRATEGY="use_commit"
                fi
            else
                log_warn "Compatibility check found a potential revision but could not parse commit."
                _PAMAC_COMPAT_STRATEGY="try_latest"
            fi
            ;;
        3)
            log_warn "No compatible pamac-aur revision found in AUR history."
            log_info "Will attempt installation of latest pamac-aur (may fail if pacman API changed)."
            _PAMAC_COMPAT_STRATEGY="try_latest"
            ;;
        *)
            if echo "$_compat_output" | grep -q "INCOMPATIBLE"; then
                log_warn "pamac-aur compatibility issue detected but auto-remediation failed."
                log_info "Will attempt installation anyway..."
            else
                log_info "pamac-aur compatibility check completed (minor issues, proceeding)."
            fi
            _PAMAC_COMPAT_STRATEGY="try_latest"
            ;;
    esac

    echo "$_compat_output" | grep -E "^(PASS|SUCCESS|WARNING|Strategy|  ->|Installed|Upgraded|INFO)" | while IFS= read -r line; do
        log_info "  compat: $line"
    done || true

    export _PAMAC_COMPAT_COMMIT
    export _PAMAC_COMPAT_STRATEGY
    return 0
}

install_pamac() {
    log_step "Installing Pamac package manager"

    if container_user_exec bash -c "command -v pamac-manager >/dev/null 2>&1 && command -v pamac >/dev/null 2>&1" 2>/dev/null; then
        log_info "Pamac is already installed (manager + CLI)."
        return 0
    fi

    log_info "Attempting to install pamac-aur from prebuilt repositories..."
    if container_root_exec bash -c 'rm -f /var/lib/pacman/db.lck; pacman -Sy --noconfirm 2>/dev/null; pacman -S --noconfirm --needed pamac-aur 2>/dev/null; command -v pamac-manager >/dev/null 2>&1 && command -v pamac >/dev/null 2>&1 && echo __PREBUILT_OK__' 2>/dev/null | grep -q "__PREBUILT_OK__"; then
        log_success "Pamac installed from prebuilt repository."
        return 0
    fi
    log_info "Prebuilt pamac-aur not available. Building from source..."

    _PAMAC_COMPAT_COMMIT=""
    _PAMAC_COMPAT_STRATEGY=""
    ensure_pamac_aur_compat "$CURRENT_USER" "$PAMAC_VERSION" || true

    local _compat_strategy="${_PAMAC_COMPAT_STRATEGY:-try_latest}"
    local _compat_commit="${_PAMAC_COMPAT_COMMIT:-}"

    if [[ "$_compat_strategy" == "ok" ]]; then
        log_info "pamac-aur is compatible. Proceeding with standard installation."
    elif [[ "$_compat_strategy" == "use_commit" ]]; then
        log_info "Using compatible older pamac-aur revision: ${_compat_commit:0:12}"
    elif [[ "$_compat_strategy" == "try_latest" ]]; then
        log_warn "Will attempt latest pamac-aur (compatibility uncertain)."
    fi

    log_info "Stage 1/2: Installing pamac-aur from AUR..."
    local pamac_install
    read -r -d '' pamac_install <<'PAMAC_INSTALL_EOF' || true
set -uo pipefail

current_user="$1"
compat_strategy="${2:-try_latest}"
compat_commit="${3:-}"

rm -f /var/lib/pacman/db.lck

echo "Installing pamac-aur (strategy: $compat_strategy)..."
pamac_installed=false

if ! sudo -n true 2>/dev/null; then
    echo "Warning: passwordless sudo not available. yay build may hang waiting for password."
    echo "If build hangs, ensure NOPASSWD sudo is configured for the current user in the container."
fi

install_from_aur_commit() {
    local commit="$1"
    local work_dir="/tmp/pamac-aur-pkg-$$"
    echo "Cloning pamac-aur at commit ${commit:0:12}..."
    rm -rf "$work_dir"
    sudo -Hu "$current_user" bash -lc "git clone --depth=50 https://aur.archlinux.org/pamac-aur.git '$work_dir'" 2>/tmp/pamac_clone_err || {
        echo "Git clone failed:"
        cat /tmp/pamac_clone_err 2>/dev/null | tail -5
        return 1
    }
    if ! sudo -Hu "$current_user" bash -lc "cd '$work_dir' && git checkout '$commit'" 2>/tmp/pamac_checkout_err; then
        echo "Checkout failed at depth 50, attempting progressive fetch to reach commit ${commit:0:12}..."
        local _depth=50
        local _max_depth=500
        local _found=false
        while [[ $_depth -lt $_max_depth ]]; do
            _depth=$((_depth + 100))
            if sudo -Hu "$current_user" bash -lc "cd '$work_dir' && git fetch --deepen 100" 2>/dev/null; then
                echo "  Deepened to $_depth commits..."
                if sudo -Hu "$current_user" bash -lc "cd '$work_dir' && git checkout '$commit'" 2>/dev/null; then
                    _found=true
                    echo "  Found commit after deepening to $_depth commits."
                    break
                fi
            else
                echo "  git fetch --deepen failed at depth $_depth. Trying full fetch..."
                sudo -Hu "$current_user" bash -lc "cd '$work_dir' && git fetch --unshallow" 2>/dev/null || true
                if sudo -Hu "$current_user" bash -lc "cd '$work_dir' && git checkout '$commit'" 2>/dev/null; then
                    _found=true
                    echo "  Found commit after full fetch."
                fi
                break
            fi
        done
        if [[ "$_found" != "true" ]]; then
            echo "Checkout failed (commit ${commit:0:12}) after progressive fetch:"
            cat /tmp/pamac_checkout_err 2>/dev/null | tail -5
            sudo -Hu "$current_user" bash -lc "cd '$work_dir' && git log --oneline -5" 2>/dev/null || true
            rm -rf "$work_dir"
            return 1
        fi
    fi
    echo "Building pamac-aur from commit ${commit:0:12}..."
    _set_makepkg_jobs
    sudo -Hu "$current_user" bash -lc "cd '$work_dir' && makepkg -si --noconfirm --clean" 2>/tmp/pamac_build_err
    local build_rc=$?
    rm -rf "$work_dir"
    if [[ $build_rc -eq 0 ]]; then
        return 0
    fi
    echo "Build from commit failed (exit $build_rc):"
    cat /tmp/pamac_build_err 2>/dev/null | tail -15
    return 1
}

install_from_yay() {
    _set_makepkg_jobs
    local _jobs
    _jobs=$(_calc_makepkg_jobs)
    for attempt in 1 2 3; do
        if sudo -Hu "$current_user" bash -lc "MAKEFLAGS=-j${_jobs} yay -S --noconfirm --needed --noprogressbar pamac-aur"; then
            return 0
        fi
        echo "yay install attempt $attempt/3 failed. Retrying in 5 seconds..."
        _safe_sleep 5
        sudo -Hu "$current_user" bash -lc "yay -Y --gendb" 2>/dev/null || true
        rm -f /var/lib/pacman/db.lck
    done
    return 1
}

case "$compat_strategy" in
    use_commit)
        if [[ -n "$compat_commit" ]]; then
            echo "Strategy: install from compatible AUR commit ${compat_commit:0:12}"
            if install_from_aur_commit "$compat_commit"; then
                pamac_installed=true
            else
                echo "Commit install failed. Falling back to yay install..."
                if install_from_yay; then
                    pamac_installed=true
                fi
            fi
        else
            echo "No commit specified. Falling back to yay install..."
            if install_from_yay; then
                pamac_installed=true
            fi
        fi
        ;;
    try_latest|ok|"")
        echo "Strategy: install latest pamac-aur via yay"
        if install_from_yay; then
            pamac_installed=true
        else
            echo "Standard yay install failed. Attempting direct clone..."
            rm -rf /tmp/pamac-aur-fallback
            if sudo -Hu "$current_user" bash -lc "git clone --depth=1 https://aur.archlinux.org/pamac-aur.git /tmp/pamac-aur-fallback" 2>/tmp/pamac_fb_err; then
                _set_makepkg_jobs
                if sudo -Hu "$current_user" bash -lc "cd /tmp/pamac-aur-fallback && makepkg -si --noconfirm --clean" 2>&1 | tail -15; then
                    pamac_installed=true
                fi
                rm -rf /tmp/pamac-aur-fallback
            else
                echo "Direct clone also failed:"
                cat /tmp/pamac_fb_err 2>/dev/null | tail -5
            fi
        fi
        ;;
esac

if [[ "$pamac_installed" != "true" ]]; then
    echo "Error: pamac-aur install failed with all strategies."
    echo ""
    echo "DIAGNOSIS: The pamac-aur AUR package may be incompatible with the current container."
    echo "  - Container pacman version: $(pacman -Q pacman 2>/dev/null | awk '{print $2}')"
    echo "  - If pacman was recently upgraded, pamac-aur may not have been updated yet."
    echo "  - Try: --pamac-version <tag>  (see https://aur.archlinux.org/packages/pamac-aur)"
    echo ""
    exit 1
fi

if ! command -v pamac >/dev/null 2>&1; then
    echo "pamac CLI not found after install. Retrying without --needed..."
    rm -f /var/lib/pacman/db.lck
    _set_makepkg_jobs
    local _jobs
    _jobs=$(_calc_makepkg_jobs)
    sudo -Hu "$current_user" bash -lc "MAKEFLAGS=-j${_jobs} yay -S --noconfirm --noprogressbar pamac-aur" || true
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

    if ! exec_container_script "$pamac_install" "pamac-install" "$CURRENT_USER" "$_compat_strategy" "$_compat_commit"; then
        log_warn "First pamac install attempt failed. Retrying once..."
        container_start 2>/dev/null || true
        sleep 3
        if ! exec_container_script "$pamac_install" "pamac-install-retry" "$CURRENT_USER" "$_compat_strategy" "$_compat_commit"; then
            if ! container_is_usable; then
                log_warn "Container not usable after pamac install retry. Attempting recovery..."
                container_start 2>/dev/null || true
                wait_for_container || {
                    log_error "Container unrecoverable."
                    return 1
                }
                log_info "Retrying pamac install after recovery..."
                if ! exec_container_script "$pamac_install" "pamac-install-recovery" "$CURRENT_USER" "$_compat_strategy" "$_compat_commit"; then
                    log_error "Failed to install Pamac after recovery retry."
                    log_error ""
                    log_error "The pamac-aur AUR package may be broken upstream."
                    log_error "Options:"
                    log_error "  1. Check https://aur.archlinux.org/packages/pamac-aur for current status"
                    log_error "  2. Try: --pamac-version <tag>  to pin a specific working version"
                    log_error "  3. Wait for the AUR maintainer to update pamac-aur for the latest pacman"
                    log_error ""
                    return 1
                fi
            else
                log_error "Failed to install Pamac after retry."
                log_error ""
                log_error "The pamac-aur AUR package may be broken upstream."
                log_error "Options:"
                log_error "  1. Check https://aur.archlinux.org/packages/pamac-aur for current status"
                log_error "  2. Try: --pamac-version <tag>  to pin a specific working version"
                log_error "  3. Wait for the AUR maintainer to update pamac-aur for the latest pacman"
                log_error ""
                return 1
            fi
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

# Atomic pamac.conf editor: avoids sed -i which is non-atomic and can corrupt
# the file if the process is killed mid-write (power loss, SIGKILL).
# Writes to a temp file, applies all edits, fsyncs, then atomically renames.
_atomic_edit_pamac_conf() {
    local target="/etc/pamac.conf"
    local tmp
    tmp=$(mktemp "${target}.atomic.XXXXXX") || { echo "FATAL: mktemp failed for pamac.conf edit"; return 1; }
    cp -f "$target" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    sed -i 's/^#EnableAUR/EnableAUR/' "$tmp"
    sed -i 's/^#CheckAURUpdates/CheckAURUpdates/' "$tmp"
    sed -i 's/^#CheckAURVCSUpdates/CheckAURVCSUpdates/' "$tmp"
    grep -q '^EnableAUR' "$tmp" || printf 'EnableAUR\n' >> "$tmp"
    grep -q '^CheckAURUpdates' "$tmp" || printf 'CheckAURUpdates\n' >> "$tmp"
    if grep -q '^BuildDirectory' "$tmp"; then
        sed -i 's|^BuildDirectory.*|BuildDirectory = /home/'"$current_user"'/\.pamac-build|' "$tmp"
    else
        printf 'BuildDirectory = /home/%s/.pamac-build\n' "$current_user" >> "$tmp"
    fi
    sync "$tmp" 2>/dev/null || sync 2>/dev/null || true
    mv -f "$tmp" "$target"
}

echo "Configuring Pamac for AUR support..."
if [[ -f /etc/pamac.conf ]]; then
    _atomic_edit_pamac_conf
    echo "Pamac configuration updated for AUR support (atomically)."

mkdir -p "/home/$current_user/.pamac-build"
chown "$current_user:$current_user" "/home/$current_user/.pamac-build" 2>/dev/null || true
echo "BuildDirectory set to /home/$current_user/.pamac-build"

echo "Leaving Pamac polkit policy at auth_admin_keep defaults."
pamac_policy="/usr/share/polkit-1/actions/org.manjaro.pamac.policy"
if [[ -f "$pamac_policy" ]]; then
if grep -q '<allow_any>yes</allow_any>' "$pamac_policy"; then
    _atomic_sed_inplace "$pamac_policy" \
        's|<allow_any>yes</allow_any>|<allow_any>auth_admin_keep</allow_any>|' \
        's|<allow_inactive>yes</allow_inactive>|<allow_inactive>auth_admin_keep</allow_inactive>|' \
        's|<allow_active>yes</allow_active>|<allow_active>auth_admin_keep</allow_active>|'
    echo "Restored auth_admin_keep in polkit policy (was previously relaxed to allow_any=yes)."
fi
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

_is_root_writable() {
    [ -w /etc ]
}

configure_ssh_environment() {
    log_step "Configuring SSH environment for nested commands"

    if ! grep -qi steamos /etc/os-release 2>/dev/null; then
        log_info "Not SteamOS, skipping SSH environment setup."
        return 0
    fi

    if ! _is_root_writable; then
        log_info "Root filesystem is read-only – skipping SSH / profile host configuration."
        log_info "These optional tweaks are only needed for advanced SSH remote access."
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

    local _host_is_x11=false
    if [[ -n "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        _host_is_x11=true
    fi

    local _host_bindir="$HOME/.local/bin"
    mkdir -p "$_host_bindir"

    if [[ "$_host_is_x11" == "true" ]]; then
        log_info "X11 session detected. Installing X11 tools for window integration..."
        container_root_exec bash -c 'pacman -S --noconfirm --needed xdotool xorg-xprop xorg-xwininfo 2>/dev/null || echo "Warning: x11 tools install failed (non-fatal)"'

        log_info "Installing xdotool inside container and creating host wrapper..."

        if [[ -x "$_host_bindir/xdotool" ]]; then
            if grep -q "distrobox enter.*xdotool" "$_host_bindir/xdotool" 2>/dev/null; then
                log_info "Updating existing distrobox xdotool wrapper..."
                rm -f "$_host_bindir/xdotool"
            elif file "$_host_bindir/xdotool" 2>/dev/null | grep -q "ELF"; then
                log_info "Host has a native xdotool ELF binary (e.g. via pacman). Skipping wrapper to avoid shadowing."
                _host_bindir_has_xdotool=true
            else
                log_info "Host has a non-wrapper xdotool script at $_host_bindir/xdotool. Skipping wrapper to avoid overwriting."
                _host_bindir_has_xdotool=true
            fi
        fi

        if [[ "${_host_bindir_has_xdotool:-}" != "true" ]] && [[ ! -f "$_host_bindir/xdotool" ]]; then
            cat > "$_host_bindir/xdotool" << XDOTOOL_WRAPPER
#!/bin/bash
exec distrobox enter "$CONTAINER_NAME" -- xdotool "\$@"
XDOTOOL_WRAPPER
            chmod +x "$_host_bindir/xdotool"
            log_success "Created xdotool wrapper at $_host_bindir/xdotool (runs xdotool inside container)"
        fi
    else
        log_info "Wayland session detected (or no DISPLAY). Skipping xdotool compilation."
        log_info "Wayland taskbar integration uses XDG_ACTIVATION_TOKEN — no xdotool needed."
    fi

    local host_tools_available=false
    if command -v xdotool >/dev/null 2>&1 || [[ -x "$_host_bindir/xdotool" ]]; then
        host_tools_available=true
        log_success "X11 window tools available (xdotool — X11 fallback)."
    fi
    if [[ "$host_tools_available" == "false" ]]; then
        log_info "No xdotool available on host. Wayland taskbar integration uses XDG_ACTIVATION_TOKEN (no tools needed)."
    fi

    log_info "Creating pamac-manager launch wrapper inside container..."
    local _desktop_path="/home/${CURRENT_USER}/.local/share/applications/${CONTAINER_NAME}-org.manjaro.pamac.manager.desktop"
    local _wrapper_content
    read -r -d '' _wrapper_content <<'CONTAINER_WRAPPER_EOF'
#!/bin/bash
set +e

/usr/local/bin/pamac-session-bootstrap.sh >/dev/null 2>&1 || true

export DISPLAY=${DISPLAY:-:0}
DESKTOP_FILE="__DESKTOP_PATH__"

pamac-manager "$@" &
PAMAC_PID=$!

# On X11 only, make a single best-effort attempt to set the desktop file hint
# after a brief delay. This avoids the brittle 30-second polling loop that
# depends on xdotool/wlrctl/hyprctl — tools that are increasingly restricted
# by Wayland compositors for security reasons.
if [[ -z "${WAYLAND_DISPLAY:-}" ]] && command -v xprop >/dev/null 2>&1; then
    sleep 3
    for wid in $(xdotool search --class "pamac-manager" 2>/dev/null | head -5); do
        width=$(xwininfo -id "$wid" 2>/dev/null | awk '/Width:/{print $NF}')
        if [[ -n "$width" ]] && [[ "$width" -gt 1 ]]; then
            xprop -id "$wid" -f _KDE_NET_WM_DESKTOP_FILE 8u \
                -set _KDE_NET_WM_DESKTOP_FILE "$DESKTOP_FILE" 2>/dev/null
            break
        fi
    done
fi

wait "$PAMAC_PID" 2>/dev/null
CONTAINER_WRAPPER_EOF
    _wrapper_content="${_wrapper_content/__DESKTOP_PATH__/$_desktop_path}"
    printf '%s\n' "$_wrapper_content" | container_root_exec bash -c 'cat > /usr/local/bin/pamac-manager-wrapper'
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
Name=Pamac
Comment=Add/Remove Software
Exec=${HOME}/.local/bin/pamac-manager-wrapper-host %U
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;PackageManager;Settings;
Keywords=package;manager;software;arch;aur;
StartupNotify=false
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
Name=Pamac
Comment=Add/Remove Software
Exec=${HOME}/.local/bin/pamac-manager-wrapper-host %U
Icon=system-software-install
Terminal=false
Categories=System;PackageManager;Settings;
Keywords=package;manager;software;arch;aur;
StartupNotify=false
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

local gui_wrapper="$bin_dir/pamac-manager-wrapper-host"
cat > "$gui_wrapper" << GUI_WRAPPER_EOF
#!/bin/bash
export HOME="/home/${current_user}"
export DISPLAY=\${DISPLAY:-:0}

# Detect display server
IS_WAYLAND=false
if [[ -n "\${WAYLAND_DISPLAY:-}" ]]; then
    IS_WAYLAND=true
fi

# Dynamically find the XAUTHORITY for the current desktop session
if [[ "\$IS_WAYLAND" == "false" ]]; then
    if [[ -n "\${XAUTH:-}" && -f "\$XAUTH" ]]; then
        export XAUTHORITY="\$XAUTH"
    elif [[ -f "\$HOME/.Xauthority" ]]; then
        export XAUTHORITY="\$HOME/.Xauthority"
    else
        newest_xauth=\$(ls -t /run/user/\$(id -u)/xauth_* 2>/dev/null | head -1)
        if [[ -n "\$newest_xauth" && -f "\$newest_xauth" ]]; then
            export XAUTHORITY="\$newest_xauth"
        fi
    fi
fi

DESKTOP_FILE="\$HOME/.local/share/applications/${CONTAINER_NAME}-org.manjaro.pamac.manager.desktop"

# Ensure ~/.local/bin is in PATH for tools compiled inside the container
if [[ -d "\$HOME/.local/bin" ]]; then
    export PATH="\$HOME/.local/bin:\$PATH"
fi

# Modern desktop environments use XDG_ACTIVATION_TOKEN to match windows to
# .desktop files. Set it before launch so the compositor can associate the
# window correctly — no polling or window-property injection needed.
export XDG_ACTIVATION_TOKEN="${CONTAINER_NAME}-pamac-manager"

# Launch Pamac in the background via distrobox
distrobox enter ${CONTAINER_NAME} -- pamac-manager-wrapper "\$@" &
LAUNCHER_PID=\$!

# On X11 only: make a single best-effort attempt to set the _KDE_NET_WM_DESKTOP_FILE
# property after a brief delay. This is a legacy fallback — modern KDE Plasma (5.27+)
# and GNOME (42+) use StartupWMClass and XDG_ACTIVATION_TOKEN instead.
# We avoid the old 30-second polling loop with xdotool/wlrctl/hyprctl because those
# tools are increasingly restricted by Wayland compositors and are unreliable.
if [[ "\$IS_WAYLAND" == "false" ]] && command -v xprop >/dev/null 2>&1 && command -v xdotool >/dev/null 2>&1; then
    sleep 3
    for wid in \$(xdotool search --class "pamac-manager" 2>/dev/null | head -5); do
        width=\$(xwininfo -id "\$wid" 2>/dev/null | awk -F': ' '/Width:/{print \$2}')
        if [[ -n "\$width" ]] && [[ "\$width" -gt 1 ]]; then
            XAUTHORITY="\$XAUTHORITY" DISPLAY="\$DISPLAY" xprop -id "\$wid" \
                -f _KDE_NET_WM_DESKTOP_FILE 8u \
                -set _KDE_NET_WM_DESKTOP_FILE "\$DESKTOP_FILE" 2>/dev/null
            break
        fi
    done
fi

wait "\$LAUNCHER_PID" 2>/dev/null
GUI_WRAPPER_EOF
chmod +x "$gui_wrapper"
log_info "Created GUI wrapper: $gui_wrapper"

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

_setup_display_env

if command -v notify-send >/dev/null 2>&1; then
notify-send -i package-generic "Uninstalling..." "Removing \$pkg from \$CONTAINER_NAME" 2>/dev/null || true
fi

 if ! command -v "\$CONTAINER_MANAGER" >/dev/null 2>&1; then
 _log "Error: \$CONTAINER_MANAGER not found in PATH"
 echo "Error: \$CONTAINER_MANAGER not found in PATH" >&2
 if command -v notify-send >/dev/null 2>&1; then
 notify-send -i dialog-error "Uninstall Failed" "\$CONTAINER_MANAGER not found" 2>/dev/null || true
 fi
 exit 1
 fi

 _log "Starting container if stopped..."
 "\$CONTAINER_MANAGER" start "\$CONTAINER_NAME" 2>/dev/null || true

 if ! "\$CONTAINER_MANAGER" inspect "\$CONTAINER_NAME" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
echo "Error: Container \$CONTAINER_NAME is not running and could not be started" >&2
_log "Error: Container not running and could not be started"
if command -v notify-send >/dev/null 2>&1; then
notify-send -i dialog-error "Uninstall Failed" "Container \$CONTAINER_NAME is not running" 2>/dev/null || true
fi
exit 1
fi

 _log "Removing \$pkg via pacman -Rns (as root, no D-Bus needed)..."
 if ! echo "\$pkg" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9._+-]*$'; then
 _log "Error: Invalid package name format: '\$pkg'"
 echo "Error: Invalid package name: '\$pkg'" >&2
 exit 1
 fi
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

_log "Cleaning up desktop files for \$pkg..."
local removed_desktops=0
for df in "\$APP_DIR"/"\${CONTAINER_NAME}"-*.desktop; do
[[ -f "\$df" ]] || continue
local df_pkg
df_pkg=\$(grep '^X-SteamOS-Pamac-SourcePackage=' "\$df" 2>/dev/null | cut -d= -f2)
if [[ "\$df_pkg" == "\$pkg" ]]; then
_log "Removing desktop file: \$df"
rm -f "\$df"
removed_desktops=\$((removed_desktops + 1))
fi
done
if [[ \$removed_desktops -gt 0 ]]; then
_log "Removed \$removed_desktops desktop file(s) for \$pkg"
fi

if [[ -f "\$STATE_DIR/exported-apps.list" ]]; then
local tmp_list
tmp_list=\$(mktemp)
while IFS= read -r line; do
[[ -f "\$line" ]] || continue
local line_pkg
line_pkg=\$(grep '^X-SteamOS-Pamac-SourcePackage=' "\$line" 2>/dev/null | cut -d= -f2)
if [[ "\$line_pkg" != "\$pkg" ]]; then
echo "\$line" >> "\$tmp_list"
fi
done < "\$STATE_DIR/exported-apps.list"
mv "\$tmp_list" "\$STATE_DIR/exported-apps.list" 2>/dev/null || true
_log "Updated exported-apps.list (removed entries for \$pkg)"
fi

if command -v update-desktop-database >/dev/null 2>&1; then
update-desktop-database "\$APP_DIR" 2>/dev/null || true
fi
if command -v kbuildsycoca6 >/dev/null 2>&1; then
DISPLAY="\${DISPLAY:-:0}" kbuildsycoca6 --noincremental 2>/dev/null || true
fi
if command -v qdbus6 >/dev/null 2>&1; then
qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.refreshCurrentShell 2>/dev/null || true
elif command -v qdbus >/dev/null 2>&1; then
qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.refreshCurrentShell 2>/dev/null || true
fi
_log "Plasma menu refresh triggered"

if command -v notify-send >/dev/null 2>&1; then
notify-send -i edit-delete "Uninstalled" "\$pkg has been removed successfully." 2>/dev/null || true
fi
_log "Notification sent"
else
echo "Failed to uninstall \$pkg (exit code: \$rc)" >&2
_log "Failed to uninstall \$pkg (exit code: \$rc)"
if command -v notify-send >/dev/null 2>&1; then
notify-send -i dialog-error "Uninstall Failed" "Could not remove \$pkg (exit code: \$rc)" 2>/dev/null || true
fi
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
elif command -v zenity >/dev/null 2>&1; then
log_msg "Attempting zenity confirmation (kdialog not available)..."
zenity --question --text="Remove \$APP_NAME?\nThis was installed via Pamac (AUR)." --title="Uninstall" 2>>"\$LOG_FILE"
ZENITY_RC=\$?
log_msg "zenity exit code: \$ZENITY_RC"
if [[ \$ZENITY_RC -eq 0 ]]; then
CONFIRMED=true
else
log_msg "User cancelled uninstall (zenity rc=\$ZENITY_RC)"
exit 0
fi
else
log_msg "No dialog tool found (kdialog/zenity). Proceeding without confirmation."
CONFIRMED=true
fi

if \$CONFIRMED; then
log_msg "Starting uninstall for \$DESKTOP_BASENAME..."
UNINSTALL_LOG="\$STATE_DIR/uninstall-\$(date +%s).log"

if command -v notify-send >/dev/null 2>&1; then
notify-send -i package-generic "Uninstalling..." "Removing \$APP_NAME..." 2>/dev/null || true
fi

nohup bash -c "
export HOME=/home/${current_user}
export PATH=/home/${current_user}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
export DISPLAY=\$DISPLAY
export WAYLAND_DISPLAY=\$WAYLAND_DISPLAY
export XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR
export DBUS_SESSION_BUS_ADDRESS=\$DBUS_SESSION_BUS_ADDRESS

'\$UNINSTALL_HELPER' --desktop-file '\$DESKTOP_BASENAME' > '\$UNINSTALL_LOG' 2>&1
rc=\\\$?
echo \\\"Exit code: \\\$rc\\\" >> '\$UNINSTALL_LOG'
" &>/dev/null &

disown
log_msg "Uninstall launched in background (nohup)"
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

    _fix_xdg_data_dirs() {
        local current_xdg
        current_xdg=$(systemctl --user show-environment 2>/dev/null | grep '^XDG_DATA_DIRS=' | cut -d= -f2 || echo "")
        if [[ -n "$current_xdg" && ":$current_xdg:" == *":$HOME/.local/share:"* ]]; then
            log_info "XDG_DATA_DIRS already includes ~/.local/share - no fix needed"
            return 0
        fi

        log_info "SteamOS does not include ~/.local/share in XDG_DATA_DIRS for plasmashell."
        log_info "Installing systemd drop-in to fix KDE menu visibility..."

        local new_xdg="$HOME/.local/share"
        local IFS=':'
        for p in $current_xdg; do
            [[ -n "$p" ]] && new_xdg="$new_xdg:$p"
        done

        mkdir -p "$HOME/.config/systemd/user/plasma-plasmashell.service.d"
        cat > "$HOME/.config/systemd/user/plasma-plasmashell.service.d/override-xdg-data-dirs.conf" << XDGOVERRIDE
[Service]
Environment=XDG_DATA_DIRS=${new_xdg}
XDGOVERRIDE

        mkdir -p "$HOME/.config/environment.d"
        cat > "$HOME/.config/environment.d/30-xdg-data-dirs.conf" << XDGCONF
XDG_DATA_DIRS=${new_xdg}
XDGCONF

        systemctl --user daemon-reload 2>/dev/null || true
        export XDG_DATA_DIRS="$new_xdg"
        systemctl --user import-environment XDG_DATA_DIRS 2>/dev/null || true

        log_success "XDG_DATA_DIRS fix installed. Desktop apps in ~/.local/share will appear in KDE menu."
        log_info "Note: If Pamac doesn't appear in the menu immediately, log out and back in."

        if command -v kbuildsycoca6 >/dev/null 2>&1; then
            XDG_DATA_DIRS="$new_xdg" kbuildsycoca6 --noincremental 2>/dev/null || true
            log_info "KDE service cache rebuilt with corrected XDG_DATA_DIRS"
        fi
    }

    _fix_xdg_data_dirs
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
HASH_FILE="\$STATE_DIR/.last-explicit-hash"
echo "\$(date): Hook triggered" > "\$EXPORT_LOG"
mkdir -p "\$APP_DIR" "\$STATE_DIR"
trap 'rm -f "\$EXPLICIT_FILE" "\$NEW_STATE_FILE"' EXIT

pacman -Qeq > "\$EXPLICIT_FILE" 2>/dev/null || true

CURRENT_HASH="\$(md5sum "\$EXPLICIT_FILE" 2>/dev/null | awk '{print \$1}')"
if [[ -f "\$HASH_FILE" ]]; then
    LAST_HASH="\$(cat "\$HASH_FILE" 2>/dev/null || echo "")"
    if [[ "\$CURRENT_HASH" == "\$LAST_HASH" ]]; then
        echo "\$(date): Explicit package list unchanged (hash=\${CURRENT_HASH:0:8}). Skipping export." >> "\$EXPORT_LOG"
        exit 0
    fi
fi
echo "\$CURRENT_HASH" > "\$HASH_FILE" 2>/dev/null || true
echo "\$(date): Package list changed (hash=\${CURRENT_HASH:0:8}). Running export." >> "\$EXPORT_LOG"

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
Name=Pamac
Comment=Add/Remove Software
Exec=\${HOME}/.local/bin/pamac-manager-wrapper-host %U
Icon=system-software-install
Terminal=false
Categories=System;PackageManager;Settings;
Keywords=package;manager;software;arch;aur;
StartupNotify=false
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
[[ "$ENABLE_MULTILIB" == "true" ]] && echo " 32-bit package support enabled"
    [[ "$ENABLE_GAMING_PACKAGES" == "true" ]] && echo " Gaming packages installed"
    [[ "$ENABLE_EXTRA_REPOS" == "true" ]] && echo " Third-party repos enabled: chaotic-aur, archlinuxcn, endeavouros"
    [[ "$ENABLE_BUILD_CACHE" == "true" ]] && echo " Persistent build cache enabled"
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

run_update() {
    log_step "Updating packages in container $CONTAINER_NAME"

    if ! distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        log_error "Container '$CONTAINER_NAME' not found. Run full setup first."
        return 1
    fi

    if ! container_is_usable; then
        log_info "Container not usable, attempting to start..."
        container_start 2>/dev/null || true
        if ! container_is_usable; then
            log_error "Container is not usable after start attempt."
            return 1
        fi
    fi

    log_info "Syncing package databases..."
    if ! container_root_exec bash -c 'rm -f /var/lib/pacman/db.lck; pacman -Syy --noconfirm' 2>/dev/null; then
        log_warn "Database sync had issues. Continuing..."
    fi

    log_info "Running pacman -Syu..."
    if ! container_root_exec bash -c 'rm -f /var/lib/pacman/db.lck; pacman -Syu --noconfirm' 2>/dev/null; then
        log_warn "pacman -Syu had issues."
    fi

    if container_user_exec bash -c "command -v yay >/dev/null 2>&1" 2>/dev/null; then
        log_info "Running yay -Syu..."
        if ! container_user_exec bash -c "yay -Syu --noconfirm --needed --noprogressbar" 2>/dev/null; then
            log_warn "yay -Syu had issues. Some AUR packages may not have updated."
        fi
    else
        log_info "yay not installed, skipping AUR updates."
    fi

    log_success "Package update complete."
}

show_status() {
    setup_colors

    echo -e "${BOLD}${BLUE}Steam Deck Pamac Setup Status v${SCRIPT_VERSION}${NC}"
    echo

    local has_issues=false

    echo -e "${BOLD}--- Container ---${NC}"
    if ! distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        echo -e "  Container: ${RED}NOT FOUND${NC} ('$CONTAINER_NAME')"
        echo -e "  ${YELLOW}Run the full setup to create the container.${NC}"
        echo
        return 1
    fi
    echo -e "  Container: ${GREEN}EXISTS${NC} ('$CONTAINER_NAME')"

    local container_state
    container_state=$(container_get_status_safe)
    case "$container_state" in
        "running")
            if container_is_usable; then
                echo -e "  State:    ${GREEN}RUNNING & RESPONSIVE${NC}"
            else
                echo -e "  State:    ${YELLOW}RUNNING but NOT RESPONSIVE${NC}"
                has_issues=true
            fi
            ;;
        "stopped"|"exited")
            echo -e "  State:    ${YELLOW}STOPPED/EXITED${NC} (may be normal for non-init containers)"
            ;;
        *)
            echo -e "  State:    ${RED}${container_state^^}${NC}"
            has_issues=true
            ;;
    esac

    echo
    echo -e "${BOLD}--- Pamac Installation ---${NC}"
    local pamac_ok=true

    if container_is_usable 2>/dev/null || container_root_exec bash -c "echo ok" 2>/dev/null | grep -q ok; then
        if container_root_exec bash -c "command -v pamac-manager >/dev/null 2>&1 && command -v pamac >/dev/null 2>&1" 2>/dev/null; then
            local pamac_ver
            pamac_ver=$(container_root_exec bash -c "pamac --version 2>/dev/null | head -1" 2>/dev/null || echo "unknown")
            echo -e "  Pamac CLI:     ${GREEN}INSTALLED${NC} ($pamac_ver)"
        else
            echo -e "  Pamac CLI:     ${RED}NOT FOUND${NC}"
            pamac_ok=false
            has_issues=true
        fi

        if container_root_exec bash -c "command -v pamac-manager >/dev/null 2>&1" 2>/dev/null; then
            echo -e "  Pamac Manager: ${GREEN}INSTALLED${NC}"
        else
            echo -e "  Pamac Manager: ${RED}NOT FOUND${NC}"
            pamac_ok=false
            has_issues=true
        fi

        if container_root_exec bash -c "command -v yay >/dev/null 2>&1" 2>/dev/null; then
            echo -e "  AUR helper:    ${GREEN}INSTALLED${NC}"
        else
            echo -e "  AUR helper:    ${YELLOW}NOT FOUND${NC} (yay)"
        fi

        if container_root_exec bash -c "command -v gcc >/dev/null 2>&1 && command -v make >/dev/null 2>&1" 2>/dev/null; then
            echo -e "  Build tools:   ${GREEN}INSTALLED${NC}"
        else
            echo -e "  Build tools:   ${YELLOW}MISSING${NC} (gcc/make)"
        fi
    else
        echo -e "  ${RED}Cannot check Pamac - container is not usable.${NC}"
        has_issues=true
    fi

    echo
    echo -e "${BOLD}--- Desktop Integration ---${NC}"
    local desktop_dir="$HOME/.local/share/applications"
    local exported_count=0
    local state_dir="$HOME/.local/share/steamos-pamac/$CONTAINER_NAME"

    if [[ -f "$state_dir/exported-apps.list" ]]; then
        while IFS= read -r line; do
            [[ -f "$line" ]] && exported_count=$((exported_count + 1))
        done < "$state_dir/exported-apps.list"
    fi

    local desktop_files
    desktop_files=$(find "$desktop_dir" -maxdepth 1 -type f -name "${CONTAINER_NAME}-*.desktop" 2>/dev/null | wc -l || echo "0")

    echo "  Desktop files:  $desktop_files"
    echo "  Exported apps:  $exported_count"

    local bin_dir="$HOME/.local/bin"
    if [[ -f "$bin_dir/pamac-${CONTAINER_NAME}" ]]; then
        echo -e "  CLI wrapper:    ${GREEN}PRESENT${NC} ($bin_dir/pamac-${CONTAINER_NAME})"
    else
        echo -e "  CLI wrapper:    ${YELLOW}MISSING${NC}"
    fi

    if [[ -f "$bin_dir/pamac-manager-wrapper-host" ]]; then
        echo -e "  GUI wrapper:    ${GREEN}PRESENT${NC}"
    else
        echo -e "  GUI wrapper:    ${YELLOW}MISSING${NC}"
    fi

    echo
    if [[ "$has_issues" == "true" ]]; then
        echo -e "${BOLD}${YELLOW}--- Issues Detected ---${NC}"
        echo "  Some components need attention. Run the full setup again to fix:"
        echo "    $0"
        echo
    else
        echo -e "${BOLD}${GREEN}--- All Checks Passed ---${NC}"
        echo
    fi
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

    # Prevent concurrent execution with file locking
    local _lock_file="/tmp/steamos-pamac-setup.lock"
    exec 9>"$_lock_file"
    if ! flock -n 9; then
        log_error "Another instance of this script is already running (lock file: $_lock_file)."
        log_error "If no other instance is running, remove the lock file and try again."
        exit 1
    fi

    if [[ "$UNINSTALL" == "true" ]]; then
        uninstall_setup
        exit 0
    fi

    if [[ "$UPDATE" == "true" ]]; then
        ensure_podman
        run_update
        exit $?
    fi

    if [[ "$STATUS" == "true" ]]; then
        show_status
        exit $?
    fi

    if [[ "$EXPORT_ONLY" == "true" ]]; then
        if ! distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
            log_error "Container '$CONTAINER_NAME' not found. Run full setup first."
            exit 1
        fi
        ensure_podman
        export_pamac_to_host
        setup_post_install_hooks
        export_existing_apps
        log_success "Export-only complete. Apps re-exported to host menu."
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

    check_battery_power || exit 0

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
    check_memory_ok 262144 "container creation" 262144 || {
        log_error "Insufficient memory for container creation (need at least 256MB). Aborting."
        exit 1
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

    # Safety check: detect stale SigLevel=TrustAll from a previous crashed run.
    # The keyring script sets SigLevel=TrustAll temporarily, with a backup for crash recovery.
    # If the script was killed mid-run, the container is left in an insecure state.
    # We MUST detect this BEFORE re-running configure_container_base to prevent re-entering
    # a TrustAll state on top of an already-compromised state.
    if container_is_usable 2>/dev/null; then
        local _stale_siglevel
        _stale_siglevel=$(container_runtime_privileged exec -i -u 0 -e HOME="/root" "$CONTAINER_NAME" \
            bash -c 'grep -q "^SigLevel\s*=\s*TrustAll" /etc/pacman.conf 2>/dev/null && [[ -f /etc/pacman.conf.siglevel-backup ]] && echo "stale"' 2>/dev/null || true)
        if [[ "$_stale_siglevel" == "stale" ]]; then
            log_error "CRITICAL: Container has leftover SigLevel=TrustAll from a previous interrupted run."
            log_error "This means signature verification is disabled, which is a security risk."
            log_error "Attempting automatic recovery from backup..."
            if container_root_exec bash -c 'cp -f /etc/pacman.conf.siglevel-backup /etc/pacman.conf' 2>/dev/null; then
                log_success "Auto-reverted SigLevel from backup. Container is secure."
            else
                log_error "Auto-revert failed. Refusing to proceed until manually fixed."
                log_info "Manual fix: distrobox enter $CONTAINER_NAME -- bash -c '"
                log_info "  cp -f /etc/pacman.conf.siglevel-backup /etc/pacman.conf || true"
                log_info "  sed -i \"s/^SigLevel.*/SigLevel = Required DatabaseOptional/\" /etc/pacman.conf'"
                exit 1
            fi
        fi
        # Also catch TrustAll without backup (worst case: script died before backup was created
        # or backup was cleaned up while SigLevel was still TrustAll)
        _stale_siglevel=$(container_runtime_privileged exec -i -u 0 -e HOME="/root" "$CONTAINER_NAME" \
            bash -c 'grep -q "^SigLevel\s*=\s*TrustAll" /etc/pacman.conf 2>/dev/null && [[ ! -f /etc/pacman.conf.siglevel-backup ]] && echo "trustall_nobak"' 2>/dev/null || true)
        if [[ "$_stale_siglevel" == "trustall_nobak" ]]; then
            log_error "CRITICAL: Container has SigLevel=TrustAll with no backup file."
            log_error "Previous run may have been interrupted before backup was created."
            log_error "Forcing SigLevel to safe default..."
            if container_root_exec bash -c 'tmp=$(mktemp /etc/pacman.conf.atomic.XXXXXX) && cp -f /etc/pacman.conf "$tmp" && sed -i "s/^SigLevel.*/SigLevel = Required DatabaseOptional/" "$tmp" && (grep -q "^SigLevel" "$tmp" || echo "SigLevel = Required DatabaseOptional" >> "$tmp") && sync "$tmp" 2>/dev/null || sync 2>/dev/null || true && mv -f "$tmp" /etc/pacman.conf' 2>/dev/null; then
                log_success "Restored SigLevel to Required DatabaseOptional."
            else
                log_error "Failed to restore SigLevel. Manual intervention required."
                exit 1
            fi
        fi
    fi

    check_memory_ok 262144 "base setup" 262144 || {
        log_error "Insufficient memory for base setup (need at least 256MB). Aborting."
        exit 1
    }

	if ! configure_container_base; then
		log_error "Container base setup failed permanently. Aborting installation."
		exit 1
	fi

	_ensure_healthy_or_recreate "before critical helpers check" || exit 1
	ensure_critical_helpers

	_ensure_healthy_or_recreate "before mirror optimization" || exit 1
	optimize_pacman_mirrors

	_ensure_healthy_or_recreate "before multilib setup" || exit 1
configure_multilib

    _ensure_healthy_or_recreate "before extra repos setup" || exit 1
    configure_extra_repos

    _ensure_healthy_or_recreate "after base setup" || exit 1

	check_memory_ok 524288 "AUR helper build" 262144 || {
		log_error "Insufficient memory for AUR helper build (need at least 256MB). Aborting."
		exit 1
	}
	check_battery_power || log_warn "Battery low, but continuing AUR helper build..."

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
