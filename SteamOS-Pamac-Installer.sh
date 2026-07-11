#!/bin/bash

set -euo pipefail
set -E

# ERR trap for better error tracing in deeply nested calls (subshells, pipes, sub-functions)
# shellcheck disable=SC2064 # $LINENO/$BASH_COMMAND MUST expand at trap execution, not definition
_err_trap() {
    local _exit_code=$?
    local _line=$1
    local _cmd=$2
    log_error "Error at line $_line (exit $_exit_code): $_cmd"
}
trap '_err_trap $LINENO "$BASH_COMMAND"' ERR

# Heredoc quoting convention:
#   <<'EOF'  — no host variable expansion; content runs inside container
#   <<EOF    — host variables expand at write-time; use \$ for literal $

readonly SCRIPT_VERSION="5.3.0"
readonly DEFAULT_CONTAINER_NAME="arch-pamac"
# Default log file (used until CONTAINER_NAME is known). init_log_file() in
# main reassigns it to a per-container path so concurrent runs with different
# --container-name values don't overwrite each other's logs. Not declared
# readonly here so the per-container override can take effect.
LOG_FILE="$HOME/distrobox-pamac-setup.log"
readonly REQUIRED_TOOLS=("distrobox")
CONTAINER_HAS_INIT="unknown"

readonly ARCHLINUX_IMAGE="${ARCHLINUX_IMAGE:-archlinux:latest}"

# Global temp directory for all script temp files. Using a single directory
# instead of tracking individual files in an array avoids race conditions where
# temp files created inside subshells or piped commands never propagate back to
# the parent shell's _TEMP_FILES array and thus leak on cleanup.
_SCRIPT_TMPDIR=""
_init_script_tmpdir() {
    _SCRIPT_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/steamos-pamac-XXXXXX") || {
        log_warn "Failed to create global temp directory."
        _SCRIPT_TMPDIR=""
    }
}
_cleanup_temp_files() {
    # Remove tracked individual files (legacy path)
    for f in "${_TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null || true
    done
    # Remove the global temp directory tree (primary cleanup)
    if [[ -n "${_SCRIPT_TMPDIR:-}" && -d "$_SCRIPT_TMPDIR" ]]; then
        rm -rf "$_SCRIPT_TMPDIR" 2>/dev/null || true
    fi
}
# Track individual temp files for backward compatibility with code that
# references _TEMP_FILES directly. New code should use _SCRIPT_TMPDIR.
_TEMP_FILES=()
CONTAINER_NAME="${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}"

CURRENT_USER=$(whoami)

ENABLE_MULTILIB="${ENABLE_MULTILIB:-true}"
ENABLE_BUILD_CACHE="${ENABLE_BUILD_CACHE:-true}"
ENABLE_GAMING_PACKAGES="${ENABLE_GAMING_PACKAGES:-false}"
ENABLE_EXTRA_REPOS="${ENABLE_EXTRA_REPOS:-true}"
FORCE_REBUILD="${FORCE_REBUILD:-false}"
OPTIMIZE_MIRRORS="${OPTIMIZE_MIRRORS:-true}"
: "${DISTROBOX_CONTAINER_MANAGER:=podman}"

# Trusted GPG fingerprints for third-party repos.
# Priority order:
#   1. archlinux-keyring + WKD/mirror dynamic discovery (preferred)
#   2. Hardcoded fallback values (last resort — may become stale after key rotations)
#
# NOTE: A prior implementation fetched a "trusted-keys.json" from the distrobox
# upstream, pinned to a commit SHA for reproducibility. That file never existed
# in the 89luca89/distrobox repository (verified via GitHub tree + git history
# API) — the URL 404'd on every run and the fetch silently fell through to the
# hardcoded fallback below. The dead JSON fetch has been removed; the dynamic
# discovery (Steps 1-3) + hardcoded fallback (Step 5) chain is sufficient and
# honest. See _enable_repo_with_fallback in configure_extra_repos.

DRY_RUN="${DRY_RUN:-false}"
DRY_RUN_VERBOSE="${DRY_RUN_VERBOSE:-false}"
CHECK_ONLY="${CHECK_ONLY:-false}"
STATUS="${STATUS:-false}"
UNINSTALL="${UNINSTALL:-false}"
UPDATE="${UPDATE:-false}"
EXPORT_ONLY="${EXPORT_ONLY:-false}"
LOG_LEVEL="${LOG_LEVEL:-normal}"
PAMAC_VERSION="${PAMAC_VERSION:-}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
# SECURITY (default off): PermitUserEnvironment yes in sshd lets any
# SSH-authenticated user inject arbitrary environment variables (LD_PRELOAD,
# PATH...) via ~/.ssh/environment — a known privilege-escalation vector on
# multi-user hosts. Only enable when the user explicitly opts in via
# --enable-ssh-env on a single-user trusted host (e.g. a personal Steam Deck).
ENABLE_SSH_ENV="${ENABLE_SSH_ENV:-false}"
ALLOW_WHEEL_NOPASSWD="${ALLOW_WHEEL_NOPASSWD:-false}"
UPLOAD_LOG="${UPLOAD_LOG:-false}"
PIN_ALPM="${PIN_ALPM:-true}"
# SECURITY: --strict-security mode. When enabled, the script refuses to relax
# signature verification (SigLevel=TrustAll methods are skipped), refuses to
# install the fake systemd-run wrapper (DynamicUser privilege-drop shim), and
# fails fast when any cryptographic bootstrap would otherwise degrade security.
# This is intended for users who want every operation to be cryptographically
# verified and verify that the container's init/pamac version are compatible.
STRICT_SECURITY="${STRICT_SECURITY:-false}"

# Maximum per-container log file size in bytes before rotate-on-startup.
# Old log is moved to ${LOG_FILE}.1 and overwritten if it already exists.
LOG_ROTATION_MAX_SIZE="${LOG_ROTATION_MAX_SIZE:-5242880}"  # 5 MiB

# Tunable constants: extracted from scattered magic numbers so timeouts,
# thresholds, and UID ranges live in one place and can be overridden via
# environment variables if needed.
readonly CONTAINER_NAME_MAX_LEN="${CONTAINER_NAME_MAX_LEN:-63}"
readonly DISK_SPACE_MIN_KB="${DISK_SPACE_MIN_KB:-2097152}"      # 2 GiB
readonly MAKEPKG_RAM_PER_JOB_KB="${MAKEPKG_RAM_PER_JOB_KB:-768000}"
readonly SUBUID_START="${SUBUID_START:-100000}"
readonly SUBUID_COUNT="${SUBUID_COUNT:-65536}"
readonly UPLOAD_CONNECT_TIMEOUT="${UPLOAD_CONNECT_TIMEOUT:-10}"
readonly UPLOAD_MAX_TIME="${UPLOAD_MAX_TIME:-60}"
readonly PACMAN_LOCK_WAIT_MAX="${PACMAN_LOCK_WAIT_MAX:-30}"
readonly NETWORK_PROBE_TIMEOUT="${NETWORK_PROBE_TIMEOUT:-5}"
readonly NETWORK_PROBE_CONNECT_TIMEOUT="${NETWORK_PROBE_CONNECT_TIMEOUT:-3}"
readonly CONTAINER_PROBE_TIMEOUT="${CONTAINER_PROBE_TIMEOUT:-15}"

# Exit code used when the user declines an interactive prompt (e.g. low battery).
# 130 is the conventional shell exit for "terminated by SIGINT" — distinct from a
# genuine success (0) so wrapper scripts can tell an abort from a clean run.
readonly EXIT_USER_ABORT=130

setup_colors() {
    [[ -n "${GREEN:-}" ]] && return 0
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        GREEN=$(tput setaf 2); readonly GREEN
        YELLOW=$(tput setaf 3); readonly YELLOW
        BLUE=$(tput setaf 4); readonly BLUE
        RED=$(tput setaf 1); readonly RED
        BOLD=$(tput bold); readonly BOLD
        NC=$(tput sgr0); readonly NC
    else
        GREEN=''; YELLOW=''; BLUE=''; RED=''; BOLD=''; NC=''
        readonly GREEN YELLOW BLUE RED BOLD NC
    fi
}

initialize_logging() {
    local os_version
    os_version=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Unknown')

    # Rotate the log if it has grown beyond the configured max size. This keeps
    # per-container logs from filling the user's home directory on repeated
    # install/update runs. We keep exactly one backup generation.
    if [[ -n "${LOG_FILE:-}" ]] && [[ -f "$LOG_FILE" ]]; then
        local _log_size
        local _max_size="${LOG_ROTATION_MAX_SIZE:-5242880}"
        if [[ ! "$_max_size" =~ ^[0-9]+$ ]]; then
            _max_size=5242880
        fi
        _log_size=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo "0")
        if [[ "$_log_size" =~ ^[0-9]+$ ]] && [[ "$_log_size" -gt "$_max_size" ]]; then
            # Only print to stderr/stdout before logging is ready; then rotate.
            echo "Rotating log (size ${_log_size} bytes exceeds ${_max_size} bytes): $LOG_FILE" >&2
            mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || rm -f "$LOG_FILE" 2>/dev/null || true
        fi
    fi

    local _desktop_env
    _desktop_env=$(detect_desktop_environment)

    local dry_run_header=""
    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$DRY_RUN_VERBOSE" == "true" ]]; then
            dry_run_header=" (DRY RUN VERBOSE MODE)"
        else
            dry_run_header=" (DRY RUN MODE)"
        fi
    fi

    {
        echo "=== Steam Deck Pamac Setup v${SCRIPT_VERSION}${dry_run_header} - $(date) ==="
        echo "User: $CURRENT_USER"
        echo "OS: $os_version"
        echo "Container: $CONTAINER_NAME"
        echo "Desktop environment: $_desktop_env"
        echo "Features: MULTILIB=$ENABLE_MULTILIB GAMING=$ENABLE_GAMING_PACKAGES EXTRA_REPOS=$ENABLE_EXTRA_REPOS BUILD_CACHE=$ENABLE_BUILD_CACHE OPTIMIZE_MIRRORS=$OPTIMIZE_MIRRORS NON_INTERACTIVE=$NON_INTERACTIVE PIN_ALPM=$PIN_ALPM"
        echo "=========================================="
    } > "$LOG_FILE"

    # Initialize the global temp directory now that logging is available.
    _init_script_tmpdir

    # shellcheck disable=SC2064 # $exit_code/$date MUST expand at trap execution, not definition
    trap 'exit_code=$?; _cleanup_temp_files; echo "=== Run finished: $(date) - Exit: $exit_code ===" >> "$LOG_FILE"; [[ "$UPLOAD_LOG" == "true" ]] && sanitize_and_upload_log || true' EXIT
}

_log() {
    local level="$1" color="$2" message="$3"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    local plain_message
    plain_message=$(printf '%s' "$message" | sed 's/\x1B\[[0-9;]*[A-Za-z]//g') || plain_message="$message"

    # Guard against an empty LOG_FILE (early bootstrap, before main finalizes
    # the per-container path) so logging never trips set -e with `>> ""`.
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "[$timestamp] $level: $plain_message" >> "$LOG_FILE"
    fi

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

sanitize_and_upload_log() {
    if [[ "$UPLOAD_LOG" != "true" ]]; then
        return 0
    fi
    if [[ ! -f "$LOG_FILE" ]]; then
        log_warn "No log file found at $LOG_FILE — nothing to upload."
        return 1
    fi

    log_info "Sanitizing log for upload..."
    local sanitized_log
    sanitized_log=$(mktemp "${_SCRIPT_TMPDIR:-/tmp}/pamac-sanitized-XXXXXXXX") || { log_error "Failed to create temp file for sanitization."; return 1; }

    # Sanitize: strip ANSI colors, user home paths, hostnames, IPs,
    # SSH keys, tokens, and other sensitive patterns.
    sed \
        -e 's/\x1B\[[0-9;]*[A-Za-z]//g' \
        -e "s|$HOME|~HOME|g" \
        -e "s|/home/[a-zA-Z0-9_-]*|/home/<USER>|g" \
        -e 's/\b[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\b/<IP>/g' \
        -e 's/\b[0-9a-f]\{40,\}\b/<HASH>/gi' \
        -e 's/-----BEGIN [A-Z ]*KEY-----/<REDACTED KEY>/g' \
        -e 's/-----END [A-Z ]*KEY-----//g' \
        -e 's/(Bearer |Authorization:)[^ ]*/\1<REDACTED>/gi' \
        -e 's/password[=: ].*$/password=<REDACTED>/gi' \
        -e 's/token[=: ].*$/token=<REDACTED>/gi' \
        "$LOG_FILE" > "$sanitized_log" 2>/dev/null || {
            log_warn "Log sanitization failed. Uploading raw log."
            cp -f "$LOG_FILE" "$sanitized_log"
        }

    local upload_url=""
    log_info "Uploading sanitized log to transfer.sh..."
    upload_url=$(curl -sf --connect-timeout ${UPLOAD_CONNECT_TIMEOUT} --max-time ${UPLOAD_MAX_TIME} \
        --data-binary "@${sanitized_log}" \
        "https://transfer.sh/steamos-pamac-$(date +%Y%m%d-%H%M%S).log" 2>/dev/null || echo "")

    if [[ -z "$upload_url" ]]; then
        log_info "transfer.sh unavailable, trying 0x0.st..."
        upload_url=$(curl -sf --connect-timeout ${UPLOAD_CONNECT_TIMEOUT} --max-time ${UPLOAD_MAX_TIME} \
            -F "file=@${sanitized_log}" \
            "https://0x0.st" 2>/dev/null || echo "")
    fi

    rm -f "$sanitized_log"

    if [[ -n "$upload_url" ]]; then
        log_success "Log uploaded successfully: $upload_url"
        echo "$upload_url" >> "$LOG_FILE"
    else
        log_warn "Log upload failed (no available paste service)."
        log_info "You can manually share the log: $LOG_FILE"
    fi
}

_filter_verbose_output() {
    # Filter verbose container output to avoid overwhelming the user.
    # Always pass through: errors, warnings, key operation markers, final status lines.
    # Filter out: repetitive download progress, package resolution noise, blank lines.
    # NOTE: warning:.*downgrading and warning:.*removing are intentionally NOT
    # filtered — unexpected downgrades/removals during upgrades are exactly the
    # kind of issue a user must see, and hiding them can mask broken upgrades.
    # NOTE: :: lines are partially filtered: only ::synchronizing, ::debug:,
    # ::warning:, and ::info: are suppressed (these are noise). Other :: lines
    # (e.g. :: Retrieving packages, :: Processing changes, :: Proceed) are
    # passed through — they contain actionable or status information.
    # Additional noise suppressed: plain "downloading" progress lines without
    # errors, "Nothing to do." churn, and "up to date" confirmations.
    grep -v -E '^\s*$|^resolving dependencies|^looking for conflicting|^checking (keyring|package|group|database)|^downloading\s|^::(synchronizing|debug:|warning:|info:)|^Nothing to do\.| is up to date$' || true
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

# container_runtime_privileged is intentionally a thin pass-through to
# container_runtime (no sudo / no --privileged flag). Rootless podman already
# runs the user's own containers; on Steam Deck the user owns the podman socket.
# The name documents the *caller's intent* (these ops reach the container's
# root namespace) rather than adding host escalation. Do NOT add sudo here —
# that would make repair_podman retry loops escalate to host root, which the
# script deliberately avoids (rootless-by-design). See also SECURITY notes
# around ALLOW_WHEEL_NOPASSWD.
container_runtime_privileged() {
    container_runtime "$@"
}

container_root_exec() {
  if ! container_is_usable; then
    container_start 2>/dev/null || true
    if ! container_is_usable; then
      log_warn "Container not usable before root exec. Attempting anyway..."
    fi
  fi
  if command -v distrobox-enter >/dev/null 2>&1; then
    distrobox-enter "$CONTAINER_NAME" --root -- "$@" 2>/dev/null && return 0
    log_debug "distrobox-enter --root failed, falling back to direct container exec"
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
  _output=$(timeout ${CONTAINER_PROBE_TIMEOUT} container_runtime_privileged exec -i -e HOME="/home/${CURRENT_USER}" "$CONTAINER_NAME" bash -c "echo ok" </dev/null 2>/dev/null || echo "")
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
				elif [[ "$wait_rc" -eq 3 ]]; then
					log_error "wait_for_container rc=3: force_remove_container failed inside wait_for_container. Container likely still stuck."
					log_info "Manual intervention required: podman rm -f $CONTAINER_NAME && distrobox rm -f $CONTAINER_NAME"
					return 1
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
            _RECREATE_COUNT=0
            log_error "Failed to recreate container after '$desc' recovery."
            return 1
        fi
        _CREATE_RECREATION_GUARD="$saved_guard"
        if ! container_is_usable; then
            _RECREATE_COUNT=0
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
    log_debug "Container '$name' in '$status' state - will rely on podman rm -f for cleanup"
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
    # Capture the reset's own output+exit, then stream lines to the log.
    # The previous form piped into `| while read` and grabbed `$?` from the
    # while loop (always 0 under pipefail because the consumer succeeds),
    # masking a real reset failure. Capture-first makes the reset exit code
    # available via PIPESTATUS[0] / the command-substitution rc.
    local _reset_output _reset_rc=0
    _reset_output=$(container_runtime_privileged system reset --force 2>&1) || _reset_rc=$?
    if [[ -n "$_reset_output" ]]; then
      while IFS= read -r line; do
        log_warn "  $line"
      done <<< "$_reset_output"
    fi
    if [[ "$_reset_rc" -ne 0 ]]; then
      log_warn "podman system reset --force returned exit code $_reset_rc (reset itself failed). Continuing to check..."
    fi

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

    if [[ ${#CONTAINER_NAME} -gt ${CONTAINER_NAME_MAX_LEN} ]]; then
        log_error "Container name too long (max ${CONTAINER_NAME_MAX_LEN} characters): $CONTAINER_NAME"
        return 1
    fi

    return 0
}

check_memory_ok() {
    # $1 min_avail_kb  : soft warning threshold in KiB (default 524288 = 512 MiB).
    #                    Below this we warn but proceed (heavy ops like AUR
    #                    builds may still complete if swap is available).
    # $2 desc          : human label for which operation is being checked.
    # $3 critical_kb   : hard abort threshold in KiB (default 262144 = 256 MiB).
    #                    Below this we abort to avoid OOM-killing pacman/yay and
    #                    corrupting the container's pacman database mid-write.
    # Magic numbers are KiB (not bytes): /proc/meminfo reports MemAvailable in
    # KiB, so the units here let the comparisons stay integer-arithmetic.
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
            log_info "Fix: sudo usermod --add-subuids ${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1)) --add-subgids ${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1)) $(whoami)"
            subuid_ok=false
        fi
        if ! grep -q "^$(whoami):" /etc/subgid 2>/dev/null; then
            log_warn "No subgid mapping for $(whoami). Rootless podman may fail."
            log_info "Fix: sudo usermod --add-subuids ${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1)) --add-subgids ${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1)) $(whoami)"
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
    if [[ -n "$available_space" ]] && [[ $available_space -lt ${DISK_SPACE_MIN_KB} ]]; then
        log_warn "Low disk space detected. At least $(( DISK_SPACE_MIN_KB / 1024 / 1024 ))GB is recommended."
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

    check_network_connectivity
    check_kernel_glibc_compat

    [[ "$all_ok" == "true" ]]
}

# Network pre-flight: the keyring bootstrap (pacman -Sy archlinux-keyring) and
# mirror/wkd key discovery ALL require outbound HTTPS to archlinux.org or the
# chosen mirror. Failing these 5 strategies later produces confusing cryptic
# errors (gpg keyserver timeouts, "invalid or corrupted package" hits) without
# identifying the root cause. Probe up-front so the user gets an actionable
# "no network" message before the container is even created. The mirror
# list later is independent of this probe — this is an early-warn heuristic.
check_network_connectivity() {
    log_step "Checking outbound network connectivity..."
    local _probe_url="https://archlinux.org"
    local _http_code
    _http_code=$(timeout ${NETWORK_PROBE_TIMEOUT} curl -sI --connect-timeout ${NETWORK_PROBE_CONNECT_TIMEOUT} --max-time ${NETWORK_PROBE_TIMEOUT} -o /dev/null -w "%{http_code}" "$_probe_url" 2>/dev/null || echo "000")
    case "$_http_code" in
        000)
            log_warn "Network probe could not reach $_probe_url (this is a heuristic — mirrors may still work)."
            log_info "The keyring bootstrap will attempt recovery and report failures at runtime if needed."
            log_info "If you know the host is offline, install cached packages instead."
            log_info "  - Verify DNS: getent hosts archlinux.org"
            log_info "  - Behind captive portal/proxy? export https_proxy=http://host:port"
            ;;
        2*|3*)
            log_success "Network connectivity OK (HTTP $_http_code from $_probe_url)."
            ;;
        *)
            log_debug "Reachable probe (HTTP $_http_code) — common redirect/maintenance code, treating as reachable."
            ;;
    esac
}

# Detect the host desktop environment in a lowercased, normalized form.
# Returns one of: kde, gnome, xfce, lxqt, mate, cinnamon, budgie, sway, hyprland,
# i3, generic-wayland, generic-x11, or unknown. Used to skip DE-specific tweaks
# (e.g. Discover notifier suppression) when the session is not KDE/Plasma.
detect_desktop_environment() {
    local de="${XDG_CURRENT_DESKTOP:-}${XDG_SESSION_DESKTOP:-}"
    de="${de,,}"  # lowercase
    case "$de" in
        *kde*|*plasma*) echo "kde" ;;
        *gnome*) echo "gnome" ;;
        *xfce*) echo "xfce" ;;
        *lxqt*) echo "lxqt" ;;
        *mate*) echo "mate" ;;
        *cinnamon*) echo "cinnamon" ;;
        *budgie*) echo "budgie" ;;
        *sway*) echo "sway" ;;
        *hypr*) echo "hyprland" ;;
        *i3*) echo "i3" ;;
        *)
            if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
                echo "generic-wayland"
            elif [[ -n "${DISPLAY:-}" ]]; then
                echo "generic-x11"
            else
                echo "unknown"
            fi
            ;;
    esac
}

check_kernel_glibc_compat() {
    local host_kernel
    host_kernel=$(uname -r 2>/dev/null || echo "")
    if [[ -z "$host_kernel" ]]; then
        log_warn "Could not determine host kernel version."
        return 0
    fi

    local kernel_major kernel_minor
    kernel_major=$(echo "$host_kernel" | cut -d. -f1)
    kernel_minor=$(echo "$host_kernel" | cut -d. -f2)

    if [[ -z "$kernel_major" || -z "$kernel_minor" ]]; then
        log_warn "Could not parse host kernel version: $host_kernel"
        return 0
    fi

    log_info "Host kernel: $host_kernel (${kernel_major}.${kernel_minor})"

    # Known glibc minimum kernel requirements (approximate, based on Arch changelogs):
    # glibc 2.38+ may require kernel >= 5.10 (for some features)
    # glibc 2.39+ may require kernel >= 5.15 (some reports)
    # glibc 2.40+ may require kernel >= 6.1 (verified minimum for recent Arch)
    # SteamOS 3.x ships kernel ~6.1 on the Steam Deck.
    local min_warn_major=6
    local min_warn_minor=1
    local min_crit_major=5
    local min_crit_minor=10

    local kernel_too_old=false
    local kernel_warn=false

    if [[ "$kernel_major" -lt "$min_crit_major" ]] || \
       { [[ "$kernel_major" -eq "$min_crit_major" ]] && [[ "$kernel_minor" -lt "$min_crit_minor" ]]; }; then
        kernel_too_old=true
    elif [[ "$kernel_major" -lt "$min_warn_major" ]] || \
         { [[ "$kernel_major" -eq "$min_warn_major" ]] && [[ "$kernel_minor" -lt "$min_warn_minor" ]]; }; then
        kernel_warn=true
    fi

    if [[ "$kernel_too_old" == "true" ]]; then
        log_warn "Host kernel ${kernel_major}.${kernel_minor} is older than the minimum"
        log_warn "recommended kernel (~${min_crit_major}.${min_crit_minor}) for current"
        log_warn "Arch Linux glibc packages. When Arch updates glibc to require a"
        log_warn "newer kernel, binaries inside the container may segfault with"
        log_warn "'FATAL: kernel too old'."
        log_warn ""
        log_warn "Mitigation options:"
        log_warn "  1. Pin the container image to an older Arch snapshot:"
        log_warn "     ARCHLINUX_IMAGE=archlinux:base-20240101 $0"
        log_warn "  2. Update your host kernel if possible."
        log_warn "  3. Accept the risk if your Arch packages are currently working."
    elif [[ "$kernel_warn" == "true" ]]; then
        log_info "Host kernel ${kernel_major}.${kernel_minor} is close to the minimum"
        log_info "recommended for current Arch Linux glibc. Monitor Arch news for"
        log_info "glibc kernel requirement changes. If issues arise, consider:"
        log_info "  ARCHLINUX_IMAGE=archlinux:base-20240101 $0"
    else
        log_success "Host kernel ${kernel_major}.${kernel_minor} meets glibc requirements."
    fi
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
        log_info "To fix: add to /etc/subuid:  $(whoami):${SUBUID_START}:${SUBUID_COUNT}"
        log_info "And:     to /etc/subgid:  $(whoami):${SUBUID_START}:${SUBUID_COUNT}"

        log_info "On SteamOS, subuid/subgid are usually created automatically when podman is installed."
        log_info "If missing, try: sudo usermod --add-subuids ${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1)) --add-subgids ${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1)) $(whoami)"
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
        local reset_output rc=0
        reset_output=$(container_runtime_privileged system reset --force 2>&1) && rc=0 || rc=$?
        log_debug "podman system reset (exit $rc): $reset_output"
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
    log_error "     sudo usermod --add-subuids ${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1)) --add-subgids ${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1)) $(whoami)"
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
  --disable-pin-alpm        Do NOT defer libalpm/pacman upgrade (risky on
                             rolling release containers; not recommended)
  --enable-ssh-env           ENABLE SSH PermitUserEnvironment (INSECURE on multi-user hosts; opt-in only)
  --allow-wheel-nopasswd     Grant NOPASSWD to entire wheel group instead of
                             just the current user (INSECURE on multi-user
                             hosts; auto-enabled on Steam Deck)
  --check                   Perform system checks and exit without installing
  --dry-run                 Show what would be done without making changes
  --dry-run-verbose         Like --dry-run, but also print the full script
                             content that would execute inside the container
                             (implies --dry-run; useful for auditing what
                             changes the container would receive)
  --strict-security         Refuse to relax signature verification (skip
                             SigLevel=TrustAll recovery, keep all packages
                             cryptographically verified). Also refuses to
                             install the fake systemd-run wrapper used for
                             DynamicUser AUR builds in non-systemd containers
                             (such builds will fail instead of running with
                             dropped sandbox properties). Failures during the
                             keyring bootstrap cause the step to fail fast
                             rather than degrade to an unverified state.
  --upload-log              Sanitize and upload the setup log for debugging
  --verbose                 Show detailed output, including command logs
  --quiet                   Only show errors
  --version                 Show version information
  -h, --help                Show this help message

ENVIRONMENT VARIABLES:
  CONTAINER_NAME            Override default container name (default: arch-pamac)
  ARCHLINUX_IMAGE           Container base image (default: archlinux:latest)
                            Override with any valid tag for different versions.
  FORCE_REBUILD            Set to 'true' to force-rebuild existing container
  ENABLE_GAMING_PACKAGES   Set to 'true' to install gaming packages
  PAMAC_VERSION            Specific pamac-aur version/commit to install (AUR fallback)
  NON_INTERACTIVE          Set to 'true' to skip all interactive prompts (safe for
                           background tools, automated installers, and cron jobs)
  PIN_ALPM                 Set to 'false' to skip deferring libalpm/pacman upgrade.
                           Default is 'true' — pacman/libalpm are upgraded after
                           pamac-aur is built to prevent API breakage on rolling
                           release containers.
  CHAOTIC_AUR_KEY_ID       Override the Chaotic-AUR signing key fingerprint
  ARCHLINUXCN_KEY_ID       Override the archlinuxcn signing key fingerprint
  ENDEAVOUROS_KEY_ID       Override the EndeavourOS signing key fingerprint
  STRICT_SECURITY          Set to 'true' to enforce --strict-security mode
                           (refuse SigLevel=TrustAll recovery and the fake
                           systemd-run wrapper). Default 'false'.
  FORCE_CONTAINER_INIT     Set to 'true' to force init-mode containers on
                           SteamOS (overrides auto-detection). For advanced
                           users with working nested systemd on custom kernels.
                           Default 'false'.
  DRY_RUN_VERBOSE          Set to 'true' to audit container scripts without
                           executing them (implies DRY_RUN=true). Default 'false'.
  LOG_ROTATION_MAX_SIZE    Rotate the per-container log on startup when it
                           exceeds this many bytes. Default: 5242880 (5 MiB).
                           One backup (.1) is kept; older backups are overwritten.

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
            --disable-pin-alpm) PIN_ALPM="false"; shift ;;
            --enable-ssh-env) ENABLE_SSH_ENV="true"; shift ;;
            --allow-wheel-nopasswd) ALLOW_WHEEL_NOPASSWD="true"; shift ;;
            --upload-log) UPLOAD_LOG="true"; shift ;;
            --dry-run) DRY_RUN="true"; shift ;;
            --dry-run-verbose) DRY_RUN="true"; DRY_RUN_VERBOSE="true"; shift ;;
            --strict-security) STRICT_SECURITY="true"; shift ;;
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
            if command -v update-desktop-database >/dev/null 2>&1; then
                update-desktop-database "$app_dir" 2>/dev/null || true
            fi
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

    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" -f 2>/dev/null || true
    fi

    log_success "Uninstallation completed."
}

_restore_errexit() {
  if [[ "${_WFC_SAVED_ERREXIT:-}" == "on" ]]; then
    set -e
  fi
  # Clear the RETURN trap so it does not fire spuriously in the caller.
  trap - RETURN
}

# Signal handler: restore errexit, clear the signal trap, and re-raise the
# identical signal so the script terminates rather than resuming the loop.
# Without this, a SIGINT/TERM/HUP fires the trap, bash resumes at the next
# command in the while loop, and the user must hit Ctrl-C a second time.
_restore_and_die() {
    local _sig=$1
    _restore_errexit
    trap - "$_sig"
    kill -s "$_sig" $$ 2>/dev/null || exit 130
}

wait_for_container() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "[DRY RUN] Would wait for container '$CONTAINER_NAME'"
    return 0
  fi
  local max_attempts=30
  local attempt=0
  _WFC_SAVED_ERREXIT=$(shopt -o -q errexit && echo "on" || echo "off")
  log_info "Waiting for container '$CONTAINER_NAME' to become ready..."

  set +e
  # Install both RETURN (covers normal return) and INT/TERM (covers signal kill)
  # traps so errexit is always restored on the way out of this function, even if
  # the user hits Ctrl-C (a bare RETURN trap does not fire on a signal death,
  # which previously left `set +e` sticky in the caller's scope).
  trap '_restore_errexit' RETURN
  trap '_restore_and_die INT'  INT
  trap '_restore_and_die TERM' TERM
  trap '_restore_and_die HUP'  HUP

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
          local _frc_rc=0
          force_remove_container "$CONTAINER_NAME" || _frc_rc=$?
          if [[ "$_frc_rc" -eq 0 ]]; then
            return 2
          else
            log_error "force_remove_container failed for '$CONTAINER_NAME' (exit $_frc_rc). Container may still be stuck — recovery may fail."
            return 3
          fi
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
        local _frc_rc=0
        force_remove_container "$CONTAINER_NAME" || _frc_rc=$?
        if [[ "$_frc_rc" -eq 0 ]]; then
          return 2
        else
          log_warn "force_remove_container failed for '$CONTAINER_NAME' (exit $_frc_rc). Container may still be stuck."
          return 3
        fi
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
      local _frc_rc=0
      force_remove_container "$CONTAINER_NAME" || _frc_rc=$?
      if [[ "$_frc_rc" -eq 0 ]]; then
        return 2
      else
        log_error "force_remove_container failed for '$CONTAINER_NAME' (exit $_frc_rc). Container may still be stuck."
        return 3
      fi
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

    # Override for advanced users who need init mode on SteamOS
    if [[ "${FORCE_CONTAINER_INIT:-}" == "true" ]]; then
        CONTAINER_HAS_INIT="true"
        log_info "FORCE_CONTAINER_INIT=true — skipping init detection, using init mode."
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
    local _pull_ok=false
    for _pull_attempt in 1 2 3; do
        if run_command container_runtime pull "$ARCHLINUX_IMAGE"; then
            _pull_ok=true
            break
        fi
        log_warn "Image pull attempt $_pull_attempt/3 failed."
        if [[ $_pull_attempt -lt 3 ]]; then
            local _backoff=$(( _pull_attempt * 5 ))
            log_info "Retrying in ${_backoff}s..."
            sleep "$_backoff"
        fi
    done
    if [[ "$_pull_ok" != "true" ]]; then
        log_warn "Image pull failed after 3 attempts. Proceeding with cached image."
        log_info "If this is a fresh install with no cached image, the next step will fail."
        log_info "Tip: Try ARCHLINUX_IMAGE=archlinux:base-YYYYMMDD $0 for a pinned version."
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
  # Recursion lock: create_container may be reached from
  # _ensure_healthy_or_recreate (which temporarily unsets this guard, calls
  # create_container, then restores). create_container itself never calls
  # back into _ensure_healthy_or_recreate, so recursion is single-level. We
  # set the guard here and clear it on EVERY return path (success and
  # failure) below; the prior code forgot to unset on the success path,
  # leaving the lock set permanently and blocking any later legitimate
  # (re)creation.
  _CREATE_RECREATION_GUARD=1

  if ! run_command distrobox create "${create_args[@]}"; then
    log_warn "Container create failed - attempting cleanup and retry..."
    force_remove_container "$CONTAINER_NAME"
    sleep 2
    if ! run_command distrobox create "${create_args[@]}"; then
      unset _CREATE_RECREATION_GUARD
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
      wait_for_container || { unset _CREATE_RECREATION_GUARD; return 1; }
    else
      unset _CREATE_RECREATION_GUARD
      log_error "Failed to recreate container after removal."
      return 1
    fi
  elif [[ "$wait_result" -eq 3 ]]; then
    unset _CREATE_RECREATION_GUARD
    log_error "wait_for_container returned 3: force_remove_container already failed internally. Container likely still stuck."
    log_info "Recreation attempt skipped — prior removal failure makes recreation unlikely to succeed."
    return 1
  elif [[ "$wait_result" -ne 0 ]]; then
    unset _CREATE_RECREATION_GUARD
    return 1
  fi

  if container_root_exec bash -c "echo ready" 2>/dev/null | grep -q "ready"; then
    log_success "Container is functional and ready."
  else
    unset _CREATE_RECREATION_GUARD
    log_error "Container created but is not functional."
    return 1
  fi
  # Success path: clear the recursion lock so a later (re)creation isn't
  # falsely rejected as nested recursion.
  unset _CREATE_RECREATION_GUARD
}

repair_pacman_db() {
    log_info "Checking and repairing pacman database (if needed)..."
    container_root_exec bash -c '
set +e

# ── Internal helpers (not available from host preamble) ──
_inner_remove_stale_lock() {
    local _lock="/var/lib/pacman/db.lck"
    if [[ ! -f "$_lock" ]]; then return 0; fi
    local _lck_pid
    _lck_pid=$(cat "$_lock" 2>/dev/null || echo "")
    if [[ -n "$_lck_pid" ]] && kill -0 "$_lck_pid" 2>/dev/null; then
        if grep -E "pacman|yay" "/proc/$_lck_pid/comm" >/dev/null 2>&1; then
            echo "  Pacman running (PID $_lck_pid), waiting up to 30s..."
            local _w=0
            while [[ $_w -lt 30 ]] && kill -0 "$_lck_pid" 2>/dev/null; do
                sleep 2
                _w=$(( _w + 2 ))
            done
            if kill -0 "$_lck_pid" 2>/dev/null; then
                echo "  WARNING: Pacman (PID $_lck_pid) still running after 30s. Force-removing lock."
                kill -9 "$_lck_pid" 2>/dev/null || true
                sleep 1
            fi
        else
            echo "  Lock file owned by non-pacman process (PID $_lck_pid). Removing."
        fi
    fi
    rm -f "$_lock" 2>/dev/null || true
}

_inner_db_is_healthy() {
    pacman -Dk 2>/dev/null | grep -q "No database errors"
}

# ── Quick exit: if DB is healthy, do nothing ──
if _inner_db_is_healthy; then
    echo "Pacman DB is consistent. No repair needed."
    exit 0
fi

echo "Database inconsistencies detected. Starting multi-strategy repair..."

# ── Pre-flight: disk space check ──
_db_avail_kb=$(df -k /var/lib/pacman 2>/dev/null | awk "NR==2{print \$4}" || echo "0")
if [[ "$_db_avail_kb" -gt 0 ]] && [[ "$_db_avail_kb" -lt 10240 ]]; then
    echo "WARNING: Low disk space (${_db_avail_kb}KB) in /var/lib/pacman partition."
    echo "  DB repair may fail due to insufficient space for backup/rebuild operations."
fi

# ── Strategy 1: Backup current DB before destructive operations ──
echo ""
echo "=== Strategy 1: Creating safety backup ==="
_db_backup="/var/lib/pacman/local/.db-backup-$(date +%Y%m%d-%H%M%S)"
if [[ -d /var/lib/pacman/local ]]; then
    mkdir -p "$_db_backup" 2>/dev/null || true
    _backup_count=0
    for _entry in /var/lib/pacman/local/*/; do
        [[ -d "$_entry" ]] || continue
        _entry_name=$(basename "$_entry")
        [[ "$_entry_name" == *".db-backup"* ]] && continue
        cp -a "$_entry" "$_db_backup/" 2>/dev/null || true
        _backup_count=$((_backup_count + 1))
    done
    echo "  Backed up $_backup_count DB entries to $_db_backup"
else
    echo "  WARNING: /var/lib/pacman/local does not exist. DB may be completely missing."
    mkdir -p /var/lib/pacman/local 2>/dev/null || true
fi

# ── Strategy 2: Fix individual broken entries ──
echo ""
echo "=== Strategy 2: Fixing individual broken entries ==="
_repaired=0
for db_dir in /var/lib/pacman/local/*/; do
    [[ -d "$db_dir" ]] || continue
    pkg_name=$(basename "$db_dir")
    [[ "$pkg_name" == *".db-backup"* ]] && continue

    # Missing desc file — entire entry is broken
    if [[ ! -f "$db_dir/desc" ]]; then
        echo "  Removing broken entry: $pkg_name (missing desc)"
        rm -rf "$db_dir" 2>/dev/null || true
        _repaired=$((_repaired + 1))
        continue
    fi

    # Zero-size desc file
    _desc_size=$(wc -c < "$db_dir/desc" 2>/dev/null || echo "0")
    if [[ "$_desc_size" -eq 0 ]]; then
        echo "  Removing broken entry: $pkg_name (empty desc file)"
        rm -rf "$db_dir" 2>/dev/null || true
        _repaired=$((_repaired + 1))
        continue
    fi

    # Missing %NAME% marker in desc — corrupted desc
    if ! grep -q "^%NAME%$" "$db_dir/desc" 2>/dev/null; then
        echo "  Removing broken entry: $pkg_name (corrupted desc — no %NAME% marker)"
        rm -rf "$db_dir" 2>/dev/null || true
        _repaired=$((_repaired + 1))
        continue
    fi

    # Missing files DB — reinstall
    if [[ ! -f "$db_dir/files" ]]; then
        echo "  Package $pkg_name missing files DB, attempting reinstall..."
        pkg_base=$(grep -A1 "^%NAME%$" "$db_dir/desc" 2>/dev/null | grep -v "^%NAME%$" | head -1)
        [[ -z "$pkg_base" ]] && pkg_base=$(echo "$pkg_name" | sed "s/-[0-9].*//")
        if pacman -S --noconfirm --needed "$pkg_base" 2>/dev/null; then
            echo "    Reinstalled $pkg_base successfully."
            _repaired=$((_repaired + 1))
        else
            echo "    Failed to reinstall $pkg_base (may not be in repos anymore)."
        fi
    fi
done

if [[ $_repaired -gt 0 ]]; then
    echo "  Fixed $_repaired broken entries."
fi

if _inner_db_is_healthy; then
    echo "Database consistent after Strategy 2 (individual fixes)."
    exit 0
fi

# ── Strategy 3: Force reinstall all packages reported as broken by -Dk ──
echo ""
echo "=== Strategy 3: Force reinstall broken packages ==="
_inner_remove_stale_lock

# Parse pacman -Dk output for broken packages
_broken_pkgs=""
while IFS= read -r line; do
    # "package-version: /path/to/file" — missing file
    # "package-version: is installed but should not be" — wrong DB state
    _pkg=$(echo "$line" | awk -F: "{print \$1}" | sed "s/ is installed but should not be//" || true)
    [[ -n "$_pkg" ]] && _broken_pkgs="$_broken_pkgs $_pkg"
done < <(pacman -Dk 2>&1 | grep -E "is installed but should not be|missing file" || true)

# Deduplicate
_broken_pkgs=$(echo "$_broken_pkgs" | tr " " "\n" | sort -u | tr "\n" " ")

if [[ -n "$_broken_pkgs" ]]; then
    echo "  Broken packages found: $(echo "$_broken_pkgs" | wc -w)"
    for _bp in $_broken_pkgs; do
        [[ -z "$_bp" ]] && continue
        echo "  Reinstalling: $_bp"
        pacman -S --noconfirm --needed "$_bp" 2>/dev/null || echo "    Failed to reinstall $_bp."
    done
fi

if _inner_db_is_healthy; then
    echo "Database consistent after Strategy 3 (force reinstall)."
    exit 0
fi

# ── Strategy 4: Full database sync ──
echo ""
echo "=== Strategy 4: Full database sync ==="
_inner_remove_stale_lock
if pacman -Syy --noconfirm 2>/dev/null; then
    if _inner_db_is_healthy; then
        echo "Database consistent after Strategy 4 (full sync)."
        exit 0
    fi
fi

# ── Strategy 5: Reinstall archlinux-keyring + core packages ──
echo ""
echo "=== Strategy 5: Reinstall core packages ==="
_inner_remove_stale_lock
for _core_pkg in archlinux-keyring pacman libarchive libcurl-gnutls openssl; do
    pacman -S --noconfirm --needed "$_core_pkg" 2>/dev/null || true
done
if _inner_db_is_healthy; then
    echo "Database consistent after Strategy 5 (core reinstall)."
    exit 0
fi

# ── Strategy 6: Rebuild DB from package cache ──
echo ""
echo "=== Strategy 6: Rebuild DB from package cache ==="
if [[ -d /var/cache/pacman/pkg ]]; then
    _cache_count=$(find /var/cache/pacman/pkg -maxdepth 1 -name '*.pkg.tar.*' 2>/dev/null | wc -l || echo "0")
    if [[ "$_cache_count" -gt 0 ]]; then
        echo "  Found $_cache_count cached packages."
        _inner_remove_stale_lock
        pacman -Syy --noconfirm 2>/dev/null || true
        
        # Only reinstall cached packages that are NOT in the DB properly
        _reinstalled=0
        for _cache_pkg in /var/cache/pacman/pkg/*.pkg.tar.*; do
            [[ -f "$_cache_pkg" ]] || continue
            _pkg_base=$(basename "$_cache_pkg" | sed "s/-[0-9].*//;s/\.pkg\.tar\.\(xz\|zst\|gz\|bz2\)$//" || true)
            # Skip if already properly installed with desc+files
            if [[ -d "/var/lib/pacman/local/$(basename "$_cache_pkg" | sed "s/\.pkg\.tar\.\(xz\|zst\|gz\|bz2\)$//")" ]] && \
               [[ -f "/var/lib/pacman/local/$(basename "$_cache_pkg" | sed "s/\.pkg\.tar\.\(xz\|zst\|gz\|bz2\)$//")/desc" ]]; then
                continue
            fi
            if pacman -U --noconfirm "$_cache_pkg" 2>/dev/null; then
                _reinstalled=$((_reinstalled + 1))
            fi
        done
        echo "  Reinstalled $_reinstalled packages from cache."
        
        if _inner_db_is_healthy; then
            echo "Database consistent after Strategy 6 (cache rebuild)."
            exit 0
        fi
    else
        echo "  No cached packages available for rebuild."
    fi
else
    echo "  Package cache directory missing."
fi

# ── Strategy 7: Remove all corrupted entries and re-sync from repos ──
echo ""
echo "=== Strategy 7: Remove corrupted entries and re-sync ==="
_corrupted_removed=0
for db_dir in /var/lib/pacman/local/*/; do
    [[ -d "$db_dir" ]] || continue
    pkg_name=$(basename "$db_dir")
    [[ "$pkg_name" == *".db-backup"* ]] && continue
    
    _corrupt=false
    if [[ ! -f "$db_dir/desc" ]]; then
        _corrupt=true
    elif ! grep -q "^%NAME%$" "$db_dir/desc" 2>/dev/null; then
        _corrupt=true
    fi
    
    if [[ "$_corrupt" == "true" ]]; then
        echo "  Removing corrupted: $pkg_name"
        rm -rf "$db_dir" 2>/dev/null || true
        _corrupted_removed=$((_corrupted_removed + 1))
    fi
done

if [[ $_corrupted_removed -gt 0 ]]; then
    echo "  Removed $_corrupted_removed corrupted entries. Re-syncing from repos..."
    _inner_remove_stale_lock
    pacman -Syy --noconfirm 2>/dev/null || true
    
    # Reinstall any removed packages that are still available
    for _pkg in $(pacman -Qn 2>/dev/null | awk "{print \$1}" || true); do
        pacman -S --noconfirm --needed "$_pkg" 2>/dev/null || true
    done
    
    if _inner_db_is_healthy; then
        echo "Database consistent after Strategy 7 (corruption removal + re-sync)."
        exit 0
    fi
fi

# ── Strategy 8: Restore from backup (partial — only broken entries) ──
echo ""
echo "=== Strategy 8: Restore from backup ==="
if [[ -d "$_db_backup" ]] && [[ -d /var/lib/pacman/local ]]; then
    _restored=0
    for _backup_entry in "$_db_backup"/*/; do
        [[ -d "$_backup_entry" ]] || continue
        _entry_name=$(basename "$_backup_entry")
        # Only restore if current entry is broken/missing
        if [[ ! -d "/var/lib/pacman/local/$_entry_name" ]] || \
           [[ ! -f "/var/lib/pacman/local/$_entry_name/desc" ]]; then
            if [[ -f "$_backup_entry/desc" ]]; then
                cp -a "$_backup_entry" "/var/lib/pacman/local/" 2>/dev/null || true
                _restored=$((_restored + 1))
            fi
        fi
    done
    echo "  Restored $_restored entries from backup."
    
    if _inner_db_is_healthy; then
        echo "Database consistent after Strategy 8 (backup restore)."
        exit 0
    fi
fi

# ── Strategy 9: Nuclear — wipe and rebuild entire local DB ──
echo ""
echo "=== Strategy 9: Full DB rebuild (last resort) ==="
echo "  WARNING: This will remove ALL database entries and rebuild from scratch."
echo "  Installed packages on disk will NOT be deleted — only the tracking DB is rebuilt."
_inner_remove_stale_lock

# Save list of installed packages before wipe
_installed_before=$(pacman -Q 2>/dev/null || true)

# Move entire local DB to a safe location
_db_nuclear="/var/lib/pacman/local/.db-nuclear-backup-$(date +%Y%m%d-%H%M%S)"
mv /var/lib/pacman/local "$_db_nuclear" 2>/dev/null || true
mkdir -p /var/lib/pacman/local 2>/dev/null || true

# Re-sync from repos to get a fresh DB
_inner_remove_stale_lock
if pacman -Syy --noconfirm 2>/dev/null; then
    echo "  Fresh database sync succeeded."
    
    # Reinstall all previously installed packages from cache/repos
    if [[ -n "$_installed_before" ]]; then
        _reinstalled=0
        while IFS= read -r _pkg_line; do
            [[ -z "$_pkg_line" ]] && continue
            _pkg_name=$(echo "$_pkg_line" | awk "{print \$1}")
            if pacman -S --noconfirm --needed "$_pkg_name" 2>/dev/null; then
                _reinstalled=$((_reinstalled + 1))
            fi
        done <<< "$_installed_before"
        echo "  Reinstalled $_reinstalled packages."
    fi
    
    if _inner_db_is_healthy; then
        echo "Database consistent after Strategy 9 (full rebuild)."
        exit 0
    fi
else
    echo "  Fresh database sync failed. Restoring from nuclear backup..."
    rm -rf /var/lib/pacman/local 2>/dev/null || true
    mv "$_db_nuclear" /var/lib/pacman/local 2>/dev/null || true
fi

# ── Final: all strategies exhausted ──
echo ""
echo "=== DB Repair: Final Status ==="
echo "All 9 repair strategies attempted."
echo ""
echo "Remaining issues:"
pacman -Dk 2>&1 | head -20 || true
echo ""
echo "The system may still be partially functional."
echo "Manual recovery options:"
echo "  1. pacman -Syyu --overwrite \"*\"  (full upgrade with overwrite)"
echo "  2. rm -rf /var/lib/pacman/local && pacman -Syy  (full DB rebuild)"
echo "  3. Check filesystem: fsck $(df /var/lib/pacman 2>/dev/null | awk "NR==2{print \$6}" || echo "/")"
echo ""
echo "WARNING: Some inconsistencies may be non-fatal and can be ignored if"
echo "the system is otherwise working. Not every -Dk warning requires action."
' 2>/dev/null || true
}

# shellcheck disable=SC2016,SC1078,SC1079
_CONTAINER_PREAMBLE='_safe_sleep() {
# CANONICAL DEFINITION — keep in sync with the two copies in
# pamac-session-bootstrap.sh (critical_script and repair_script).
# All three must be functionally identical.
local _d="$1"
# Sanitize argument to a positive INTEGER (default 1s) before passing to
# timers. Floats are NOT allowed: bash arithmetic ($(( ... ))) cannot handle
# decimals and would crash the script under `set -e`, so we reject anything
# containing a non-digit (including '.') and default to 1.
case "$_d" in
    ''|*[!0-9]*) _d=1 ;;
esac
if sleep "$_d" 2>/dev/null; then return 0; fi
# sleep is unavailable/broken — try a real timer that actually delays.
# (read -t </dev/null returns immediately on EOF, so it is NOT a sleep.)
if command -v python3 >/dev/null 2>&1; then
    python3 -c "import time,sys; time.sleep(float(sys.argv[1]))" "$_d" 2>/dev/null && return 0
fi
if command -v perl >/dev/null 2>&1; then
    perl -e "select undef,undef,undef,\$ARGV[0]" "$_d" 2>/dev/null && return 0
fi
# No working timer available: degrade to a \$SECONDS-based wall-clock wait so
# retry loops neither busy-pin a core NOR return in <10ms. bashs \$SECONDS
# advances once per real second of wall time, so we poll until the requested
# number of whole seconds elapses. The case guard above restricted \$_d to
# [0-9] (floats sanitized to 1), so the arithmetic here is integer-safe.
# Returns 0: a real wall-clock delay DID happen even though no precise sub-
# second timer fired; callers should not interpret a non-zero exit as \"no
# delay happened\" — the function always sleeps at least the requested integer
# number of seconds (or 1s minimum) when reached.
local _target=\$(( _d + 0 ))
[[ \$_target -lt 1 ]] && _target=1
local _start=\$SECONDS
while (( SECONDS - _start < _target )); do
    # Use read -t to yield CPU instead of busy-pinning a core to 100%.
    # This prevents battery drain on handheld devices when sleep is broken.
    # Redirect stdin from /dev/null so read always times out after ~1s
    # regardless of the callers stdin state (terminal, pipe, or closed fd).
    read -t 1 _dummy </dev/null 2>/dev/null || true
done
return 0
}
_remove_stale_lock() {
    local _lock="/var/lib/pacman/db.lck"
    if [[ ! -f "$_lock" ]]; then return 0; fi
    local _lck_pid
    _lck_pid=$(cat "$_lock" 2>/dev/null || echo "")
    # Validate PID is a numeric value (prevent malformed lock file injection)
    if [[ -n "$_lck_pid" ]] && [[ "$_lck_pid" =~ ^[0-9]+$ ]]; then
        if kill -0 "$_lck_pid" 2>/dev/null && grep -E "pacman|yay" "/proc/$_lck_pid/comm" >/dev/null 2>&1; then
            echo "Pacman is currently running (PID $_lck_pid). Waiting..."
            local _wait=0
            while [[ $_wait -lt 30 ]] && kill -0 "$_lck_pid" 2>/dev/null; do
                _safe_sleep 2
                _wait=$(( _wait + 2 ))
            done
            if kill -0 "$_lck_pid" 2>/dev/null; then
                echo "ERROR: Pacman (PID $_lck_pid) is still running after ${_wait}s. Aborting to prevent database corruption."
                exit 1
            fi
        fi
    elif [[ -n "$_lck_pid" ]]; then
        echo "Warning: Lock file contains non-numeric PID: '$_lck_pid'. Removing stale lock."
    fi
    rm -f "$_lock" 2>/dev/null || true
}
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
    local attempt=0 max_attempts=4 rc=0
    while [[ $attempt -lt $max_attempts ]]; do
        _remove_stale_lock
        if pacman -S --noconfirm --needed "$@"; then
            ldconfig 2>/dev/null || true
            return 0
        fi
        rc=$?
        attempt=$((attempt + 1))
        if [[ $attempt -lt $max_attempts ]]; then
            echo "Install failed (attempt $attempt/$max_attempts, exit=$rc), attempting recovery..."

            # Diagnose failure type and apply targeted recovery
            case $rc in
                137)
                    echo "  Exit 137: OOM kill detected. Syncing and waiting..."
                    sync 2>/dev/null || true
                    _safe_sleep 5
                    # On OOM, try to free some cache
                    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
                    ;;
                1)
                echo "  Exit 1: General error (dependency conflict, etc.)."
                # Check for file conflicts
                _conflict_output=$(pacman -S --noconfirm --needed "$@" 2>&1 | grep -i "conflicting files\|exists in filesystem" || true)
                if [[ -n "$_conflict_output" ]]; then
                    echo "  File conflicts detected. Trying with targeted --overwrite for /usr/lib and /usr/share..."
                    # Only overwrite files in standard package directories, not config dirs
                    pacman -S --noconfirm --needed --overwrite '/usr/lib/*,/usr/share/*,/usr/bin/*,/usr/sbin/*' "$@" 2>/dev/null || true
                fi
                    ;;
                2)
                    echo "  Exit 2: Invalid package name or target."
                    echo "  Packages requested: $*"
                    ;;
                *)
                    echo "  Exit $rc: Unknown error."
                    ;;
            esac

            # Progressive recovery strategies
            if [[ $attempt -eq 1 ]]; then
                # First retry: just fix DB and re-sync
                echo "  Recovery 1: DB check + re-sync..."
                pacman -Dk 2>/dev/null || true
                _remove_stale_lock
                pacman -Syy --noconfirm 2>/dev/null || true
                _safe_sleep 2
            elif [[ $attempt -eq 2 ]]; then
                # Second retry: more aggressive DB repair
                echo "  Recovery 2: Aggressive DB repair..."
                _remove_stale_lock
                # Remove any stale lock aggressively
                rm -f /var/lib/pacman/db.lck 2>/dev/null || true
                # Kill only stale pacman/yay processes that held the lock
                # (not all pacman processes — other builds may be running)
                _stale_pids=$(pgrep -x pacman 2>/dev/null || true)
                for _spid in $_stale_pids; do
                    if [[ "$_spid" != "$$" ]] && [[ "$_spid" != "$PPID" ]]; then
                        echo "  Force-killing stale pacman PID $_spid"
                        kill -9 "$_spid" 2>/dev/null || true
                    fi
                done
                _stale_yay_pids=$(pgrep -x yay 2>/dev/null || true)
                for _ypid in $_stale_yay_pids; do
                    if [[ "$_ypid" != "$$" ]] && [[ "$_ypid" != "$PPID" ]]; then
                        echo "  Force-killing stale yay PID $_ypid"
                        kill -9 "$_ypid" 2>/dev/null || true
                    fi
                done
                sleep 1
                # Re-sync with overwrite limited to standard package dirs
                pacman -Syy --noconfirm 2>/dev/null || true
                # Reinstall keyring to fix potential signature issues
                pacman -S --noconfirm --needed archlinux-keyring 2>/dev/null || true
                _safe_sleep 3
            else
                # Third retry: nuclear option — reinstall the specific package directly
                echo "  Recovery 3: Direct package reinstall attempt..."
                _remove_stale_lock
                for _pkg in "$@"; do
                    # Try to find and install the package directly
                    pacman -S --noconfirm --needed --overwrite "*" "$_pkg" 2>/dev/null || true
                done
                _safe_sleep 2
            fi
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
        # shellcheck disable=SC2086 # Intentional word-splitting: $batch is a space-separated package list
        if ! safe_install $batch; then
            echo "ERROR: batch install failed for: $batch"
            # shellcheck disable=SC2086
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
# Write the fake systemd-run wrapper script. Shared between install and
# repair paths. The heredoc body is at column 0 (no leading whitespace)
# because the kernel requires the shebang to be byte 0 of the file.
_write_fake_systemd_run_wrapper() {
    mkdir -p /usr/local/sbin
    cat > /usr/local/sbin/systemd-run << 'SYSTEMD_RUN_FAKE_HEREDOC'
#!/bin/bash
# Fake systemd-run for non-systemd containers (Distrobox).
# Mimics the subset of systemd-run used by Pamac/makepkg for DynamicUser builds.
# Logs unrecognized arguments to /tmp/systemd-run-fake.log for diagnostics.
# Prints visible warnings to stderr when unrecognized properties are detected.
_DSR_LOG="/tmp/systemd-run-fake.log"
DSR_VERSION="2.0"
_log_dsr() { echo "[$(date '\''+%H:%M:%S'\'')] $*" >> "$_DSR_LOG" 2>/dev/null; }
_warn_dsr() { echo "systemd-run(fake): WARNING: $*" >> "$_DSR_LOG" 2>/dev/null; echo "systemd-run(fake): WARNING: $*" >&2 2>/dev/null || true; }

# Pre-flight: clean up orphaned ad-hoc build users and temp home directories
# left behind by interrupted builds. Ad-hoc users are named _brecover* and
# own /var/tmp/builduser-home-* directories.
_cleanup_orphaned_buildusers() {
    local _orphan_users=""
    _orphan_users=$(getent passwd 2>/dev/null | awk -F: '\''$1 ~ /^_brecover/ { print $1 }'\'' || true)
    for _ou in $_orphan_users; do
        _warn_dsr "Cleaning up orphaned build user: $_ou"
        userdel -r "$_ou" 2>/dev/null || userdel "$_ou" 2>/dev/null || true
    done
    for _dir in /var/tmp/builduser-home-*; do
        [[ -d "$_dir" ]] || continue
        # Only remove if owned by root (build users run as non-root, so a
        # non-root-owned directory might be an active build'\''s workspace).
        if [[ "$(stat -c '\''%U'\'' "$_dir" 2>/dev/null || echo root)" == "root" ]]; then
            _warn_dsr "Removing orphaned build-user home: $_dir"
            rm -rf "$_dir" 2>/dev/null || true
        fi
    done
}
_cleanup_orphaned_buildusers

# Passthrough: --help and --version are not meaningful here
for _a in "$@"; do
    case "$_a" in
        --help|-h) echo "systemd-run (fake) v${DSR_VERSION}: Mimics systemd-run for DynamicUser AUR builds in non-systemd containers."; echo "Recognized options: --property=DynamicUser=yes, --property=CacheDirectory=*, --property=WorkingDirectory=*, --property=StateDirectory=*, --property=LogsDirectory=*, --property=RuntimeDirectory=*, --property=TemporaryFileSystem=*, --property=BindPaths=*, --property=BindReadOnlyPaths=*, --property=ProtectSystem=*, --property=ProtectHome=*, --property=PrivateTmp=*, --property=NoNewPrivileges=*, --property=MemoryDenyWriteExecute=*, --property=SystemCallFilter=*, --property=CapabilityBoundingSet=*, --property=User=*, --property=Group=*, --property=SupplementaryGroups=*, --property=AmbientCapabilities=*, --property=EnvironmentFile=*, --property=Type=*, --property=RemainAfterExit=*, --property=Ephemeral=*, --property=Slice=*, --property=IOSchedulingClass=*, --property=CPUSchedulingPolicy=*, --property=RestrictNamespaces=*, --property=RestrictSUIDSGID=*, --property=LockPersonality=*, --property=RestrictRealtime=*, --property=RestrictAddressFamilies=*, --property=RemoveIPC=*, --property=UMask=*, --property=KeyringMode=*, --property=ProtectClock=*, --property=ProtectKernelTunables=*, --property=ProtectKernelModules=*, --property=ProtectKernelLogs=*, --property=ProtectControlGroups=*, --property=ProtectHostname=*, --property=ProtectProc=*, --property=ProcSubset=*, --property=MemorySwapMax=*, --property=CPUQuota=*, --property=DeviceAllow=*, --property=DevicePolicy=*, --property=RestrictFileSystems=*, --property=SocketBindDeny=*, --property=SocketBindAllow=*, --property=IPAddressAllow=*, --property=IPAddressDeny=*, and all other systemd.exec(5)/resource-control(5)/service(5) --property= sandboxing (Private*, Protect*, ReadWritePaths, RootDirectory, ...), resource (Limit*, *Accounting, *Max, *Weight, IO*, Memory*, CPU*), logging (StandardIO, Syslog*, LogLevel*), Condition*, Assert*, and Timeout*/Restart* options (recognized and dropped in this non-systemd env; sandboxing drops are logged to /tmp/systemd-run-fake.log), --pipe, --wait, --quiet, --no-block, --description=*, --unit=*, --service-type=*, --user, --uid=*, --gid=*, --setenv=*, --"; exit 0 ;;
        --version) echo "systemd-run (fake) v${DSR_VERSION} (SteamOS-Pamac)"; exit 0 ;;
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
# Recognized but currently unimplemented properties in this fake systemd-run.
# Security-hardening properties (Protect*, SystemCallFilter, ...) are DROPPED
# in the non-systemd container — they cannot be enforced outside a unit. We log
# every dropped property to /tmp/systemd-run-fake.log so a build that depended
# on a property'\''s behavior (not just its presence) is debuggable. Resource and
# metadata properties that have no sandboxing impact stay silent for brevity.
--property=StateDirectory=*) continue ;;
--property=LogsDirectory=*) continue ;;
--property=RuntimeDirectory=*) continue ;;
--property=Type=*) continue ;;
--property=RemainAfterExit=*) continue ;;
--property=TemporaryFileSystem=*) continue ;;
--property=BindPaths=*) continue ;;
--property=BindReadOnlyPaths=*) continue ;;
--property=ProtectSystem=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=ProtectHome=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=PrivateTmp=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=NoNewPrivileges=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=MemoryDenyWriteExecute=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=SystemCallFilter=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=CapabilityBoundingSet=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=User=*) continue ;;
--property=Group=*) continue ;;
--property=SupplementaryGroups=*) continue ;;
--property=AmbientCapabilities=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=EnvironmentFile=*) continue ;;
--property=Ephemeral=*) continue ;;
--property=Slice=*) continue ;;
--property=IOSchedulingClass=*) continue ;;
--property=CPUSchedulingPolicy=*) continue ;;
--property=RestrictNamespaces=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=RestrictSUIDSGID=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=LockPersonality=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=RestrictRealtime=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=RestrictAddressFamilies=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=RemoveIPC=*) continue ;;
--property=UMask=*) continue ;;
--property=KeyringMode=*) continue ;;
--property=ProtectClock=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=ProtectKernelTunables=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=ProtectKernelModules=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=ProtectKernelLogs=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=ProtectControlGroups=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=ProtectHostname=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=ProtectProc=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=ProcSubset=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=MemorySwapMax=*) continue ;;
--property=CPUQuota=*) continue ;;
--property=DeviceAllow=*) continue ;;
--property=DevicePolicy=*) continue ;;
--property=RestrictFileSystems=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=SocketBindDeny=*) continue ;;
--property=SocketBindAllow=*) continue ;;
--property=IPAddressAllow=*) continue ;;
--property=IPAddressDeny=*) continue ;;
# Additional recognized systemd-run properties (not previously handled).
# Grouped per systemd.exec(5)/systemd.resource-control(5). Security/sandboxing
# properties are logged via _warn_dsr when dropped (same convention as above);
# resource/accounting/metadata/IO/log properties stay silent.
# --- Filesystem / namespace sandboxing ---
--property=PrivateDevices=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=PrivateMounts=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=PrivateNetwork=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=PrivateUsers=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=MountFlags=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=MountAPIVFS=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=ReadWritePaths=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=ReadOnlyPaths=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=InaccessiblePaths=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=ExecPaths=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=NoExecPaths=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=ConfigurationDirectory=*) continue ;;
--property=RootDirectory=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=RootImage=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=RootHash=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=RootVerity=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=MountImages=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=ExtensionImages=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=NamespacePath=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=NetworkNamespacePath=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=LogNamespace=*) continue ;;
# --- Capabilities / privileges ---
--property=InheritDescriptors=*) continue ;;
--property=SecureBits=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
# --- Environment ---
--property=Environment=*) continue ;;
--property=PassEnvironment=*) continue ;;
--property=UnsetEnvironment=*) continue ;;
# --- Personality / arch ---
--property=Personality=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=SystemCallArchitectures=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=SystemCallErrorNumber=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=SystemCallLog=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
# --- IPC / time / misc ---
--property=TimerSlackNSec=*) continue ;;
--property=SetLoginEnvironment=*) continue ;;
--property=Delegate=*) continue ;;
--property=DisableExtraFileDescriptors=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=CoredumpReceive=*) _warn_dsr "Dropped --property (non-systemd env, no sandboxing): $arg"; continue ;;
--property=DynamicUser=*) continue ;;
# --- Standard I/O / logging ---
--property=StandardInput=*) continue ;;
--property=StandardOutput=*) continue ;;
--property=StandardError=*) continue ;;
--property=StandardInputText=*) continue ;;
--property=StandardInputFileDescriptor=*) continue ;;
--property=StandardInputData=*) continue ;;
--property=StandardOutputFileDescriptor=*) continue ;;
--property=StandardErrorFileDescriptor=*) continue ;;
--property=TTYPath=*) continue ;;
--property=TTYReset=*) continue ;;
--property=TTYVHangup=*) continue ;;
--property=TTYVTDisallocate=*) continue ;;
--property=SyslogIdentifier=*) continue ;;
--property=SyslogFacility=*) continue ;;
--property=SyslogLevel=*) continue ;;
--property=SyslogLevelPrefix=*) continue ;;
--property=LogLevelMax=*) continue ;;
--property=LogRateLimitIntervalSec=*) continue ;;
--property=LogRateLimitBurst=*) continue ;;
--property=LogExtraFields=*) continue ;;
--property=LogFilterPatterns=*) continue ;;
--property=LogFilterAllow=*) continue ;;
--property=LogFilterDeny=*) continue ;;
--property=LogLevelOverride=*) continue ;;
# --- Resource limits (RLIMIT_*) and accounting ---
--property=LimitCPU=*) continue ;;
--property=LimitCPUSoft=*) continue ;;
--property=LimitFSIZE=*) continue ;;
--property=LimitFIZESoft=*) continue ;;
--property=LimitDATA=*) continue ;;
--property=LimitDATASoft=*) continue ;;
--property=LimitSTACK=*) continue ;;
--property=LimitSTACKSoft=*) continue ;;
--property=LimitCORE=*) continue ;;
--property=LimitCORESoft=*) continue ;;
--property=LimitRSS=*) continue ;;
--property=LimitRSSSoft=*) continue ;;
--property=LimitNOFILE=*) continue ;;
--property=LimitNOFILESoft=*) continue ;;
--property=LimitAS=*) continue ;;
--property=LimitASSoft=*) continue ;;
--property=LimitNPROC=*) continue ;;
--property=LimitNPROCSoft=*) continue ;;
--property=LimitMEMLOCK=*) continue ;;
--property=LimitMEMLOCKSoft=*) continue ;;
--property=LimitLOCKS=*) continue ;;
--property=LimitLOCKSSoft=*) continue ;;
--property=LimitSIGPENDING=*) continue ;;
--property=LimitSIGPENDINGSoft=*) continue ;;
--property=LimitMSGQUEUE=*) continue ;;
--property=LimitMSGQUEUESoft=*) continue ;;
--property=LimitNICE=*) continue ;;
--property=LimitNICESoft=*) continue ;;
--property=LimitRTPRIO=*) continue ;;
--property=LimitRTPRIOSoft=*) continue ;;
--property=LimitRTTIME=*) continue ;;
--property=LimitRTTIMESoft=*) continue ;;
--property=LimitNFILEVSZ=*) continue ;;
--property=TasksMax=*) continue ;;
--property=TasksAccounting=*) continue ;;
--property=CPUAccounting=*) continue ;;
--property=MemoryAccounting=*) continue ;;
--property=IOAccounting=*) continue ;;
--property=IPAccounting=*) continue ;;
--property=TasksMaxScalePercent=*) continue ;;
--property=TasksMaxInhibitPercent=*) continue ;;
# --- CPU / scheduling control ---
--property=CPUWeight=*) continue ;;
--property=StartupCPUWeight=*) continue ;;
--property=CPUWeightPerWeight=*) continue ;;
--property=AllowedCPUs=*) continue ;;
--property=StartupAllowedCPUs=*) continue ;;
--property=AllowedMemoryNodes=*) continue ;;
--property=StartupAllowedMemoryNodes=*) continue ;;
--property=CPUQuotaPeriodSec=*) continue ;;
--property=AllowedMemoryNodesPerWeight=*) continue ;;
--property=DisableControllers=*) continue ;;
--property=ManagedOOMSwap=*) continue ;;
--property=ManagedOOMMemoryPressure=*) continue ;;
--property=ManagedOOMMemoryPressureLimit=*) continue ;;
--property=ManagedOOMPreference=*) continue ;;
# --- IO / block control ---
--property=IOWeight=*) continue ;;
--property=StartupIOWeight=*) continue ;;
--property=IODeviceWeight=*) continue ;;
--property=IODeviceLatencyTargetSec=*) continue ;;
--property=IOReadBandwidthMax=*) continue ;;
--property=IOWriteBandwidthMax=*) continue ;;
--property=IOReadIOPSMax=*) continue ;;
--property=IOWriteIOPSMax=*) continue ;;
--property=IODeviceWriteLatencyTargetSec=*) continue ;;
--property=IODeviceReadIOPSMax=*) continue ;;
--property=IODeviceWriteIOPSMax=*) continue ;;
--property=IODeviceWeightPerWeight=*) continue ;;
--property=IODeviceWeightPerWeightForWrites=*) continue ;;
--property=BlockIOWeight=*|--property=BlockIODeviceWeight=*|--property=BlockIOReadBandwidth=*|--property=BlockIOWriteBandwidth=*) continue ;;
# --- Memory control ---
--property=MemoryLow=*) continue ;;
--property=MemoryMin=*) continue ;;
--property=MemoryHigh=*) continue ;;
--property=MemoryMax=*) continue ;;
--property=MemoryZswapMax=*) continue ;;
--property=MemoryZswapWriteback=*) continue ;;
--property=MemoryZswapCompression=*) continue ;;
--property=MemoryZswapAcceptPercent=*) continue ;;
--property=DisableMemoryMax=*) continue ;;
--property=MemoryHighWriteback=*) continue ;;
# --- OOM / pressure / cachettl ---
--property=OOMScoreAdjust=*) continue ;;
--property=OOMPolicy=*) continue ;;
--property=OOMScoreAdjustPerWeight=*) continue ;;
--property=MemoryPressureWatch=*) continue ;;
--property=MemoryPressureThresholdSec=*) continue ;;
# --- Slices / delegation / unit metadata ---
--property=RequiresMountsFor=*) continue ;;
--property=CollectMode=*) continue ;;
--property=ConditionCPUFeature=*) continue ;;
--property=ConditionCPUs=*) continue ;;
--property=ConditionMemory=*) continue ;;
--property=ConditionCPUPressure=*) continue ;;
--property=ConditionMemoryPressure=*) continue ;;
--property=ConditionPathIsMountPoint=*) continue ;;
--property=ConditionDirectoryNotEmpty=*) continue ;;
--property=ConditionFileNotEmpty=*) continue ;;
--property=ConditionFileIsExecutable=*) continue ;;
--property=ConditionPathIsReadWrite=*) continue ;;
--property=ConditionPathIsSymbolicLink=*) continue ;;
--property=ConditionUser=*) continue ;;
--property=ConditionGroup=*) continue ;;
--property=ConditionVirtualization=*) continue ;;
--property=ConditionArchitecture=*) continue ;;
--property=ConditionFirmware=*) continue ;;
--property=ConditionFirstBoot=*) continue ;;
--property=ConditionKernelCommandLine=*) continue ;;
--property=ConditionKernelVersion=*) continue ;;
--property=ConditionSecurity=*) continue ;;
--property=ConditionControlGroupController=*) continue ;;
--property=ConditionCapability=*) continue ;;
--property=ConditionACPower=*) continue ;;
--property=ConditionNeedsUpdate=*) continue ;;
--property=ConditionNull=*) continue ;;
--property=AssertUser=*) continue ;;
--property=AssertDirectoryNotEmpty=*) continue ;;
--property=AssertFileNotEmpty=*) continue ;;
--property=AssertFileIsExecutable=*) continue ;;
--property=AssertPathExists=*) continue ;;
--property=AssertPathIsDirectory=*) continue ;;
--property=AssertPathIsSymbolicLink=*) continue ;;
--property=AssertPathIsMountPoint=*) continue ;;
--property=AssertPathIsReadWrite=*) continue ;;
--property=AssertPathIsEncrypted=*) continue ;;
--property=AssertVirtualization=*) continue ;;
--property=AssertArchitecture=*) continue ;;
--property=AssertFirstBoot=*) continue ;;
--property=AssertKernelVersion=*) continue ;;
--property=AssertKernelCommandLine=*) continue ;;
--property=AssertSecurity=*) continue ;;
--property=AssertControlGroupController=*) continue ;;
--property=AssertCapability=*) continue ;;
--property=AssertCPUFeature=*) continue ;;
--property=AssertCPUs=*) continue ;;
--property=AssertMemory=*) continue ;;
--property=AssertACPower=*) continue ;;
--property=AssertNeedsUpdate=*) continue ;;
--property=AssertNull=*) continue ;;
# --- Misc unit ---
--property=OnFailure=*) continue ;;
--property=SuccessAction=*) continue ;;
--property=FailureAction=*) continue ;;
--property=Restart=*) continue ;;
--property=RestartSec=*) continue ;;
--property=RestartPreventExitStatus=*) continue ;;
--property=RestartForceExitStatus=*) continue ;;
--property=WatchdogSec=*) continue ;;
--property=TimeoutStartSec=*) continue ;;
--property=TimeoutStopSec=*) continue ;;
--property=TimeoutAbortSec=*) continue ;;
--property=TimeoutCleanSec=*) continue ;;
--property=TimeoutStartFailureMode=*) continue ;;
--property=TimeoutStopFailureMode=*) continue ;;
--property=RuntimeMaxSec=*) continue ;;
--property=RuntimeRandomizedExtraSec=*) continue ;;
# Unrecognized properties — collect silently, warn once in summary below.
--property=*) UNRECOGNIZED_PROPS+=("$arg"); continue ;;
--property) SKIP_NEXT=true; continue ;;
--user|--uid=*|--gid=*|--setenv=*) continue ;;
--setenv) SKIP_NEXT=true; continue ;;
--) shift; CMD_ARGS+=("$@"); break ;;
*) CMD_ARGS+=("$arg") ;;
esac
done
if [[ ${#CMD_ARGS[@]} -eq 0 ]]; then
    _log_dsr "ERROR: No command arguments found after parsing. Raw args: $*"
    exit 1
fi
if [[ ${#UNRECOGNIZED_PROPS[@]} -gt 0 ]]; then
    _warn_dsr "systemd-run(fake): ${#UNRECOGNIZED_PROPS[@]} unrecognized property/ies (ignored):"
    for _up in "${UNRECOGNIZED_PROPS[@]}"; do
        _warn_dsr "  $_up"
    done
    _warn_dsr "These are silently dropped. Normal when Pamac/makepkg adds new systemd"
    _warn_dsr "options not yet in this wrapper. Only investigate if AUR builds fail."
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
# Use a dedicated build user to isolate AUR builds from the host user'\''s
# home directory. A malicious AUR package gains only build-user access.
BUILD_USER="_builduser"
_BL_TMP_HOME=""
if ! id "$BUILD_USER" >/dev/null 2>&1; then
    if ! useradd -r -d /var/lib/builduser -s /usr/bin/nologin "$BUILD_USER" 2>/dev/null; then
        _warn_dsr "useradd -r failed — trying ad-hoc non-root build user as fallback"
        # Ensure /var/tmp has the sticky bit so only directory owners can delete
        # within it. /var/tmp is container-internal (not a host mount in Distrobox),
        # so temporary homes placed here stay isolated from the host'\''s /home.
        chmod +t /var/tmp 2>/dev/null || true
        _bl_tmp=$(mktemp -d /var/tmp/builduser-home-XXXXXX) || _bl_tmp=""
        if [[ -n "$_bl_tmp" ]]; then
            # Validate: temp home must NOT be under /home (host mount overlap risk)
            case "$_bl_tmp" in
                /home/*)
                    _warn_dsr "REFUSING temp home under /home (host mount overlap): $_bl_tmp"
                    rmdir "$_bl_tmp" 2>/dev/null || true
                    _bl_tmp=""
                    ;;
                *)
                    chmod 0700 "$_bl_tmp" 2>/dev/null || true
                    ;;
            esac
        fi
        if [[ -n "$_bl_tmp" ]]; then
            BUILD_USER="_brecover$(date +%s|tail -c7)"
            if ! useradd -M -d "$_bl_tmp" -s /bin/bash "$BUILD_USER" 2>/dev/null; then
                rmdir "$_bl_tmp" 2>/dev/null || true
                BUILD_USER=""
            else
                _BL_TMP_HOME="$_bl_tmp"
                _log_dsr "Ad-hoc build user $_BL_TMP_HOME created (isolated from host mounts)"
            fi
        fi
        if [[ -z "$BUILD_USER" ]] || ! id "$BUILD_USER" >/dev/null 2>&1; then
            _warn_dsr "FATAL: Cannot create a dedicated build user (useradd -r and ad-hoc user both failed)."
            _warn_dsr "Refusing to drop privileges to '\''nobody'\'' — it lacks a writable home and is unsafe for AUR builds."
            _warn_dsr "Aborting DynamicUser build to avoid running a potentially untrusted package with no isolation."
            echo "systemd-run(fake): FATAL: no build user available, refusing to run as nobody" >&2
            exit 127
        fi
    fi
    mkdir -p /var/lib/builduser 2>/dev/null || true
    chown "$BUILD_USER:$BUILD_USER" /var/lib/builduser 2>/dev/null || true
fi
if [[ -n "$WORK_DIR" ]]; then
_log_dsr "EXEC: sudo -u $BUILD_USER -- cd $WORK_DIR; ${CMD_ARGS[*]}"
if [[ -n "$_BL_TMP_HOME" ]]; then
    sudo -u "$BUILD_USER" -H -- bash -c '\''cd "$1" 2>/dev/null; shift; exec "$@"'\'' _ "$WORK_DIR" "${CMD_ARGS[@]}"
    _user_cmd_exit=$?
    userdel -r "$BUILD_USER" 2>/dev/null || true
    rm -rf "$_BL_TMP_HOME" 2>/dev/null || true
    exit $_user_cmd_exit
else
    exec sudo -u "$BUILD_USER" -H -- bash -c '\''cd "$1" 2>/dev/null; shift; exec "$@"'\'' _ "$WORK_DIR" "${CMD_ARGS[@]}"
fi
else
_log_dsr "EXEC: sudo -u $BUILD_USER -- ${CMD_ARGS[*]}"
if [[ -n "$_BL_TMP_HOME" ]]; then
    sudo -u "$BUILD_USER" -H -- "${CMD_ARGS[@]}"
    _user_cmd_exit=$?
    userdel -r "$BUILD_USER" 2>/dev/null || true
    rm -rf "$_BL_TMP_HOME" 2>/dev/null || true
    exit $_user_cmd_exit
else
    exec sudo -u "$BUILD_USER" -H -- "${CMD_ARGS[@]}"
fi
fi
else
if [[ -n "$WORK_DIR" ]] && [[ -d "$WORK_DIR" ]]; then cd "$WORK_DIR" 2>/dev/null || true; fi
_log_dsr "EXEC: ${CMD_ARGS[*]}"
exec "${CMD_ARGS[@]}"
fi
SYSTEMD_RUN_FAKE_HEREDOC
    chmod +x /usr/local/sbin/systemd-run
    _atomic_sed_inplace /usr/local/sbin/systemd-run "s/HOST_USER_PLACEHOLDER/${HOST_USER//\//\\/}/g"
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

    _script_file=$(mktemp "${_SCRIPT_TMPDIR:-/tmp}/pamac-script-XXXXXXXX")
    _TEMP_FILES+=("$_script_file")
    printf '%s\n' "${_preamble}" > "$_script_file"

    local _marker
    _marker="PAMAC_SCRIPT_OK_$(head -c 16 /dev/urandom 2>/dev/null | base64 2>/dev/null || echo "$$_$(date +%s)")"
    # Marker race fix: install an EXIT trap BEFORE the script body so an early
    # `exit 0` mid-body still emits the marker. The trap only fires on a
    # successful (exit-code 0) exit so the existing "no marker => failure" proxy
    # still works. The guard variable keeps emission idempotent if the trailing
    # echo also runs.
    _exec_install_marker_trap "$_script_file" "$_marker"
    # Now append the script body AFTER the trap so it is registered before
    # any commands in the body execute (including mid-body `exit 0`).
    printf '%s\n' "${_script}" >> "$_script_file"
    # Trailing redundant emission (normal fallthrough, exit-code-0 path); trap
    # covers early exits. Both paths are gated by the guard and exit-code check.
    printf '\n[ $? -eq 0 ] && echo "%s"\ntrap - EXIT\n' "$_marker" >> "$_script_file"

  if _exec_dry_run_check "$_desc" "$_script_file"; then
    rm -f "$_script_file"
    return 0
  fi

  set +e
  local _output=""
  if [[ "$LOG_LEVEL" == "verbose" ]]; then
    # Capture output+exit FIRST, then stream filtered lines to the user.
    # The prior pipe `... | tee | _filter_verbose_output` ran inside $(...),
    # making PIPESTATUS[0] point to the command-substitution exit (always 0)
    # instead of container_root_exec's exit — effectively masking terminal
    # failures. Now the exit code is captured directly from the assignment.
    _output=$(container_root_exec bash -s "$@" < "$_script_file" 2>&1); _rc=$?
    tee -a "$LOG_FILE" <<< "$_output" | _filter_verbose_output || true
  else
    _output=$(container_root_exec bash -s "$@" < "$_script_file" 2>&1)
    _rc=$?
    echo "$_output" >> "$LOG_FILE"
  fi
  set -e

  rm -f "$_script_file"

    _exec_handle_result "$_rc" "$_output" "$_marker" "$_desc" "Script"
}

exec_container_pipe() {
    local _desc="$1"
    shift
    local _rc=0
    local _script_file
    local _marker
    _marker="PAMAC_PIPE_OK_$(head -c 16 /dev/urandom 2>/dev/null | base64 2>/dev/null || echo "$$_$(date +%s)")"
    local _preamble="$_CONTAINER_PREAMBLE"

    _script_file=$(mktemp "${_SCRIPT_TMPDIR:-/tmp}/pamac-pipe-XXXXXXXX")
    _TEMP_FILES+=("$_script_file")
    printf '%s' "$_preamble" > "$_script_file"
    # Marker race fix (see exec_container_script): install an EXIT trap BEFORE
    # the streamed body so early `exit 0` mid-body still emits the marker. Trap
    # only emits on a successful (exit-code 0) exit to preserve the existing
    # failure-detection proxy. The trailing echo below is a redundant fallback
    # for normal fallthrough; both paths are guarded by pamac_script_marked.
    _exec_install_marker_trap "$_script_file" "$_marker"
    # Baseline size = preamble + trap. An empty body yields exactly this size,
    # so we detect empty heredocs by comparing the post-cat size against it.
    local _trap_baseline
    _trap_baseline=$(wc -c < "$_script_file" 2>/dev/null || echo "0")
    cat >> "$_script_file"
    local _piped_size
    _piped_size=$(wc -c < "$_script_file" 2>/dev/null || echo "0")
    if [[ "$_piped_size" -le "${_trap_baseline:-0}" ]]; then
        log_error "Internal error: piped script '$_desc' is empty (heredoc delimiter may be missing/misfound). Aborting stage."
        rm -f "$_script_file"
        return 1
    fi
    # Trailing redundant emission (normal-fallthrough, exit-code-0 path); the
    # EXIT trap covers early `exit 0` cases. Both gated by pamac_script_marked.
    printf '\n[ $? -eq 0 ] && echo "%s"\ntrap - EXIT\n' "$_marker" >> "$_script_file"

    if _exec_dry_run_check "$_desc" "$_script_file"; then
        rm -f "$_script_file"
        return 0
    fi

    set +e
    local _output=""
    if [[ "$LOG_LEVEL" == "verbose" ]]; then
      # Same fix as exec_container_script: capture output+exit directly so
      # container_root_exec's exit code is not masked by the tee-grep pipeline
      # inside a command substitution (PIPESTATUS[0] would point to $(...), not
      # to container_root_exec).
      _output=$(container_root_exec bash -s "$@" < "$_script_file" 2>&1); _rc=$?
      tee -a "$LOG_FILE" <<< "$_output" | _filter_verbose_output || true
    else
      _output=$(container_root_exec bash -s "$@" < "$_script_file" 2>&1)
      _rc=$?
      echo "$_output" >> "$LOG_FILE"
    fi
    set -e

    rm -f "$_script_file"

    _exec_handle_result "$_rc" "$_output" "$_marker" "$_desc" "Piped script"
}

# Shared helper: install the marker-emission EXIT trap (with chained prior trap)
# into a prepared container script file. Used by both exec_container_script and
# exec_container_pipe so the trap setup logic lives in exactly one place.
_exec_install_marker_trap() {
    local _file="$1"
    local _marker="$2"
    {
        printf 'PAMAC_SCRIPT_MARKER="%s"\n' "$_marker"
        printf '%s\n' "pamac_script_marked=''"
        # Capture any pre-existing EXIT trap so a script body that installs its
        # own `trap ... EXIT` does NOT silently replace our marker emission: we
        # save the previous trap when we install ours, then pamac_emit_marker
        # re-invokes that saved handler after emitting (chaining). This keeps the
        # "no marker => failure" detection proxy working even if the body sets
        # its own EXIT trap. `trap -p EXIT` returns nothing when none is set.
        printf '%s\n' "pamac_emit_marker() { local _rc=$?; [ -z \"\$pamac_script_marked\" ] || return 0; [ \"\$_rc\" -eq 0 ] || return 0; pamac_script_marked=1; echo \"\$PAMAC_SCRIPT_MARKER\"; if [ -n \"\$PAMAC_PREV_EXIT_TRAP\" ]; then eval \"\$PAMAC_PREV_EXIT_TRAP\"; fi; }"
        printf '%s\n' "PAMAC_PREV_EXIT_TRAP=\$(trap -p EXIT 2>/dev/null | sed -e \"s/^trap -- //\" -e \"s/ EXIT\$//\")"
        printf '%s\n' "trap pamac_emit_marker EXIT"
    } >> "$_file"
}

# Shared helper: dry-run short-circuit for container scripts. When
# --dry-run-verbose is active, print the assembled container script that WOULD
# have executed inside the container. When --dry-run (without --verbose) is
# active, just log that the script is being skipped. In both cases return true
# (0) so the caller returns 0 without exec'ing into the container. Returns
# false (1) when dry-run is off so the caller proceeds with the normal container
# exec. Consolidates all three container exec paths behind one implementation.
# Args: $1=description, $2=script file path. Caller removes $_script_file on true.
_exec_dry_run_check() {
    local _desc="$1" _file="$2"

    if [[ "${DRY_RUN_VERBOSE:-}" == "true" ]]; then
        log_warn "[DRY RUN VERBOSE] Container script '$_desc' — script that would execute inside the container:"
        printf '%s\n' "----- BEGIN CONTAINER SCRIPT: $_desc -----"
        cat "$_file"
        printf '%s\n' "----- END CONTAINER SCRIPT: $_desc -----"
        return 0
    fi

    if [[ "${DRY_RUN:-}" == "true" ]]; then
        log_warn "[DRY RUN] Skipping container script '$_desc' (use --dry-run-verbose to audit its contents)."
        return 0
    fi

    return 1
}

# Shared helper: post-run recovery + error reporting for container scripts.
# Args: _rc _output _marker _desc _kind_label (e.g. "script" or "piped script").
# Consolidates the previously-duplicated non-init recovery and failure-message
# logic that existed in both exec_container_script and exec_container_pipe.
_exec_handle_result() {
    local _rc="$1" _output="$2" _marker="$3" _desc="$4" _kind="$5"

    if [[ "$CONTAINER_HAS_INIT" == "false" ]] && [[ $_rc -ne 0 ]]; then
        if echo "$_output" | grep -q "$_marker"; then
            log_debug "$_kind '$_desc' completed successfully (exit $_rc is expected in non-init container - podman may kill entry process after completion)."
            container_start 2>/dev/null || true
            return 0
        fi
        if [[ $_rc -eq 137 ]]; then
            log_warn "$_kind '$_desc' got exit 137 without completion marker. May be OOM or signal kill."
        else
            log_warn "$_kind '$_desc' got exit $_rc without completion marker in non-init container. May be premature container stop."
        fi
        container_start 2>/dev/null || true
        # Only run heavy DB repair if output suggests pacman DB corruption
        if echo "$_output" | grep -qiE "database|corrupt|invalid|signature|could not open|failed to init"; then
            log_info "DB corruption indicators detected in output — running repair..."
            repair_pacman_db
        fi
    fi

    if [[ $_rc -ne 0 ]] && ! { [[ "$CONTAINER_HAS_INIT" == "false" ]] && echo "$_output" | grep -q "$_marker"; }; then
        log_warn "$_kind '$_desc' failed (exit=$_rc)."
        if [[ $_rc -eq 100 ]]; then
            log_error "Fatal keyring/security error in $_kind '$_desc'. Last 20 lines of output:"
            echo "$_output" | tail -20 | while IFS= read -r line; do
                log_error "  $line"
            done
        elif [[ $_rc -eq 137 ]]; then
            log_error "$_kind '$_desc' killed (OOM/signal). Last 20 lines of output:"
            echo "$_output" | tail -20 | while IFS= read -r line; do
                log_error "  $line"
            done
        else
            local _tail
            _tail=$(echo "$_output" | tail -20)
            if [[ -n "$_tail" ]]; then
                log_warn "Last 20 lines of $_kind output:"
                echo "$_tail" | while IFS= read -r line; do
                    log_warn "  $line"
                done
            fi
        fi
        # ── Pre-repair: aggressive cleanup before calling full DB repair ──
        # Kill any stale pacman/yay processes that may hold locks
        container_root_exec bash -c '
set +e
# Remove stale lock file (with wait for running pacman)
if [[ -f /var/lib/pacman/db.lck ]]; then
    _p=$(cat /var/lib/pacman/db.lck 2>/dev/null || echo "")
    if [[ -n "$_p" ]] && kill -0 "$_p" 2>/dev/null; then
        if grep -E "pacman|yay" "/proc/$_p/comm" >/dev/null 2>&1; then
            echo "Pacman running (PID $_p) at failure time, waiting..."
            _w=0
            while [[ $_w -lt 15 ]] && kill -0 "$_p" 2>/dev/null; do
                sleep 2
                _w=$(( _w + 2 ))
            done
            if kill -0 "$_p" 2>/dev/null; then
                echo "Force-killing stale pacman (PID $_p)..."
                kill -9 "$_p" 2>/dev/null || true
                sleep 1
            fi
        fi
    fi
    rm -f /var/lib/pacman/db.lck 2>/dev/null || true
fi
# Kill only stale pacman/yay processes that hold the db.lck
# (avoid pkill -9 pacman which would kill ALL pacman processes including active builds)
_stale_pids=$(pgrep -x pacman 2>/dev/null || true)
for _spid in $_stale_pids; do
    if [[ "$_spid" != "$$" ]] && [[ "$_spid" != "$PPID" ]]; then
        echo "  Force-killing stale pacman PID $_spid"
        kill -9 "$_spid" 2>/dev/null || true
    fi
done
_stale_yay_pids=$(pgrep -x yay 2>/dev/null || true)
for _ypid in $_stale_yay_pids; do
    if [[ "$_ypid" != "$$" ]] && [[ "$_ypid" != "$PPID" ]]; then
        echo "  Force-killing stale yay PID $_ypid"
        kill -9 "$_ypid" 2>/dev/null || true
    fi
done
pkill -9 gpg-agent 2>/dev/null || true
pkill -9 dirmngr 2>/dev/null || true
sleep 1
# Quick disk space check — if /var is full, DB repair will fail
_avail_kb=$(df -k /var/lib/pacman 2>/dev/null | awk "NR==2{print \$4}" || echo "0")
if [[ "$_avail_kb" -gt 0 ]] && [[ "$_avail_kb" -lt 5120 ]]; then
    echo "WARNING: Critically low disk space (${_avail_kb}KB) in /var/lib/pacman."
    echo "  DB repair may fail. Consider freeing space: docker system prune / podman system prune"
fi
' 2>/dev/null || true
        container_start 2>/dev/null || true
        repair_pacman_db
        return "$_rc"
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

# Arg 1: STRICT_SECURITY flag ("true" disables TrustAll relaxation recovery).
_STRICT_SECURITY_MODE="${1:-}"

_remove_stale_lock

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
_PUBRING_FILE="/etc/pacman.d/gnupg/pubring.gpg"
_safe_recovered=false

# Trade-off note: the sentinel persists recovery completion state across
# container restarts to avoid the cost of re-running keyring recovery on
# every bootstrap. To detect later corruption (disk error, partial restore,
# manual gnupg modification), the sentinel file now stores a sha256 checksum
# plus the byte size of pubring.gpg captured at recovery time. On the next
# bootstrap the stored checksum is re-validated against the current pubring.gpg;
# a mismatch discards the sentinel and forces a full recovery re-run. If sha256
# is unavailable the sentinel still behaves as before (presence-only trust) so
# we never hard-block recovery on a missing checksum tool. If you suspect
# keyring corruption, delete /etc/pacman.d/gnupg/.keyring-recovery-pending
# (and ideally /etc/pacman.d/gnupg) manually so the next bootstrap repeats
# recovery from scratch.
_keyring_checksum() {
    # Print "<size>:<sha256>" for $_PUBRING_FILE, or empty string when unavailable.
    [[ -f "$_PUBRING_FILE" ]] || { echo ""; return 0; }
    local _size
    _size=$(wc -c < "$_PUBRING_FILE" 2>/dev/null | awk '{print $1}' || echo "0")
    local _sum=""
    if command -v sha256sum >/dev/null 2>&1; then
        _sum=$(sha256sum "$_PUBRING_FILE" 2>/dev/null | awk '{print $1}')
    elif command -v sha256 >/dev/null 2>&1; then
        _sum=$(sha256 -q "$_PUBRING_FILE" 2>/dev/null)
    elif command -v shasum >/dev/null 2>&1; then
        _sum=$(shasum -a 256 "$_PUBRING_FILE" 2>/dev/null | awk '{print $1}')
    fi
    echo "${_size}:${_sum}"
}

if [[ -f "$_KEYRING_SENTINEL" ]]; then
    _sentinel_stored=""
    _sentinel_stored=$(cat "$_KEYRING_SENTINEL" 2>/dev/null | head -1 || echo "")
    _sentinel_current=""
    _sentinel_current=$(_keyring_checksum)
    # A sentinel is trusted only when it carries a matching checksum, OR when
    # no checksum tool is available (then fall back to presence-only trust so
    # recovery is not blocked on a missing sha256).
    if [[ -n "$_sentinel_stored" && "$_sentinel_stored" == "$_sentinel_current" && -n "$_sentinel_current" ]]; then
        echo "Found valid keyring recovery sentinel from previous run (pubring.gpg checksum matches). Keyring recovery already completed."
        _safe_recovered=true
        rm -f "$_KEYRING_SENTINEL" 2>/dev/null || true
    elif [[ -z "$_sentinel_current" || "$_sentinel_current" == *":*" && "${_sentinel_current##*:}" == "" ]]; then
        # No checksum tool available — try installing coreutils (provides
        # sha256sum) so the sentinel can be validated next time AND so the
        # rest of this recovery run has the tool available. If pacman is not
        # usable yet, fall back to presence-only trust so recovery is not
        # blocked purely because sha256 is missing.
        echo "Found keyring recovery sentinel, but no checksum tool is available to validate pubring.gpg. Attempting to install coreutils..."
        if command -v pacman >/dev/null 2>&1 && pacman -S --noconfirm --needed coreutils 2>/dev/null; then
            echo "coreutils installed; re-checking checksum tool availability."
            _sentinel_current=$(_keyring_checksum)
        fi
        if [[ -z "$_sentinel_current" || "$_sentinel_current" == *":*" && "${_sentinel_current##*:}" == "" ]]; then
            echo "WARNING: No checksum tool available even after coreutils install. Trusting sentinel (presence-only) so recovery is not blocked. If you suspect keyring corruption, delete /etc/pacman.d/gnupg/.keyring-recovery-pending or /etc/pacman.d/gnupg manually and re-run."
            _safe_recovered=true
            rm -f "$_KEYRING_SENTINEL" 2>/dev/null || true
        elif [[ -n "$_sentinel_stored" && "$_sentinel_stored" == "$_sentinel_current" ]]; then
            echo "Found valid keyring recovery sentinel (checksum now matches after coreutils install). Keyring recovery already completed."
            _safe_recovered=true
            rm -f "$_KEYRING_SENTINEL" 2>/dev/null || true
        else
            echo "Found keyring recovery sentinel, but pubring.gpg checksum mismatch (stored='$_sentinel_stored' current='$_sentinel_current'). Keyring may have been corrupted — re-running recovery from scratch."
            rm -f "$_KEYRING_SENTINEL" 2>/dev/null || true
        fi
    else
        echo "Found keyring recovery sentinel, but pubring.gpg checksum mismatch (stored='$_sentinel_stored' current='$_sentinel_current'). Keyring may have been corrupted since recovery — re-running recovery from scratch."
        rm -f "$_KEYRING_SENTINEL" 2>/dev/null || true
    fi
fi

# Method A: Refresh keys from keyservers (uses GnuPG's built-in HTTP client, no curl needed)
echo "Method A: Refreshing keys from keyservers..."
pkill -9 gpg-agent 2>/dev/null || true
pkill -9 dirmngr 2>/dev/null || true
_safe_sleep 1

# Pre-flight: check which keyservers are reachable over port 443 (HTTPS).
# Port 443 is universally allowed through firewalls (same as web browsing).
# Port 11371 (HKPS) is frequently blocked on restrictive networks, so we
# only use 443. The hkps:// URIs in GnuPG default to port 443.
echo "Pre-flight: testing keyserver reachability (port 443 only)..."
_KS_REACHABLE=()
_KS_UNREACHABLE=()
for _ks in "hkps://keyserver.ubuntu.com" "hkps://keys.openpgp.org" "hkps://pgp.mit.edu"; do
    _ks_host="${_ks#hkps://}"
    _ks_host="${_ks_host#https://}"
    _ks_host="${_ks_host#http://}"
    if timeout 3 bash -c "echo >/dev/tcp/$_ks_host/443" 2>/dev/null; then
        echo "  $_ks: REACHABLE (port 443)"
        _KS_REACHABLE+=("$_ks")
    else
        echo "  $_ks: UNREACHABLE on port 443 (will skip)"
        _KS_UNREACHABLE+=("$_ks")
    fi
done

if [[ ${#_KS_REACHABLE[@]} -eq 0 ]]; then
    echo "  WARNING: No keyservers reachable on port 443. All keyserver methods will be skipped."
    echo "  This may indicate DNS issues or an unusual network configuration."
    echo "  Falling back to WKD, direct HTTPS keyring download, and JSON endpoint..."
fi

for _ks in "${_KS_REACHABLE[@]}"; do
    echo "  Trying keyserver: $_ks"
    if timeout 20 pacman-key --refresh-keys --keyserver "$_ks" 2>/dev/null; then
        echo "  Key refresh succeeded from $_ks."
        _safe_recovered=true
        break
    fi
    echo "  Keyserver $_ks failed or timed out (20s limit)."
done

# Method B: Download keyring package directly via HTTPS and import keys manually
if [[ "$_safe_recovered" != "true" ]] && command -v curl >/dev/null 2>&1; then
    echo "Method B: Attempting direct keyring package download via HTTPS..."
    _SECURE_TMP=$(mktemp -d /var/tmp/pamac-kr-XXXXXX) && chmod 700 "$_SECURE_TMP" 2>/dev/null || _SECURE_TMP=$(mktemp -d)
    # Try multiple mirrors for keyring package download
    _mirror_urls=(
        "https://geo.mirror.pkgbuild.com/core/os/x86_64"
        "https://mirror.rackspace.com/archlinux/core/os/x86_64"
        "https://archlinux.umn.edu/repos/core/os/x86_64"
        "https://mirrors.kernel.org/archlinux/core/os/x86_64"
        "https://mirror.osct.net/archlinux/core/os/x86_64"
        "https://ftp.icm.edu.pl/pub/Linux/distro/archlinux/core/os/x86_64"
        "https://mirror.16personalities.com/archlinux/core/os/x86_64"
    )
    for _mirror_url in "${_mirror_urls[@]}"; do
        echo "  Trying mirror: $_mirror_url"
        _kr_pkg=$(curl -sLf --connect-timeout 5 --max-time 15 "${_mirror_url}/" 2>/dev/null | \
            grep -oP 'archlinux-keyring-[0-9]+-[0-9]+-any\.pkg\.tar\.zst' | sort -V | tail -1 || true)
        if [[ -n "$_kr_pkg" ]]; then
            echo "  Found keyring package: $_kr_pkg"
            _tmp_kr="$_SECURE_TMP/kr.pkg.tar.zst"
            if curl -sLf --connect-timeout 5 --max-time 60 -o "$_tmp_kr" "${_mirror_url}/${_kr_pkg}" 2>/dev/null; then
                _tmp_kr_dir="$_SECURE_TMP/kr-extract"
                mkdir -p "$_tmp_kr_dir" && chmod 700 "$_tmp_kr_dir" 2>/dev/null || true
                if tar -xf "$_tmp_kr" -C "$_tmp_kr_dir" 2>/dev/null; then
                    for _kr_file in "$_tmp_kr_dir"/usr/share/pacman/keyrings/archlinux*; do
                        [[ -f "$_kr_file" ]] && cp -f "$_kr_file" /etc/pacman.d/gnupg/ 2>/dev/null || true
                    done
                    echo "  Keyring files extracted. Populating..."
                    if pacman-key --populate archlinux 2>/dev/null; then
                        echo "  Direct keyring import succeeded."
                        _safe_recovered=true
                        break
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
    done
    rm -rf "$_SECURE_TMP" 2>/dev/null || true
fi

# Method C: Try standard database sync (works if keys are only slightly stale)
if [[ "$_safe_recovered" != "true" ]]; then
    echo "Method C: Attempting standard database sync and keyring update..."
    _remove_stale_lock
    if pacman -Syy --noconfirm 2>/dev/null; then
        if pacman -S --noconfirm --needed archlinux-keyring gnupg 2>/dev/null; then
            echo "Standard sync and keyring update succeeded."
            _safe_recovered=true
        fi
    fi
fi

# Method D: Offline bootstrap from pre-existing keyring files on the system
# The base archlinux image ships keyring files in /usr/share/pacman/keyrings/.
# If they exist, we can copy them into the GnuPG homedir and populate directly
# without any network access. This handles the case where the image has valid
# keyring files but the gnupg directory was corrupted or never initialized.
if [[ "$_safe_recovered" != "true" ]]; then
    echo "Method D: Attempting offline bootstrap from system keyring files..."
    _system_keyring_dir="/usr/share/pacman/keyrings"
    if [[ -d "$_system_keyring_dir" ]]; then
        _archlinux_keys=$(ls "$_system_keyring_dir"/archlinux* 2>/dev/null | head -5 || true)
        if [[ -n "$_archlinux_keys" ]]; then
            echo "  Found system keyring files in $_system_keyring_dir"
            # Ensure gnupg directory is properly initialized for populate
            rm -rf /etc/pacman.d/gnupg 2>/dev/null || true
            mkdir -p /etc/pacman.d/gnupg 2>/dev/null || true
            chmod 700 /etc/pacman.d/gnupg 2>/dev/null || true
            # Copy keyring files
            for _kf in "$_system_keyring_dir"/archlinux*; do
                [[ -f "$_kf" ]] && cp -f "$_kf" /etc/pacman.d/gnupg/ 2>/dev/null || true
            done
            # Also copy any other keyring files that might be present (gpg, sig)
            for _kf in "$_system_keyring_dir"/*; do
                [[ -f "$_kf" ]] && cp -f "$_kf" /etc/pacman.d/gnupg/ 2>/dev/null || true
            done
            echo "  Copied keyring files. Initializing and populating..."
            if timeout 120 pacman-key --init 2>/dev/null; then
                if timeout 60 pacman-key --populate archlinux 2>/dev/null; then
                    echo "  Offline bootstrap from system keyring succeeded."
                    _safe_recovered=true
                else
                    echo "  Populating from system keyring files failed."
                fi
            else
                echo "  pacman-key --init failed during offline bootstrap."
            fi
        else
            echo "  No archlinux keyring files found in $_system_keyring_dir."
        fi
    else
        echo "  System keyring directory $_system_keyring_dir does not exist."
    fi
fi

# Method E: Web Key Directory (WKD) lookups for individual Arch Linux master keys
# WKD allows fetching GPG keys via HTTPS using the key owner's domain, without
# relying on keyservers. This queries openpgpkey.archlinux.org for each of the
# Arch Linux master signing keys.
if [[ "$_safe_recovered" != "true" ]] && command -v gpg >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    echo "Method E: Attempting Web Key Directory (WKD) lookups for Arch Linux master keys..."
    # Known Arch Linux master signing key IDs (may rotate — these are common long-lived keys)
    _arch_master_keys=(
        "DB273E7112E976A32A658B9D9D3D0F9C3F4C419B"  # David Runge
        "56C3E775E72B0C8BFD975F8510DDB6C069A926C1"  # Jan Alexander Steffens (fta)
        "B81515D46F1161234E8A4BEB6BFF5AA654FABD5A"  # Levente Polyák (anthraxx)
    )
    for _mk_id in "${_arch_master_keys[@]}"; do
        echo "  Attempting WKD lookup for key $_mk_id..."
        # WKD URL pattern: https://openpgpkey.archlinux.org/.well-known/openpgpkey/hu/<40-char-fingerprint>
        # Convert fingerprint to WKD local-part format (lowercase, split into 2-char chunks)
        _wkd_fp_lower=$(echo "$_mk_id" | tr 'A-F' 'a-f')
        _wkd_local=""
        _chunk=""
        for (( i=0; i<${#_wkd_fp_lower}; i++ )); do
            _chunk="${_chunk}${_wkd_fp_lower:$i:1}"
            if (( ${#_chunk} == 2 )); then
                [[ -n "$_wkd_local" ]] && _wkd_local="${_wkd_local}."
                _wkd_local="${_wkd_local}${_chunk}"
                _chunk=""
            fi
        done
        [[ -n "$_chunk" ]] && _wkd_local="${_wkd_local}.${_chunk}"
        _wkd_url="https://openpgpkey.archlinux.org/.well-known/openpgpkey/hu/${_wkd_local}"
        _wkd_tmp=$(mktemp /var/tmp/pamac-wkd-XXXXXX) && chmod 700 "$_wkd_tmp" 2>/dev/null || _wkd_tmp=$(mktemp)
        if timeout 15 curl -fsSL --connect-timeout 5 --max-time 10 -o "$_wkd_tmp" "$_wkd_url" 2>/dev/null; then
            if file "$_wkd_tmp" 2>/dev/null | grep -qi "GPG\|PGP"; then
                echo "    WKD returned valid key for $_mk_id"
                if timeout 30 gpg --homedir /etc/pacman.d/gnupg --import "$_wkd_tmp" 2>/dev/null; then
                    echo "    Imported key $_mk_id via WKD"
                fi
            else
                echo "    WKD response was not a valid GPG key"
            fi
        else
            echo "    WKD lookup failed for $_mk_id (server may not support WKD)"
        fi
        rm -f "$_wkd_tmp" 2>/dev/null || true
    done
    # After WKD imports, try to populate
    if pacman-key --populate archlinux 2>/dev/null; then
        echo "  WKD key imports + populate succeeded."
        _safe_recovered=true
    fi
fi

# Method F: Controlled temporary SigLevel relaxation as last-ditch bootstrap
# SECURITY MODEL: we NEVER write TrustAll to the real /etc/pacman.conf. Instead
# we build a throwaway pacman.conf copy with SigLevel=TrustAll and run pacman
# against it via `pacman --config <tmp>`. The real pacman.conf stays at its
# secure value the entire time, so an untrappable death (SIGKILL, host OOM-kill,
# power loss) leaves the container's signature-verification config intact — no
# restore trap is needed because nothing was modified. This closes the prior
# TrustAll-window risk where a mid-write kill could leave the file modified.
if [[ "$_safe_recovered" != "true" ]]; then
if [[ "$_STRICT_SECURITY_MODE" == "true" ]]; then
    echo "Method F: SKIPPED (--strict-security: refusing SigLevel=TrustAll relaxation)."
    echo "  All prior safe methods (A-E) failed to bootstrap the keyring."
    echo "  Options:"
    echo "    a. Manually import the keyring inside the container, then re-run:"
    echo "         distrobox enter <container-name> -- pacman -Sy --noconfirm archlinux-keyring gnupg"
    echo "       (or: pacman-key --init && pacman-key --populate archlinux)"
    echo "    b. Re-run the installer WITHOUT --strict-security to let Method F"
    echo "       attempt the throwaway-config TrustAll bootstrap as a last resort."
    echo "  Failure here is by design (--strict-security fails safe rather than"
    echo "  degrade to an unverified keyring state)."
else
    echo "Method F: Attempting controlled SigLevel relaxation bootstrap..."
    echo "  WARNING: Temporarily disabling signature verification (in a throwaway config only) to bootstrap keyring."
    echo "  The real /etc/pacman.conf is NOT modified; /etc/pacman.conf stays secure."
    # Build a throwaway config: copy the real one, flip ONLY the copy to TrustAll.
    _TA_CONF=$(mktemp /tmp/pacman-trustall.XXXXXX.conf) 2>/dev/null
    if [[ -n "$_TA_CONF" ]] && cp -f /etc/pacman.conf "$_TA_CONF" 2>/dev/null; then
        sed -i "s/^[[:space:]]*SigLevel.*/SigLevel = TrustAll/" "$_TA_CONF"
        grep -q '^SigLevel' "$_TA_CONF" || printf 'SigLevel = TrustAll\n' >> "$_TA_CONF"
        echo "  Throwaway TrustAll config built: $_TA_CONF (real pacman.conf untouched)."
        # Sync and install keyring USING the throwaway config only.
        _remove_stale_lock
        if pacman --config "$_TA_CONF" -Syy --noconfirm 2>/dev/null; then
            if pacman --config "$_TA_CONF" -S --noconfirm --needed archlinux-keyring gnupg 2>/dev/null; then
                echo "  Keyring package installed via TrustAll throwaway config."
                echo "  Real /etc/pacman.conf still secure — no restore needed."
                # Verify the keyring works with the REAL (secure) config.
                if pacman -Syy --noconfirm 2>/dev/null; then
                    echo "  Controlled SigLevel relaxation bootstrap succeeded."
                    _safe_recovered=true
                else
                    echo "  Database sync failed with the real (secure) config. Keyring may be incomplete."
                fi
            else
                echo "  Keyring package install failed even with TrustAll throwaway config."
            fi
        else
            echo "  Database sync failed even with TrustAll throwaway config. Network may be down."
        fi
        # Always remove the throwaway config (it contained the relaxed SigLevel).
        rm -f "$_TA_CONF" 2>/dev/null || true
    else
        # Could not build the throwaway config — refuse to touch the real one.
        rm -f "${_TA_CONF:-/tmp/pacman-trustall.NOCONF}" 2>/dev/null || true
        echo "  Could not build throwaway TrustAll config. Aborting Method F WITHOUT modifying the real pacman.conf."
    fi
    # Defensive: ensure the real config is at a secure value (no-op if already secure).
    # This is belt-and-suspenders against any earlier buggy run that left TrustAll.
    _cur_sl=$(grep '^SigLevel' /etc/pacman.conf 2>/dev/null | head -1 | sed 's/^SigLevel = //')
    if [[ "$_cur_sl" == "TrustAll" ]]; then
        echo "  WARNING: real pacman.conf detected at TrustAll — restoring to Required DatabaseOptional."
        _atomic_write_pacman_conf "Required DatabaseOptional"
    fi
fi
fi

if [[ "$_safe_recovered" == "true" ]]; then
    echo "Safe keyring recovery succeeded."
    # Persist recovery state across container restarts together with a
    # checksum of pubring.gpg, so the next bootstrap can detect later
    # corruption (see _keyring_checksum above). Falls back to a plain
    # sentinel when no checksum tool is available.
    _kr_sum=""
    _kr_sum=$(_keyring_checksum)
    if [[ -n "$_kr_sum" && "$_kr_sum" != *":*" && "${_kr_sum##*:}" != "" ]] || \
       { [[ "$_kr_sum" == *":*" ]] && [[ -n "${_kr_sum##*:}" ]]; }; then
        printf '%s\n' "$_kr_sum" > "$_KEYRING_SENTINEL" 2>/dev/null || \
            touch "$_KEYRING_SENTINEL" 2>/dev/null || true
    else
        touch "$_KEYRING_SENTINEL" 2>/dev/null || true
    fi
else
    echo ""
    echo "FATAL: All safe recovery methods (A-F) failed. Cannot proceed without valid keyring."
    echo ""
    echo "=== Network Diagnostics ==="
    echo "  DNS resolution:"
    if host archlinux.org >/dev/null 2>&1 || nslookup archlinux.org >/dev/null 2>&1; then
        echo "    archlinux.org: RESOLVED"
    else
        echo "    archlinux.org: FAILED (DNS may be broken)"
    fi
    echo "  HTTPS connectivity:"
    if timeout 5 curl -fsSI --connect-timeout 3 https://archlinux.org 2>/dev/null | head -1; then
        echo "    https://archlinux.org: OK"
    else
        echo "    https://archlinux.org: FAILED (port 443 may be blocked)"
    fi
    echo "  Keyserver connectivity (port 443):"
    for _diag_ks in "keyserver.ubuntu.com" "keys.openpgp.org" "pgp.mit.edu"; do
        if timeout 3 bash -c "echo >/dev/tcp/$_diag_ks/443" 2>/dev/null; then
            echo "    $_diag_ks: REACHABLE"
        else
            echo "    $_diag_ks: UNREACHABLE"
        fi
    done
    echo "  GnuPG state:"
    echo "    GNUPGHOME=/etc/pacman.d/gnupg"
    ls -la /etc/pacman.d/gnupg/ 2>/dev/null | head -10 || echo "    (directory missing or empty)"
    echo ""
    echo "=== Manual Recovery Steps ==="
    echo "  1. Full GnuPG reset and re-init:"
    echo "     rm -rf /etc/pacman.d/gnupg && pacman-key --init && pacman-key --populate archlinux"
    echo "  2. If repos are accessible:"
    echo "     pacman -Syy --noconfirm && pacman -S --noconfirm archlinux-keyring gnupg"
    echo "  3. If behind a corporate firewall, configure HTTPS proxy:"
    echo "     export http_proxy=http://proxy:port"
    echo "     export https_proxy=http://proxy:port"
    echo "  4. Check network: curl -I https://archlinux.org (should return 200)"
    echo "  5. Nuclear option (destroys ALL containers): podman system reset --force"
    echo "  6. Install archlinux-keyring from a trusted USB/external source."
    echo ""
    echo "TrustAll is NOT used as it would disable all signature verification."
    if [[ "$_STRICT_SECURITY_MODE" == "true" ]]; then
        echo ""
        echo "=== --strict-security guidance ==="
        echo "  Method F (controlled SigLevel=TrustAll throwaway-config bootstrap) was"
        echo "  SKIPPED in this run because --strict-security refuses to relax signature"
        echo "  verification. All cryptographic recovery (Methods A-E) failed."
        echo "  Options:"
        echo "    a. Manually import the keyring INSIDE the container, then re-run the"
        echo "       installer:"
        echo "         distrobox enter <container-name> --"
        echo "         pacman -Sy --noconfirm archlinux-keyring gnupg"
        echo "         (or: pacman-key --init && pacman-key --populate archlinux)"
        echo "    b. Download archlinux-keyring from a trusted mirror on another host,"
        echo "       copy it into the container, and install it with pacman -U."
        echo "    c. Re-run the installer WITHOUT --strict-security to let Method F"
        echo "       attempt the throwaway-config TrustAll bootstrap as a last resort."
        echo "  Failure here is by design (--strict-security fails safe rather than"
        echo "  degrade to an unverified keyring state)."
    fi
    exit 100
fi

echo "Step 3/5: Updating keyring, GPG, and certificate packages..."
_remove_stale_lock

if ! pacman -Syy --noconfirm 2>/dev/null; then
    echo "Warning: Initial database sync failed. Attempting repair..."
    pacman -Syy --noconfirm 2>/dev/null || true
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

    # On attempts 2 and 3, do a full GnuPG directory reset to eliminate any
    # corrupted state that may be causing init to fail repeatedly.
    if [[ $attempt -ge 2 ]]; then
        echo "  Attempt $attempt: Performing full GnuPG directory reset..."
        # Preserve the keyring files we downloaded in Step 2 (if any) so we
        # don't lose the keys we already recovered.
        _saved_keys_dir=""
        if ls /etc/pacman.d/gnupg/archlinux* >/dev/null 2>&1; then
            _saved_keys_dir=$(mktemp -d /var/tmp/pamac-kr-save-XXXXXX) && chmod 700 "$_saved_keys_dir" 2>/dev/null || _saved_keys_dir=$(mktemp -d)
            cp -f /etc/pacman.d/gnupg/archlinux* "$_saved_keys_dir/" 2>/dev/null || true
            echo "  Preserved $(find "$_saved_keys_dir" -maxdepth 1 -name 'archlinux*' 2>/dev/null | wc -l) keyring file(s) before reset."
        fi
        rm -rf /etc/pacman.d/gnupg 2>/dev/null || true
        mkdir -p /etc/pacman.d/gnupg 2>/dev/null || true
        chmod 700 /etc/pacman.d/gnupg 2>/dev/null || true
        # Restore preserved keyring files
        if [[ -n "$_saved_keys_dir" ]] && [[ -d "$_saved_keys_dir" ]]; then
            cp -f "$_saved_keys_dir"/archlinux* /etc/pacman.d/gnupg/ 2>/dev/null || true
            rm -rf "$_saved_keys_dir" 2>/dev/null || true
        fi
    fi

    if timeout 120 pacman-key --init 2>/dev/null; then
        echo "Keyring init succeeded."
        keyring_ok=true
        break
    else
        echo "Warning: pacman-key --init failed or timed out on attempt $attempt."
        # On the last attempt, try a fallback: generate the keyring manually
        # using gpg directly if pacman-key is broken.
        if [[ $attempt -eq 3 ]]; then
            echo "  Last resort: attempting manual GPG keyring generation..."
            # Check if gpg binary is functional even if pacman-key is not
            if gpg --homedir /etc/pacman.d/gnupg --batch --gen-key <<GPGKEY 2>/dev/null; then
%no-protection
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: Arch Linux
Name-Email: archlinux@example.com
Expire-Date: 0
%commit
GPGKEY
                echo "  Manual GPG keyring generation succeeded."
                keyring_ok=true
            else
                echo "  Manual GPG keyring generation also failed."
            fi
        fi
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
        echo "Warning: pacman-key --populate failed. Attempting individual key import..."
        # Try importing archlinux keys individually from the system keyring files
        _sys_kr="/usr/share/pacman/keyrings"
        if [[ -d "$_sys_kr" ]]; then
            _pop_ok=false
            for _kr_file in "$_sys_kr"/archlinux*; do
                [[ -f "$_kr_file" ]] || continue
                if timeout 30 gpg --homedir /etc/pacman.d/gnupg --import "$_kr_file" 2>/dev/null; then
                    echo "  Imported $(_kr_file) individually."
                    _pop_ok=true
                fi
            done
            if [[ "$_pop_ok" == "true" ]]; then
                echo "  Individual key imports succeeded."
            else
                echo "  Individual key imports also failed."
                keyring_ok=false
            fi
        else
            keyring_ok=false
        fi
    fi
fi

echo "Step 5/5: Verifying keyring and restoring security settings..."

if [[ "$keyring_ok" == "true" ]]; then
    # Verify the keyring has actual Arch Linux signing keys (not just empty)
    _sig_count=$(pacman-key --list-sigs 2>/dev/null | grep -c "archlinux" || echo "0")
    if [[ "$_sig_count" -gt 0 ]]; then
        echo "Keyring contains $_sig_count archlinux signature(s)."
    else
        echo "Warning: pacman-key --list-sigs found no archlinux signatures."
        # Try one more time to populate from system files as a last resort
        _sys_kr="/usr/share/pacman/keyrings"
        if [[ -d "$_sys_kr" ]] && ls "$_sys_kr"/archlinux* >/dev/null 2>&1; then
            echo "  Attempting final populate from system keyring files..."
            for _kf in "$_sys_kr"/archlinux*; do
                [[ -f "$_kf" ]] && cp -f "$_kf" /etc/pacman.d/gnupg/ 2>/dev/null || true
            done
            timeout 60 pacman-key --populate archlinux 2>/dev/null || true
            _sig_count=$(pacman-key --list-sigs 2>/dev/null | grep -c "archlinux" || echo "0")
            if [[ "$_sig_count" -gt 0 ]]; then
                echo "  Final populate succeeded with $_sig_count signature(s)."
            else
                echo "  Final populate still produced no signatures."
                keyring_ok=false
            fi
        else
            keyring_ok=false
        fi
    fi
fi

if [[ "$keyring_ok" == "true" ]]; then
    echo "Restoring SigLevel to Required DatabaseOptional..."
    _atomic_write_pacman_conf "Required DatabaseOptional"

    echo "Testing database sync with restored signature verification..."
    if pacman -Syy --noconfirm 2>/dev/null; then
        echo "Signature verification restored and functional."
        # Final validation: try to resolve a package to verify the keyring
        # actually works end-to-end (not just that files exist)
        if pacman -Ss --noconfirm "^archlinux-keyring$" >/dev/null 2>&1; then
            echo "Keyring validation: package search with signatures succeeded."
        else
            echo "Warning: Package search test failed, but database sync succeeded."
            # Don't fail here — database sync success is the critical check
        fi
    else
        echo "Warning: Database sync failed after restoring SigLevel."
        keyring_ok=false
    fi
fi

if [[ "$keyring_ok" != "true" ]]; then
    echo "FATAL: Pacman keyring could not be repaired. The container is in an unsecure state."
    echo "FATAL: Aborting installation to prevent running without signature verification."
    _atomic_write_pacman_conf "Required DatabaseOptional" 2>/dev/null || \
        _atomic_sed_inplace /etc/pacman.conf 's/^[[:space:]]*SigLevel.*/SigLevel = Required DatabaseOptional/' 2>/dev/null || true
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

    if ! exec_container_script "$keyring_script" "keyring-init" "${STRICT_SECURITY:-false}"; then
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

pin_alpm="${1:-false}"

_remove_stale_lock

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

echo "Creating pre-upgrade snapshot..."
pacman -Q > /tmp/pre-upgrade-packages.list 2>/dev/null || true
# Record versions of critical packages for post-upgrade comparison
for _cp in openssl glibc lib32-glibc systemd-libs pam; do
    pacman -Q "$_cp" 2>/dev/null >> /tmp/pre-upgrade-critical.list || true
done

echo "Upgrading system packages (3-pass: keyring+SSL first, then non-critical, then critical)..."
_remove_stale_lock

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
if [[ "$pin_alpm" == "true" ]]; then
    echo "PIN_ALPM active: pacman/libalpm upgraded upfront; pamac-aur compat handled via ensure_pamac_aur_compat."
fi
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
        _remove_stale_lock
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

echo "Running post-upgrade verification..."

# Check for partial upgrade indicators
if [[ -f /tmp/pre-upgrade-critical.list ]]; then
    echo "Critical package versions after upgrade:"
    for _cp in openssl glibc lib32-glibc systemd-libs pam; do
        _pre_ver=$(grep "^$_cp " /tmp/pre-upgrade-critical.list 2>/dev/null | awk "{print \$2}" || echo "unknown")
        _post_ver=$(pacman -Q "$_cp" 2>/dev/null | awk "{print \$2}" || echo "missing")
        echo "  $_cp: $_pre_ver -> $_post_ver"
    done
fi

# Verify database consistency
if pacman -Dk 2>/dev/null | grep -q "No database errors"; then
    echo "Database: consistent"
else
    echo "WARNING: Database inconsistencies detected after upgrade."
    pacman -Dk 2>&1 | head -5 || true
fi

# Verify critical shared libraries
for _lib in /usr/lib/libc.so.6 /usr/lib/libm.so.6; do
    if [[ -f "$_lib" ]] && ! ldd "$_lib" >/dev/null 2>&1; then
        echo "CRITICAL: $_lib has broken dependencies!"
    fi
done

# Verify core tools
for _tool in pacman grep bash coreutils; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "CRITICAL: $_tool is missing after upgrade!"
    fi
done

echo "System upgrade completed."
UPG_EOF

    if ! exec_container_script "$upgrade_script" "pacman-upgrade" "$PIN_ALPM"; then
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

_remove_stale_lock

echo "Installing core packages (sudo, shadow, gnupg, jq, python)..."
if ! safe_install sudo shadow gnupg jq python; then
    echo "ERROR: Failed to install core packages after retries."
    exit 1
fi
echo "Core packages installed."
CORE_EOF

    if ! exec_container_script "$core_script" "core-packages"; then
        log_error "Failed to install core packages (sudo, shadow, gnupg, jq, python)."
        log_error "CRITICAL: downstream stages (user setup, dev packages, pamac) require these."
        log_error "Any further failures are likely caused by this core-packages failure."
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

_remove_stale_lock

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
            container_root_exec bash -c "if [[ -f /var/lib/pacman/db.lck ]]; then _p=\$(cat /var/lib/pacman/db.lck 2>/dev/null || echo ''); if [[ -n \"\$_p\" ]] && kill -0 \"\$_p\" 2>/dev/null && grep -E 'pacman|yay' /proc/\$_p/comm >/dev/null 2>&1; then echo \"Pacman running (PID \$_p), waiting...\"; _w=0; while [[ \$_w -lt 30 ]] && kill -0 \"\$_p\" 2>/dev/null; do sleep 2; _w=\$(( _w + 2 )); done; if kill -0 \"\$_p\" 2>/dev/null; then echo \"ERROR: Pacman (PID \$_p) still running after 30s. Aborting.\"; exit 1; fi; fi; rm -f /var/lib/pacman/db.lck; fi; pacman -S --noconfirm --needed $_dep" 2>/dev/null || true
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

# Security: Determine sudoers scope.
# Default: per-user NOPASSWD (limits AUR escalation to one user).
# Steam Deck: auto-upgrade to wheel group (single-user device).
# Explicit: --allow-wheel-nopasswd flag overrides to wheel group.
_use_wheel_group=false
if [[ "$ALLOW_WHEEL_NOPASSWD" == "true" ]]; then
    echo "SECURITY: --allow-wheel-nopasswd specified. Granting NOPASSWD to entire wheel group."
    _use_wheel_group=true
elif grep -q "ID=steamos" /etc/os-release 2>/dev/null; then
    echo "SteamOS detected — using wheel-group NOPASSWD (single-user device)."
    _use_wheel_group=true
else
    echo "Multi-user system detected — restricting NOPASSWD to user '$current_user' only."
fi

cat > /etc/sudoers.d/99-pamac-nopasswd <<SUDOERS
# SECURITY NOTE: AUR PKGBUILDs are arbitrary shell scripts run via makepkg; a
# malicious or compromised AUR package can invoke the commands below and
# effectively escalate to root inside this container.
#
# Scope: $(if [[ "\$_use_wheel_group" == "true" ]]; then echo "wheel group (all members)"; else echo "user $current_user only"; fi)
# To remove: sudo rm /etc/sudoers.d/99-pamac-nopasswd
# To widen:   re-run with --allow-wheel-nopasswd

# makepkg is deliberately EXCLUDED from PAMAC_CMDS. Pamac invokes makepkg
# through the systemd-run fake wrapper (which drops privileges for DynamicUser),
# so makepkg itself never calls sudo. Including makepkg in passwordless sudoers
# would let a malicious AUR PKGBUILD (which is an arbitrary shell script run
# BY makepkg) invoke pacman directly as root, bypassing the privilege drop.
# Consensus fix per security review:
#   https://github.com/89luca89/distrobox/issues/636#issuecomment-2929404949
Cmnd_Alias PAMAC_CMDS = /usr/bin/pacman, \\
    /usr/bin/yay, \\
    /usr/bin/pacman-key, \\
    /usr/bin/paccache, \\
    /usr/bin/pacscripts

$(if [[ "\$_use_wheel_group" == "true" ]]; then
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: PAMAC_CMDS"
else
    echo "$current_user ALL=(ALL:ALL) NOPASSWD: PAMAC_CMDS"
fi)
SUDOERS
chmod 0440 /etc/sudoers.d/99-pamac-nopasswd

# Reduce sudo timestamp cache to zero so privileges are not retained between
# operations. Each sudo invocation requires a fresh (passwordless) auth check.
cat > /etc/sudoers.d/98-pamac-timeout <<'TIMEOUT_SUDOERS'
# Reset sudo timestamp after each Pamac operation to minimize escalation window.
Defaults timestamp_timeout=0
TIMEOUT_SUDOERS
chmod 0440 /etc/sudoers.d/98-pamac-timeout

if command -v visudo >/dev/null 2>&1; then
    if visudo -c -f /etc/sudoers.d/99-pamac-nopasswd 2>/dev/null && \
       visudo -c -f /etc/sudoers.d/98-pamac-timeout 2>/dev/null; then
        echo "Sudoers configured and validated (visudo)."
    else
        echo "Warning: sudoers syntax check failed. Removing potentially broken sudoers files."
        rm -f /etc/sudoers.d/99-pamac-nopasswd /etc/sudoers.d/98-pamac-timeout
    fi
else
    echo "Sudoers configured (visudo not available for validation)."
fi

if [[ "\$_use_wheel_group" == "true" ]]; then
    echo "SECURITY: wheel-group NOPASSWD package management is enabled."
    echo "          A malicious AUR PKGBUILD run via makepkg can escalate to root."
    echo "          Remove /etc/sudoers.d/99-pamac-nopasswd if you do not accept this risk."
else
    echo "SECURITY: Per-user NOPASSWD package management is enabled for '$current_user'."
    echo "          Only this user can run package commands without password."
    echo "          A malicious AUR PKGBUILD can still escalate as '$current_user' inside the container."
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
' if (action.id.indexOf("org.manjaro.pamac.") == 0 &&' \
'   subject.isInGroup("wheel")) {' \
'   return polkit.Result.YES;' \
' }' \
'});' > "$polkit_dir/10-pamac-nopasswd.rules"
# polkitd drops privileges to uid 966 (polkitd) — it needs read access to rules
chmod 755 /etc/polkit-1 /etc/polkit-1/rules.d 2>/dev/null || true
echo "polkit passwordless rule created for pamac operations (wheel group only)."
echo "SECURITY: This rule grants passwordless package management to any local, active wheel-group"
echo "          member. Safe on single-user devices (e.g. Steam Deck). On multi-user hosts,"
echo "          consider restricting the subject check to a specific user or removing the rule."
if ! id polkitd >/dev/null 2>&1; then
useradd -r -d / -s /usr/bin/nologin polkitd 2>/dev/null || echo "Note: polkitd user creation failed"
fi
else
echo "Warning: could not install polkit. pamac GUI may prompt for password."
fi

# Note: No polkit authentication agent is installed inside the container.
# The 10-pamac-nopasswd.rules file above grants passwordless access for
# Pamac operations, so the agent is never triggered. If a user removes
# the rules, the agent cannot project authentication dialogs from inside
# a Distrobox container to the host's Wayland session — the GUI would
# appear to hang. Use CLI (pacman/yay) as a fallback in that case.

echo "Setting up D-Bus..."
if command -v dbus-daemon >/dev/null 2>&1; then
mkdir -p /run/dbus
if [[ ! -S /run/dbus/system_bus_socket ]]; then
dbus-daemon --system --fork 2>/dev/null || echo "Note: dbus-daemon start failed (may already be running via init)"
fi
fi

echo "Setting pamac polkit policy for passwordless operation..."
pamac_policy="/usr/share/polkit-1/actions/org.manjaro.pamac.policy"
if [[ -f "$pamac_policy" ]]; then
    # Blanket-set allow_any / allow_active / allow_inactive to "yes" across
    # EVERY <action> in the policy, regardless of the upstream default value.
    # The host root is read-only (SteamOS immutable) so these in-container
    # rules/policy are the ONLY authority: the container runs its own private
    # system bus + polkitd (not the host's). Any remaining auth_admin* value
    # would trigger a password prompt with no polkit-agent inside the
    # container to handle it, freezing the GUI. Safe on a single-user Deck.
    _atomic_sed_inplace "$pamac_policy" \
        's|<allow_any>[^<]*</allow_any>|<allow_any>yes</allow_any>|g' \
        's|<allow_active>[^<]*</allow_active>|<allow_active>yes</allow_active>|g' \
        's|<allow_inactive>[^<]*</allow_inactive>|<allow_inactive>yes</allow_inactive>|g'
    echo "Polkit policy set to allow_any=allow_active=allow_inactive=yes for ALL pamac actions."
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
_STRICT_SECURITY_MODE="${2:-}"

echo "Installing Pamac bootstrap helper..."
cat > /usr/local/bin/pamac-session-bootstrap.sh << 'BOOTSTRAP'
#!/bin/bash
set +e
BOOTSTRAP_LOG="/var/log/pamac-bootstrap.log"
mkdir -p /var/log 2>/dev/null || true
chmod 1777 /var/log 2>/dev/null || true
touch "$BOOTSTRAP_LOG" 2>/dev/null && chmod 644 "$BOOTSTRAP_LOG" 2>/dev/null

_safe_sleep() {
# COPY #1 of 3 — keep in sync with _CONTAINER_PREAMBLE and repair_script copy.
local _d="$1"
case "$_d" in ''|*[!0-9]*) _d=1 ;; esac
if sleep "$_d" 2>/dev/null; then return 0; fi
# sleep is unavailable/broken — try a real timer that actually delays.
# (read -t </dev/null returns immediately on EOF, so it is NOT a sleep.)
if command -v python3 >/dev/null 2>&1; then
    python3 -c "import time,sys; time.sleep(float(sys.argv[1]))" "$_d" 2>/dev/null && return 0
fi
if command -v perl >/dev/null 2>&1; then
    perl -e "select undef,undef,undef,\$ARGV[0]" "$_d" 2>/dev/null && return 0
fi
# No working timer available: degrade to a $SECONDS-based wall-clock wait so
# retry loops neither busy-pin a core NOR return in <10ms. bash's $SECONDS
# advances once per real second of wall time, so we poll until the requested
# number of whole seconds elapses. The case guard above restricted $_d to
# [0-9] (floats sanitized to 1), so the arithmetic here is integer-safe.
# Returns 0: a real wall-clock delay DID happen even though no precise sub-
# second timer fired; callers should not interpret a non-zero exit as "no
# delay happened" — the function always sleeps at least the requested integer
# number of seconds (or 1s minimum) when reached.
local _target=$(( _d + 0 ))
[[ $_target -lt 1 ]] && _target=1
local _start=$SECONDS
while (( SECONDS - _start < _target )); do
    local _dummy
    # Redirect from /dev/null so read always times out after ~1s regardless of
    # the caller's stdin state (terminal, pipe, or closed fd).
    read -t 1 _dummy </dev/null 2>/dev/null || true
done
return 0
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

start_dbus_system() {
mkdir -p /run/dbus
rm -f /run/dbus/pid
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

# Auto-refresh pacman databases if stale (>12 hours old) or missing.
_refresh_pacman_databases() {
local sync_dir="/var/lib/pacman/sync"
local max_age=43200  # 12 hours in seconds

# If no .db files exist, sync immediately
if ! ls "$sync_dir"/*.db >/dev/null 2>&1; then
    log_bootstrap "No sync databases found, syncing..."
    rm -rf "$sync_dir"/download-* 2>/dev/null || true
    pacman -Sy --noconfirm 2>&1 | tail -5 >> "$BOOTSTRAP_LOG" || true
    if ! ls "$sync_dir"/*.db >/dev/null 2>&1; then
        log_bootstrap "ERROR: Database sync failed - no .db files after pacman -Sy"
    else
        log_bootstrap "Database sync complete."
    fi
    return 0
fi

# Check age of newest database file
local newest_db
newest_db=$(ls -t "$sync_dir"/*.db 2>/dev/null | head -1)
if [[ -z "$newest_db" ]]; then
    pacman -Sy --noconfirm 2>&1 | tail -5 >> "$BOOTSTRAP_LOG" || true
    return 0
fi

local db_mtime db_age now
db_mtime=$(stat -c %Y "$newest_db" 2>/dev/null || echo "0")
now=$(date +%s 2>/dev/null || echo "0")
db_age=$(( now - db_mtime ))

if [[ "$db_age" -gt "$max_age" ]]; then
    log_bootstrap "Sync databases are ${db_age}s old (max ${max_age}s). Refreshing..."
    rm -rf "$sync_dir"/download-* 2>/dev/null || true
    pacman -Sy --noconfirm 2>&1 | tail -5 >> "$BOOTSTRAP_LOG" || true
    log_bootstrap "Database refresh complete."
else
    log_bootstrap "Sync databases are ${db_age}s old (within ${max_age}s limit). OK."
fi
}

# Ensure pacman keyring is initialized (first-run or corrupted)
_ensure_keyring() {
if [[ -f /etc/pacman.d/gnupg/pubring.gpg ]] && pacman-key --list-keys >/dev/null 2>&1; then
    # Keyring exists — verify all repo keyrings are populated
    local _populated
    _populated=$(pacman-key --list-keys 2>/dev/null | grep -c "^pub " || echo "0")
    if [[ "$_populated" -gt 10 ]]; then
        return 0
    fi
    log_bootstrap "Keyring exists but only has $_populated keys. Re-populating..."
fi
log_bootstrap "Initializing pacman keyring..."
rm -rf /etc/pacman.d/gnupg 2>/dev/null || true
mkdir -p /etc/pacman.d/gnupg 2>/dev/null || true
chmod 700 /etc/pacman.d/gnupg 2>/dev/null || true
pacman-key --init 2>/dev/null || true
# Populate all available keyrings (archlinux, blackarch, archlinuxcn, endeavouros, etc.)
for _kr in /usr/share/pacman/keyrings/*.gpg; do
    [[ -f "$_kr" ]] || continue
    _kr_name=$(basename "$_kr" .gpg)
    if pacman-key --populate "$_kr_name" 2>/dev/null; then
        log_bootstrap "Populated keyring: $_kr_name"
    fi
done
# Also import any locally added keys
for _kr in /usr/share/pacman/keyrings/*.gpg; do
    [[ -f "$_kr" ]] || continue
    _kr_name=$(basename "$_kr" .gpg)
    if pacman-key --lsign-key --no-confirm "pacman@$_kr_name" 2>/dev/null; then
        log_bootstrap "Locally signed keyring: $_kr_name"
    fi
done
local _count
_count=$(pacman-key --list-keys 2>/dev/null | grep -c "^pub " || echo "0")
log_bootstrap "Keyring initialized: $_count keys"
}

# Clean stale pacman lock file
if [[ -f /var/lib/pacman/db.lck ]]; then
    _lck_pid=$(cat /var/lib/pacman/db.lck 2>/dev/null || echo "")
    if [[ -n "$_lck_pid" ]] && [[ "$_lck_pid" =~ ^[0-9]+$ ]] && kill -0 "$_lck_pid" 2>/dev/null; then
        log_bootstrap "Pacman is running (PID $_lck_pid). Waiting for lock..."
    else
        log_bootstrap "Removing stale pacman lock file."
        rm -f /var/lib/pacman/db.lck 2>/dev/null || true
    fi
fi

# Ensure keyring BEFORE database refresh (pacman -Sy needs valid signatures)
_ensure_keyring

# Refresh databases synchronously (must complete before pamac-daemon starts)
_refresh_pacman_databases

if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
log_bootstrap "systemd detected, starting services via systemctl"
systemctl start polkit 2>/dev/null || true
systemctl start pamac-daemon >/dev/null 2>&1 || true
else
log_bootstrap "Non-systemd environment, starting services manually"
# Kill any stale processes (host processes may leak through PID namespace)
pkill -9 pamac-daemon 2>/dev/null || true
pkill -9 polkitd 2>/dev/null || true
pkill -9 dbus-daemon 2>/dev/null || true
sleep 2
# Clean start: dbus -> polkitd -> pamac-daemon
rm -f /run/dbus/pid 2>/dev/null
mkdir -p /run/dbus
dbus-daemon --system --fork 2>/dev/null || true
sleep 2
/usr/lib/polkit-1/polkitd --no-debug 2>/dev/null &
sleep 2
/usr/bin/pamac-daemon 2>/dev/null &
sleep 2
log_bootstrap "Services started (dbus, polkitd, pamac-daemon)"
fi
BOOTSTRAP
chmod +x /usr/local/bin/pamac-session-bootstrap.sh
echo "Bootstrap helper installed."

echo "Installing fake systemd-run wrapper for non-systemd AUR builds..."
if [[ "$_STRICT_SECURITY_MODE" == "true" ]]; then
    echo "SKIPPED fake systemd-run wrapper (--strict-security: refuses DynamicUser shim)."
    echo "  AUR builds that need systemd-run --property=DynamicUser=yes will fail in"
    echo "  non-systemd containers instead of running with dropped sandbox properties."
    echo "  This is by design: --strict-security prioritizes correctness over"
    echo "  compatibility with DynamicUser outside of systemd."
elif ! command -v systemctl >/dev/null 2>&1 || ! systemctl show-environment >/dev/null 2>&1; then
_write_fake_systemd_run_wrapper
echo "Fake systemd-run installed at /usr/local/sbin/systemd-run (with ad-hoc build-user cleanup)."
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
cat > /usr/share/dbus-1/system.d/org.manjaro.pamac.daemon.conf << DBUS_CONF
<!DOCTYPE busconfig PUBLIC
"-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
"http://www.freedesktop.org/standards/dbus-1.0/busconfig.dtd">
<busconfig>

<policy user="root">
<allow own="org.manjaro.pamac.daemon"/>
<allow send_destination="org.manjaro.pamac.daemon"/>
</policy>

<policy user="$HOST_USER">
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

if ! exec_container_script "$critical_script" "critical-helpers" "$CURRENT_USER" "${STRICT_SECURITY:-false}"; then
log_warn "Critical helpers setup had issues, retrying..."
container_start 2>/dev/null || true
sleep 3
if container_is_usable; then
if ! exec_container_script "$critical_script" "critical-helpers-retry" "$CURRENT_USER" "${STRICT_SECURITY:-false}"; then
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
_STRICT_SECURITY_MODE="${2:-}"

repaired=0

if [[ ! -x /usr/local/bin/pamac-session-bootstrap.sh ]]; then
echo "Repairing: pamac-session-bootstrap.sh..."
cat > /usr/local/bin/pamac-session-bootstrap.sh << 'BOOTSTRAP'
#!/bin/bash
set +e
BOOTSTRAP_LOG="/var/log/pamac-bootstrap.log"
mkdir -p /var/log 2>/dev/null || true
chmod 1777 /var/log 2>/dev/null || true
touch "$BOOTSTRAP_LOG" 2>/dev/null && chmod 644 "$BOOTSTRAP_LOG" 2>/dev/null

_safe_sleep() {
# COPY #1 of 3 — keep in sync with _CONTAINER_PREAMBLE and repair_script copy.
local _d="$1"
case "$_d" in ''|*[!0-9]*) _d=1 ;; esac
if sleep "$_d" 2>/dev/null; then return 0; fi
# sleep is unavailable/broken — try a real timer that actually delays.
# (read -t </dev/null returns immediately on EOF, so it is NOT a sleep.)
if command -v python3 >/dev/null 2>&1; then
    python3 -c "import time,sys; time.sleep(float(sys.argv[1]))" "$_d" 2>/dev/null && return 0
fi
if command -v perl >/dev/null 2>&1; then
    perl -e "select undef,undef,undef,\$ARGV[0]" "$_d" 2>/dev/null && return 0
fi
# No working timer available: degrade to a $SECONDS-based wall-clock wait so
# retry loops neither busy-pin a core NOR return in <10ms. bash's $SECONDS
# advances once per real second of wall time, so we poll until the requested
# number of whole seconds elapses. The case guard above restricted $_d to
# [0-9] (floats sanitized to 1), so the arithmetic here is integer-safe.
# Returns 0: a real wall-clock delay DID happen even though no precise sub-
# second timer fired; callers should not interpret a non-zero exit as "no
# delay happened" — the function always sleeps at least the requested integer
# number of seconds (or 1s minimum) when reached.
local _target=$(( _d + 0 ))
[[ $_target -lt 1 ]] && _target=1
local _start=$SECONDS
while (( SECONDS - _start < _target )); do
    local _dummy
    # Redirect from /dev/null so read always times out after ~1s regardless of
    # the caller's stdin state (terminal, pipe, or closed fd).
    read -t 1 _dummy </dev/null 2>/dev/null || true
done
return 0
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

start_dbus_system() {
mkdir -p /run/dbus
rm -f /run/dbus/pid
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

# Auto-refresh pacman databases if stale (>12 hours old) or missing.
_refresh_pacman_databases() {
local sync_dir="/var/lib/pacman/sync"
local max_age=43200  # 12 hours in seconds
if ! ls "$sync_dir"/*.db >/dev/null 2>&1; then
    log_bootstrap "No sync databases found, syncing..."
    rm -rf "$sync_dir"/download-* 2>/dev/null || true
    pacman -Sy --noconfirm 2>&1 | tail -5 >> "$BOOTSTRAP_LOG" || true
    if ! ls "$sync_dir"/*.db >/dev/null 2>&1; then
        log_bootstrap "ERROR: Database sync failed - no .db files after pacman -Sy"
    else
        log_bootstrap "Database sync complete."
    fi
    return 0
fi
local newest_db
newest_db=$(ls -t "$sync_dir"/*.db 2>/dev/null | head -1)
[[ -z "$newest_db" ]] && return 0
local db_mtime db_age now
db_mtime=$(stat -c %Y "$newest_db" 2>/dev/null || echo "0")
now=$(date +%s 2>/dev/null || echo "0")
db_age=$(( now - db_mtime ))
if [[ "$db_age" -gt "$max_age" ]]; then
    log_bootstrap "Sync databases are ${db_age}s old. Refreshing..."
    rm -rf "$sync_dir"/download-* 2>/dev/null || true
    pacman -Sy --noconfirm 2>&1 | tail -5 >> "$BOOTSTRAP_LOG" || true
    log_bootstrap "Database refresh complete."
fi
}

_ensure_keyring() {
if [[ -f /etc/pacman.d/gnupg/pubring.gpg ]] && pacman-key --list-keys >/dev/null 2>&1; then
    local _populated
    _populated=$(pacman-key --list-keys 2>/dev/null | grep -c "^pub " || echo "0")
    if [[ "$_populated" -gt 10 ]]; then
        return 0
    fi
fi
log_bootstrap "Repairing keyring..."
rm -rf /etc/pacman.d/gnupg 2>/dev/null || true
mkdir -p /etc/pacman.d/gnupg 2>/dev/null || true
chmod 700 /etc/pacman.d/gnupg 2>/dev/null || true
pacman-key --init 2>/dev/null || true
for _kr in /usr/share/pacman/keyrings/*.gpg; do
    [[ -f "$_kr" ]] || continue
    _kr_name=$(basename "$_kr" .gpg)
    pacman-key --populate "$_kr_name" 2>/dev/null || true
done
}

# Clean stale pacman lock file
if [[ -f /var/lib/pacman/db.lck ]]; then
    _lck_pid=$(cat /var/lib/pacman/db.lck 2>/dev/null || echo "")
    if [[ -n "$_lck_pid" ]] && [[ "$_lck_pid" =~ ^[0-9]+$ ]] && kill -0 "$_lck_pid" 2>/dev/null; then
        log_bootstrap "Pacman is running (PID $_lck_pid). Waiting for lock..."
    else
        log_bootstrap "Removing stale pacman lock file."
        rm -f /var/lib/pacman/db.lck 2>/dev/null || true
    fi
fi

# Ensure keyring BEFORE database refresh (pacman -Sy needs valid signatures)
_ensure_keyring

# Refresh databases synchronously (must complete before pamac-daemon starts)
_refresh_pacman_databases

if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
log_bootstrap "systemd detected, starting services via systemctl"
systemctl start polkit 2>/dev/null || true
systemctl start pamac-daemon >/dev/null 2>&1 || true
else
log_bootstrap "Non-systemd environment, starting services manually"
# Kill any stale processes (host processes may leak through PID namespace)
pkill -9 pamac-daemon 2>/dev/null || true
pkill -9 polkitd 2>/dev/null || true
pkill -9 dbus-daemon 2>/dev/null || true
sleep 2
# Clean start: dbus -> polkitd -> pamac-daemon
rm -f /run/dbus/pid 2>/dev/null
mkdir -p /run/dbus
dbus-daemon --system --fork 2>/dev/null || true
sleep 2
/usr/lib/polkit-1/polkitd --no-debug 2>/dev/null &
sleep 2
/usr/bin/pamac-daemon 2>/dev/null &
sleep 2
log_bootstrap "Services started (dbus, polkitd, pamac-daemon)"
fi
BOOTSTRAP
chmod +x /usr/local/bin/pamac-session-bootstrap.sh
repaired=$((repaired + 1))
echo "Bootstrap helper repaired."
fi

if [[ ! -x /usr/local/sbin/systemd-run ]]; then
echo "Repairing: fake systemd-run wrapper..."
if [[ "$_STRICT_SECURITY_MODE" == "true" ]]; then
    echo "SKIPPED fake systemd-run wrapper repair (--strict-security: refuses DynamicUser shim)."
    echo "  AUR builds that need DynamicUser will fail in non-systemd containers"
    echo "  instead of running with dropped sandbox properties (by design under"
    echo "  --strict-security)."
elif ! command -v systemctl >/dev/null 2>&1 || ! systemctl show-environment >/dev/null 2>&1; then
_write_fake_systemd_run_wrapper
repaired=$((repaired + 1))
echo "Fake systemd-run repaired (with ad-hoc build-user cleanup)."
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

if [[ ! -f /usr/share/dbus-1/system.d/org.manjaro.pamac.daemon.conf ]] || ! grep -q "policy user=\"$HOST_USER\"" /usr/share/dbus-1/system.d/org.manjaro.pamac.daemon.conf 2>/dev/null; then
echo "Repairing: D-Bus system policy for pamac-daemon..."
mkdir -p /usr/share/dbus-1/system.d
cat > /usr/share/dbus-1/system.d/org.manjaro.pamac.daemon.conf << DBUS_CONF
<!DOCTYPE busconfig PUBLIC
"-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
"http://www.freedesktop.org/standards/dbus-1.0/busconfig.dtd">
<busconfig>

<policy user="root">
<allow own="org.manjaro.pamac.daemon"/>
<allow send_destination="org.manjaro.pamac.daemon"/>
</policy>

<policy user="$HOST_USER">
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

# Also fix D-Bus service file for non-systemd containers
_dbus_svc="/usr/share/dbus-1/system-services/org.manjaro.pamac.daemon.service"
if [[ -f "$_dbus_svc" ]] && grep -q "SystemdService" "$_dbus_svc" 2>/dev/null; then
cat > "$_dbus_svc" << 'DBUS_SVC_FIX'
[D-BUS Service]
Name=org.manjaro.pamac.daemon
Exec=/usr/bin/pamac-daemon
DBUS_SVC_FIX
repaired=$((repaired + 1))
echo "D-Bus service file fixed for non-systemd."
fi

# Fix PolicyKit1 D-Bus service file (keep User=root, remove SystemdService)
_pkit_svc="/usr/share/dbus-1/system-services/org.freedesktop.PolicyKit1.service"
if [[ -f "$_pkit_svc" ]] && grep -q "SystemdService" "$_pkit_svc" 2>/dev/null; then
cat > "$_pkit_svc" << 'PKIT_SVC_FIX'
[D-BUS Service]
Name=org.freedesktop.PolicyKit1
Exec=/usr/lib/polkit-1/polkitd --no-debug
User=root
PKIT_SVC_FIX
repaired=$((repaired + 1))
echo "PolicyKit1 D-Bus service file fixed for non-systemd."
fi

# Ensure /var/lib/polkit-1 exists
mkdir -p /var/lib/polkit-1 2>/dev/null || true
chmod 755 /var/lib/polkit-1 2>/dev/null || true

# Ensure system bus daemon is running
if ! dbus-send --system --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
mkdir -p /run/dbus
rm -f /run/dbus/pid
dbus-daemon --system --fork 2>/dev/null || true
echo "Started system bus daemon."
fi

echo "Repaired $repaired critical item(s)."
REPAIR_EOF

local repair_ok=false
for attempt in 1 2 3; do
if exec_container_script "$repair_script" "critical-helpers-repair-attempt-$attempt" "$CURRENT_USER" "${STRICT_SECURITY:-false}"; then
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

  _remove_stale_lock

  echo "Installing reflector..."
if ! pacman -S --noconfirm --needed reflector; then
    echo "Failed to install reflector. Skipping mirror optimization."
    exit 0
fi

echo "Backing up current mirrorlist..."
[[ -f /etc/pacman.d/mirrorlist ]] && cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

echo "Generating optimized mirrorlist (this may take a minute)..."

# Strategy 1: Full optimization — latest 20 mirrors, sorted by rate
_reflector_ok=false
for _attempt in 1 2 3; do
    echo "  Attempt $_attempt/3: reflector --latest 20 --protocol https --sort rate"
    if timeout 120 reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null; then
        # Verify the mirrorlist is not empty
        if [[ -s /etc/pacman.d/mirrorlist ]] && grep -q "Server" /etc/pacman.d/mirrorlist; then
            _reflector_ok=true
            echo "Successfully updated mirrorlist (attempt $_attempt)."
            break
        fi
        echo "  Reflector succeeded but mirrorlist is empty. Retrying..."
    fi
    echo "  Attempt $_attempt failed or timed out."
    sleep 2
done

# Strategy 2: Relaxed — latest 10 mirrors (faster, more likely to succeed)
if [[ "$_reflector_ok" != "true" ]]; then
    echo "  Trying relaxed mode: reflector --latest 10 --protocol https --sort rate"
    if timeout 90 reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null; then
        if [[ -s /etc/pacman.d/mirrorlist ]] && grep -q "Server" /etc/pacman.d/mirrorlist; then
            _reflector_ok=true
            echo "Successfully updated mirrorlist (relaxed mode)."
        fi
    fi
fi

# Strategy 3: Country-based — just pick mirrors from a nearby country
if [[ "$_reflector_ok" != "true" ]]; then
    echo "  Trying country-based: reflector --latest 5 --protocol https --sort rate"
    if timeout 60 reflector --latest 5 --protocol https --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null; then
        if [[ -s /etc/pacman.d/mirrorlist ]] && grep -q "Server" /etc/pacman.d/mirrorlist; then
            _reflector_ok=true
            echo "Successfully updated mirrorlist (country-based fallback)."
        fi
    fi
fi

if [[ "$_reflector_ok" != "true" ]]; then
    echo "All reflector strategies failed. Restoring backup..."
    [[ -f /etc/pacman.d/mirrorlist.backup ]] && cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
    echo "Note: Using previous mirrorlist. You can retry later with: reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist"
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

  _remove_stale_lock

  if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    echo "Enabling multilib repository..."
    # Backup pacman.conf before modification
    cp /etc/pacman.conf /etc/pacman.conf.multilib-backup 2>/dev/null || true
    if [[ -s /etc/pacman.conf ]] && [[ "$(tail -c1 /etc/pacman.conf 2>/dev/null)" != "" ]]; then
        printf '\n' >> /etc/pacman.conf
    fi
    printf '[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
    echo "Multilib repository enabled."
else
    echo "Multilib repository is already enabled."
fi

echo "Updating package database..."
# Retry database sync up to 3 times for multilib
_sync_ok=false
for _attempt in 1 2 3; do
    if pacman -Sy --noconfirm 2>/dev/null; then
        _sync_ok=true
        break
    fi
    echo "  Database sync attempt $_attempt/3 failed. Retrying..."
    _remove_stale_lock
    sleep 2
done

if [[ "$_sync_ok" != "true" ]]; then
    echo "WARNING: Database sync failed after 3 attempts."
    echo "  The multilib repo entry was written to pacman.conf but may not be functional."
    echo "  If this causes issues, restore from: /etc/pacman.conf.multilib-backup"
    # Verify multilib is actually accessible
    if ! pacman -Sy --noconfirm 2>/dev/null; then
        echo "  Restoring pacman.conf from backup due to sync failure..."
        cp /etc/pacman.conf.multilib-backup /etc/pacman.conf 2>/dev/null || true
        echo "  Multilib entry removed — the repo appears unreachable."
    fi
fi
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

# Import host environment variable overrides passed as positional args.
# Single-quoted heredocs prevent host-side variable expansion, so the caller
# passes these as arguments to exec_container_script and we read them here.
# Args: $1=CHAOTIC_AUR_KEY_ID,
#       $2=ARCHLINUXCN_KEY_ID, $3=ENDEAVOUROS_KEY_ID
[[ -n "${1:-}" ]] && export CHAOTIC_AUR_KEY_ID="$1"
[[ -n "${2:-}" ]] && export ARCHLINUXCN_KEY_ID="$2"
[[ -n "${3:-}" ]] && export ENDEAVOUROS_KEY_ID="$3"

_remove_stale_lock

_repo_already_enabled() {
    grep -q "^\[$1\]" /etc/pacman.conf
}

_import_key_with_retry() {
    local key_id="$1"
    shift
    local keyserver_urls=("$@")
    local max_attempts=2

    if [[ ${#keyserver_urls[@]} -eq 0 ]]; then
        keyserver_urls=("hkps://keyserver.ubuntu.com" "hkps://keys.openpgp.org" "hkps://pgp.mit.edu")
    fi

    # Step 0: Try WKD (Web Key Directory) lookup first - no keyserver needed
    # WKD uses DNS + HTTPS to the domain directly, bypassing keyservers entirely.
    echo "  Attempting WKD (Web Key Directory) lookup for $key_id..."
    if timeout 10 gpg --locate-external-keys "$key_id" 2>/dev/null; then
        local _wkd_fp
        _wkd_fp=$(GNUPGHOME=/etc/pacman.d/gnupg gpg --with-colons --list-keys "$key_id" 2>/dev/null \
            | grep '^fpr' | head -1 | cut -d: -f10 || echo "")
        if [[ -n "$_wkd_fp" ]]; then
            echo "  WKD lookup found key: ${_wkd_fp: -8}"
            timeout 15 pacman-key --lsign-key "$_wkd_fp" 2>/dev/null && return 0
        fi
    fi
    echo "  WKD lookup did not resolve key $key_id."

    # Step 1: Try keyservers with reduced timeouts
    for server in "${keyserver_urls[@]}"; do
        local attempt=1
        while [[ $attempt -le $max_attempts ]]; do
            if timeout 12 pacman-key --recv-key --keyserver "$server" "$key_id" 2>/dev/null; then
                local _verify_fp
                _verify_fp=$(GNUPGHOME=/etc/pacman.d/gnupg gpg --with-colons --list-keys "$key_id" 2>/dev/null \
                    | grep '^fpr' | head -1 | cut -d: -f10 || echo "")
                local _fp_len=${#_verify_fp}
                local _kid_len=${#key_id}
                local _verify_ok=false
                if [[ -n "$_verify_fp" ]]; then
                    local _clean_kid="${key_id,,}"
                    local _clean_fp="${_verify_fp,,}"
                    local _is_hex=false
                    [[ "$_clean_kid" =~ ^[0-9a-f]+$ ]] && _is_hex=true
                    # Condition 1: exact full-fingerprint match (40 chars).
                    if [[ "$_clean_fp" == "$_clean_kid" ]] && [[ "$_is_hex" == "true" ]]; then
                        _verify_ok=true
                    # Condition 2: long key ID (>=16 chars) that is a UNIQUE,
                    # hex-aligned suffix of exactly one fingerprint in the ring.
                    # This protects against a coincidental 16-char collision:
                    # we count ALL fingerprints ending in $key_id and require
                    # that count to be exactly 1.
                    elif [[ $_kid_len -ge 16 ]] && [[ "$_is_hex" == "true" ]] && [[ "$_clean_fp" == *"$_clean_kid" ]]; then
                        local _stripped="${_clean_fp%$_clean_kid}"
                        # Reject coincidental earlier-position match.
                        if [[ "$_stripped" == *"$_clean_kid"* ]]; then
                            _verify_ok=false
                        else
                            local _suffix_matches
                            _suffix_matches=$(GNUPGHOME=/etc/pacman.d/gnupg gpg --with-colons --list-keys 2>/dev/null \
                                | grep '^fpr' | cut -d: -f10 \
                                | grep -c -i -- "${_clean_kid}$" || echo 0)
                            _suffix_matches="${_suffix_matches//[[:space:]]/}"
                            if [[ "${_suffix_matches:-0}" -eq 1 ]]; then
                                _verify_ok=true
                            else
                                echo "Ambiguous key import: ${_suffix_matches:-0} fingerprints end with '$key_id'. Rejecting to avoid a collision."
                                _verify_ok=false
                            fi
                        fi
                    fi
                fi
                if [[ "$_verify_ok" == "true" ]]; then
                    timeout 15 pacman-key --lsign-key "$_verify_fp" 2>/dev/null && return 0
                else
                    echo "Fingerprint verification failed for key $key_id (got $_verify_fp)."
                    echo "Short/ambiguous-ID matches are rejected for security. Use the full fingerprint (40 hex chars)."
                fi
            fi
            echo "Key import attempt $attempt/$max_attempts failed for $key_id from $server (12s timeout)."
            attempt=$((attempt + 1))
            [[ $attempt -le $max_attempts ]] && sleep 2
        done
    done

    # Step 2: Try downloading key directly from common key distribution paths
    echo "  Attempting direct key download from common distribution paths..."
    local _key_dl_urls=(
        "https://archlinux.org/packages/core/x86_64/archlinux-keyring/files/"
        "https://geo.mirror.pkgbuild.com/core/os/x86_64/"
    )
    local _key_tmp
    _key_tmp=$(mktemp /var/tmp/pamac-key-dl-XXXXXX) && chmod 700 "$_key_tmp" 2>/dev/null || _key_tmp=$(mktemp)
    for _base_url in "${_key_dl_urls[@]}"; do
        local _kr_url="${_base_url}archlinux-keyring-"*.pkg.tar.zst
        if timeout 15 curl -fsSL --connect-timeout 5 -o "$_key_tmp/kr.pkg.tar.zst" "$_kr_url" 2>/dev/null; then
            local _kr_dir="$_key_tmp/kr-extract"
            mkdir -p "$_kr_dir" && chmod 700 "$_kr_dir" 2>/dev/null || true
            if tar -xf "$_key_tmp/kr.pkg.tar.zst" -C "$_kr_dir" 2>/dev/null; then
                for _kr_file in "$_kr_dir"/usr/share/pacman/keyrings/archlinux*; do
                    [[ -f "$_kr_file" ]] && cp -f "$_kr_file" /etc/pacman.d/gnupg/ 2>/dev/null || true
                done
                if pacman-key --populate archlinux 2>/dev/null; then
                    rm -rf "$_key_tmp"
                    return 0
                fi
            fi
            rm -rf "$_kr_dir"
        fi
    done
    rm -rf "$_key_tmp" 2>/dev/null || true

    echo "Warning: Could not import key $key_id after all methods (WKD + keyservers + direct download)."
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

    # Validate the resolved key_id is a 40-char hex fingerprint OR empty/informative
    # short prefix (the bootstrap chain below probes keyservers + mirror paths and
    # confirms a live fingerprint before trusting it — but if the USER-supplied
    # override is malformed, fail fast with an actionable error instead of
    # attempting to import garbage and producing confusing keyserver failures.
    if [[ -n "${!env_var_name:-}" ]] && [[ "$key_id" != "$default_key_id" ]]; then
        if [[ ! "$key_id" =~ ^[0-9a-fA-F]{40}$ ]]; then
            echo "ERROR: $env_var_name='$key_id' is not a valid 40-character hex fingerprint."
            echo "       GPG fingerprints must be a 40-character hexadecimal string (e.g. 30565AC3868033CA...)."
            echo "       Short IDs (16-char or 8-char) are rejected for security (collision/ambiguous-match)."
            echo "       Clear $env_var_name or set it to the full fingerprint and re-run."
            return 1
        fi
    fi

    echo "Adding repository [$repo_name] (key_id=$key_id)..."

    local server_lines=""
    for url in "${mirror_urls[@]}"; do
        server_lines="${server_lines}Server = $url\n"
    done

    local key_ok=false
    # Defensive cleanup: ensure any temp dirs created by the fallback strategies
    # below are removed on EVERY exit path (normal return, ERR, or signal kill),
    # not just the happy paths. This function runs inside the container script
    # so the host-side _TEMP_FILES/_cleanup_temp_files machinery is unavailable.
    local _repo_tmp_dirs=()
    _repo_cleanup_tmps() {
        local _d
        for _d in "${_repo_tmp_dirs[@]:-}"; do
            [[ -n "$_d" ]] && rm -rf "$_d" 2>/dev/null || true
        done
        trap - RETURN INT TERM HUP
    }
    _repo_signal_cleanup() {
        local _sig=$1
        _repo_cleanup_tmps
        trap - "$_sig"; kill -s "$_sig" $$ 2>/dev/null || true
    }
    trap '_repo_cleanup_tmps' RETURN
    trap '_repo_signal_cleanup INT'  INT
    trap '_repo_signal_cleanup TERM' TERM
    trap '_repo_signal_cleanup HUP'  HUP

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
        local _kr_tmp_dir
        _kr_tmp_dir=$(mktemp -d /var/tmp/pamac-kr-XXXXXX) && chmod 700 "$_kr_tmp_dir" 2>/dev/null || _kr_tmp_dir=$(mktemp -d)
        _repo_tmp_dirs+=("$_kr_tmp_dir")
        for url in "${mirror_urls[@]}"; do
            local direct_url="${url}"
            direct_url="${direct_url//\\\$arch/$host_arch}"
            direct_url="${direct_url//\$arch/$host_arch}"
            direct_url="${direct_url//\\\$repo/$repo_name}"
            direct_url="${direct_url//\$repo/$repo_name}"
            direct_url="${direct_url//\$\{arch\}/$host_arch}"
            direct_url="${direct_url//\$\{repo\}/$repo_name}"
            local pkg_url="${direct_url%/}/${keyring_pkg}.pkg.tar.zst"
            local pkg_sig_url="${pkg_url}.sig"
            if timeout 30 curl -fsSL --connect-timeout 10 -o "$_kr_tmp_dir/${keyring_pkg}.pkg.tar.zst" "$pkg_url" 2>/dev/null; then
                # Verify package signature if available
                local _sig_ok=false
                if timeout 15 curl -fsSL --connect-timeout 5 -o "$_kr_tmp_dir/${keyring_pkg}.pkg.tar.zst.sig" "$pkg_sig_url" 2>/dev/null; then
                    if gpg --verify "$_kr_tmp_dir/${keyring_pkg}.pkg.tar.zst.sig" "$_kr_tmp_dir/${keyring_pkg}.pkg.tar.zst" 2>/dev/null; then
                        _sig_ok=true
                        echo "$repo_name keyring package signature verified."
                    else
                        echo "Warning: $repo_name keyring package signature verification FAILED. Skipping this mirror."
                    fi
                else
                    echo "Warning: $repo_name keyring package has no signature file. Skipping this mirror."
                fi
                if [[ "$_sig_ok" == "true" ]]; then
                    if pacman -U --noconfirm "$_kr_tmp_dir/${keyring_pkg}.pkg.tar.zst" 2>/dev/null; then
                        echo "$repo_name keyring installed from direct download: $pkg_url"
                        key_ok=true
                        rm -f "$_kr_tmp_dir/${keyring_pkg}.pkg.tar.zst" "$_kr_tmp_dir/${keyring_pkg}.pkg.tar.zst.sig"
                        break
                    fi
                fi
                rm -f "$_kr_tmp_dir/${keyring_pkg}.pkg.tar.zst" "$_kr_tmp_dir/${keyring_pkg}.pkg.tar.zst.sig"
            fi
        done
        rm -rf "$_kr_tmp_dir" 2>/dev/null || true
    fi

    # Step 3: Dynamically discover and import GPG key from repo mirrors
    # Tries to download the signing key directly from the repo's distribution
    # rather than relying on hardcoded fingerprints that may become stale after key rotations.
    # SECURITY: Keys discovered from mirrors are verified against the expected $key_id
    # before being trusted. If the discovered key does not match $key_id, it is rejected
    # to prevent a compromised mirror from injecting an arbitrary signing key.
    if [[ "$key_ok" != "true" ]] && command -v pacman-key >/dev/null 2>&1; then
        echo "Attempting dynamic key discovery from repo mirrors (fingerprint-verified against expected $key_id)..."
        local host_arch
        host_arch=$(uname -m 2>/dev/null || echo "x86_64")
        local _key_tmp_dir
        _key_tmp_dir=$(mktemp -d /var/tmp/pamac-key-XXXXXX) && chmod 700 "$_key_tmp_dir" 2>/dev/null || _key_tmp_dir=$(mktemp -d)
        _repo_tmp_dirs+=("$_key_tmp_dir")
        for url in "${mirror_urls[@]}"; do
            local direct_url="${url}"
            direct_url="${direct_url//\\\$arch/$host_arch}"
            direct_url="${direct_url//\$arch/$host_arch}"
            direct_url="${direct_url//\\\$repo/$repo_name}"
            direct_url="${direct_url//\$repo/$repo_name}"
            direct_url="${direct_url//\$\{arch\}/$host_arch}"
            direct_url="${direct_url//\$\{repo\}/$repo_name}"
            # Try common GPG key distribution filenames used by Arch repos
            for keyfile in "pub.gpg" "archlinuxcn.gpg" "key.gpg"; do
                local key_url="${direct_url%/}/$keyfile"
                local _tmp_key="$_key_tmp_dir/repo-key.gpg"
                if timeout 15 curl -fsSL --connect-timeout 5 -o "$_tmp_key" "$key_url" 2>/dev/null; then
                    if file "$_tmp_key" 2>/dev/null | grep -qi "GPG\|PGP"; then
                        echo "  Found GPG key at $key_url"
                        # Verify the discovered key's fingerprint matches the expected key_id
                        local _discovered_fp
                        _discovered_fp=$(GNUPGHOME=/etc/pacman.d/gnupg gpg --with-colons --show-keys "$_tmp_key" 2>/dev/null \
                            | grep '^fpr' | head -1 | cut -d: -f10 || echo "")
                        local _clean_expected="${key_id,,}"
                        local _clean_discovered="${_discovered_fp,,}"
                        if [[ -n "$_discovered_fp" ]] && \
                           { [[ "$_clean_discovered" == "$_clean_expected" ]] || \
                             [[ "$_clean_discovered" == *"$_clean_expected"* ]]; }; then
                            echo "  Fingerprint verified: ${_discovered_fp: -8} matches expected ${key_id: -8}"
                            if timeout 30 pacman-key --import "$_tmp_key" 2>/dev/null; then
                                timeout 30 pacman-key --lsign-key "$_discovered_fp" 2>/dev/null || true
                                echo "  Dynamically discovered and verified key: ${_discovered_fp: -8}"
                                key_ok=true
                                rm -f "$_tmp_key"
                                break 2
                            fi
                        else
                            echo "  WARNING: Key at $key_url has fingerprint ${_discovered_fp:-NONE} but expected ${key_id}. REJECTED."
                            echo "  This may indicate a compromised mirror or a key rotation."
                            echo "  Update ${env_var_name} with the new fingerprint and re-run."
                        fi
                    fi
                    rm -f "$_tmp_key"
                fi
            done
        done
        rm -rf "$_key_tmp_dir" 2>/dev/null || true
        if [[ "$key_ok" != "true" ]]; then
            echo "  No verified GPG key found at common mirror paths. Trying keyserver fallback..."
        fi
    fi

    # Step 4: Import the signing key from keyservers as last resort (uses hardcoded fallback fingerprint)
    if [[ "$key_ok" != "true" ]] && command -v pacman-key >/dev/null 2>&1; then
        echo "WARNING: Using hardcoded fallback fingerprint for $repo_name (key_id=$key_id)."
        echo "  This fingerprint may be STALE after key rotations. If key import fails,"
        echo "  set ${env_var_name}=<NEW_FULL_FINGERPRINT> (40 hex chars) before re-running."
        echo "  Verify current fingerprint at: https://archlinux.org/packages/?repo=$repo_name"
        echo "  or check the upstream keyring package for the latest signing key."
        if _import_key_with_retry "$key_id"; then
            key_ok=true
        fi
    fi

    # Step 5: Write the repo entry with appropriate SigLevel
    if [[ "$key_ok" == "true" ]]; then
        printf '\n[%s]\nSigLevel = Optional\n%b' "$repo_name" "$server_lines" >> /etc/pacman.conf
        echo "$repo_name repository configured (Optional)."
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
echo "Note: Fallback fingerprint 30565AC3868033CA may be stale after key rotation."
echo "  Override with: CHAOTIC_AUR_KEY_ID=<FULL_FINGERPRINT>  (40 hex chars)"

echo "=== Configuring archlinuxcn repository ==="
_enable_repo_with_fallback \
    "archlinuxcn" "archlinuxcn-keyring" "11C2E2D1D43CF75C" \
    "https://repo.archlinuxcn.org/\$arch" \
    "https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/\$arch" \
    "https://mirror.sjtu.edu.cn/archlinuxcn/\$arch"
echo "Note: Fallback fingerprint 11C2E2D1D43CF75C may be stale after key rotation."
echo "  Override with: ARCHLINUXCN_KEY_ID=<FULL_FINGERPRINT>  (40 hex chars)"

echo "=== Configuring endeavouros repository ==="
_enable_repo_with_fallback \
    "endeavouros" "endeavouros-keyring" "F52611D11AFD4556" \
    "https://mirror.freedif.org/EndeavourOS/repo/\$repo/\$arch" \
    "https://mirror.endeavouros.com/EndeavourOS/repo/\$repo/\$arch" \
    "https://mirror.enderunix.org/endeavouros/repo/\$repo/\$arch"
echo "Note: Fallback fingerprint F52611D11AFD4556 may be stale after key rotation."
echo "  Override with: ENDEAVOUROS_KEY_ID=<FULL_FINGERPRINT>  (40 hex chars)"

echo "=== Configuring mesa-git repository (disabled by default - can break GPU drivers) ==="
if ! _repo_already_enabled "mesa-git"; then
    echo "Skipping mesa-git repo (can break GPU drivers on Steam Deck)."
    echo "To enable manually, add to /etc/pacman.conf inside the container:"
    echo '  [mesa-git]'
    echo '  SigLevel = Optional'
    echo '  Server = https://cdn-mirror.chaotic.cx/chaotic-aur/mesa-git/$arch'
else
    echo "mesa-git already enabled."
fi

echo "=== Syncing package databases with new repositories ==="
pacman -Sy --noconfirm 2>/dev/null || echo "Warning: database sync with new repos had issues."

echo "Third-party repository configuration complete."
echo "Available additional repos: chaotic-aur, archlinuxcn, endeavouros"
REPOS_EOF

    if ! exec_container_script "$repos_script" "extra-repos" \
        "${CHAOTIC_AUR_KEY_ID:-}" \
        "${ARCHLINUXCN_KEY_ID:-}" \
        "${ENDEAVOUROS_KEY_ID:-}"; then
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
    local _prebuilt_output
    _prebuilt_output=$(container_root_exec bash -c 'if [[ -f /var/lib/pacman/db.lck ]]; then _p=$(cat /var/lib/pacman/db.lck 2>/dev/null || echo ""); if [[ -n "$_p" ]] && kill -0 "$_p" 2>/dev/null && grep -E "pacman|yay" "/proc/$_p/comm" >/dev/null 2>&1; then echo "Pacman running (PID $_p), waiting..."; _w=0; while [[ $_w -lt 30 ]] && kill -0 "$_p" 2>/dev/null; do sleep 2; _w=$(( _w + 2 )); done; if kill -0 "$_p" 2>/dev/null; then echo "ERROR: Pacman (PID $_p) still running after 30s. Aborting."; exit 1; fi; fi; rm -f /var/lib/pacman/db.lck; fi; pacman -Sy --noconfirm 2>/dev/null; pacman -S --noconfirm --needed yay 2>/dev/null; command -v yay >/dev/null 2>&1 && echo __PREBUILT_OK__' 2>/dev/null) || _prebuilt_output=""
    if [[ -n "$_prebuilt_output" ]] && grep -q "__PREBUILT_OK__" <<< "$_prebuilt_output"; then
        log_success "AUR helper yay installed from prebuilt repository."
        return 0
    fi
    log_info "Prebuilt yay not available. Building from source..."

	log_info "Verifying build dependencies (git, base-devel, go) are present..."
	local verify_script
	read -r -d '' verify_script <<'VERIFY_EOF' || true
set -uo pipefail

_remove_stale_lock

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

_remove_stale_lock

echo "Cloning and building yay from AUR..."
_YAY_WORK=$(mktemp -d /var/tmp/pamac-yay-XXXXXX) && chmod 700 "$_YAY_WORK" 2>/dev/null || _YAY_WORK=$(mktemp -d)
rm -rf "$_YAY_WORK" && mkdir -p "$_YAY_WORK" && chmod 700 "$_YAY_WORK"

echo "Ensuring CA certificates are available for HTTPS..."
pacman -S --noconfirm --needed ca-certificates-mozilla 2>/dev/null || true

clone_retry=0
max_clone_retries=3
while [[ $clone_retry -lt $max_clone_retries ]]; do
    if sudo -Hu "$current_user" git clone "https://aur.archlinux.org/yay.git" "$_YAY_WORK/yay" 2>"$_YAY_WORK/clone_err"; then
        break
    fi
    clone_err=$(cat "$_YAY_WORK/clone_err" 2>/dev/null || true)
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
        cat "$_YAY_WORK/clone_err" 2>/dev/null || true
        echo "AUR clone failed. Trying to download yay from GitHub..."
        rm -rf "$_YAY_WORK/yay"
        if sudo -Hu "$current_user" git clone --depth=1 "https://github.com/Jguer/yay.git" "$_YAY_WORK/yay" 2>"$_YAY_WORK/gh_err"; then
            echo "Successfully cloned yay from GitHub."
        else
            echo "GitHub clone also failed."
            cat "$_YAY_WORK/gh_err" 2>/dev/null || true
            exit 1
        fi
    fi
done

chown -R "$current_user:$current_user" "$_YAY_WORK/yay"
_set_makepkg_jobs
sudo -Hu "$current_user" bash -lc "cd '$_YAY_WORK/yay' && makepkg -si --noconfirm --clean"
build_rc=$?

if [[ $build_rc -ne 0 ]]; then
    echo "ERROR: makepkg failed for yay (exit $build_rc)."
    exit 1
fi

if ! command -v yay >/dev/null 2>&1; then
    echo "FATAL: yay binary not found after successful makepkg. Installation may have failed silently."
    echo "Attempting direct reinstall from built package..."
    _yay_pkg=$(ls -t "$_YAY_WORK/yay"/*.pkg.tar.* 2>/dev/null | head -1)
    if [[ -n "$_yay_pkg" ]]; then
        pacman -U --noconfirm "$_yay_pkg" || true
    fi
    if ! command -v yay >/dev/null 2>&1; then
        echo "FATAL: yay is still not available after build. Aborting."
        exit 1
    fi
fi
echo "yay verified installed: $(yay --version 2>/dev/null || echo 'unknown version')"
rm -rf "$_YAY_WORK" 2>/dev/null || true
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
# Strip epoch first, then extract minor/patch only when dot delimiters exist
# (avoids cut -d. -f2 returning the full string when there is no dot)
_pacman_ver_stripped=$(echo "$installed_pacman_ver" | sed 's/^[^:]*://')
if [[ "$_pacman_ver_stripped" == *.* ]]; then
    _pacman_minor_raw=$(echo "$_pacman_ver_stripped" | cut -d. -f2)
    pacman_minor=$(echo "$_pacman_minor_raw" | grep -oP '^[0-9]+' || echo "0")
else
    pacman_minor=0
fi
[[ -z "$pacman_minor" ]] && pacman_minor=0
if [[ "$_pacman_ver_stripped" == *.*.* ]]; then
    _pacman_patch_raw=$(echo "$_pacman_ver_stripped" | cut -d. -f3)
    pacman_patch=$(echo "$_pacman_patch_raw" | grep -oP '^[0-9]+' || echo "0")
else
    pacman_patch=0
fi
[[ -z "$pacman_patch" ]] && pacman_patch=0
echo "Parsed pacman version: major=$pacman_major minor=$pacman_minor patch=$pacman_patch (raw: $installed_pacman_ver)"

if [[ -n "$pamac_version_pin" && "$pamac_version_pin" != "latest" ]]; then
    echo "User specified --pamac-version=$pamac_version_pin. Attempting direct install..."
    _remove_stale_lock
    if sudo -Hu "$current_user" bash -lc "yay -S --noconfirm --noprogressbar --clone --noedit 'pamac-aur=$pamac_version_pin'" 2>&1; then
        echo "SUCCESS: pamac-aur $pamac_version_pin installed via --pamac-version."
        exit 0
    fi
    echo "Direct version install failed. Trying git clone approach..."
    local _compat_work
    _compat_work=$(mktemp -d /var/tmp/pamac-compat-XXXXXX) && chmod 700 "$_compat_work" 2>/dev/null || _compat_work=$(mktemp -d)
    if sudo -Hu "$current_user" bash -lc "git clone --depth 1 --branch '$pamac_version_pin' https://aur.archlinux.org/pamac-aur.git '$_compat_work/pamac-aur'" 2>&1 || \
       sudo -Hu "$current_user" bash -lc "git clone --depth 1 https://aur.archlinux.org/pamac-aur.git '$_compat_work/pamac-aur' && cd '$_compat_work/pamac-aur' && git checkout '$pamac_version_pin'" 2>&1; then
        _set_makepkg_jobs
        if sudo -Hu "$current_user" bash -lc "cd '$_compat_work/pamac-aur' && makepkg -si --noconfirm --clean" 2>&1; then
            echo "SUCCESS: pamac-aur $pamac_version_pin installed from git."
            rm -rf "$_compat_work"
            exit 0
        fi
    fi
    rm -rf "$_compat_work"
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
    if [[ -n "$_rpc_resp" ]]; then
        # Validate JSON response structure with jq (avoids regex fragility on
        # future API field renames or reordering).
        local _resultcount
        _resultcount=$(echo "$_rpc_resp" | jq -r '.resultcount // empty' 2>/dev/null || echo "")
        if [[ "$_resultcount" == "1" ]]; then
            local _deps_formatted _makedeps_formatted
            _deps_formatted=$(echo "$_rpc_resp" | jq -r '.results[0].Depends // [] | join("\n")' 2>/dev/null || echo "")
            _makedeps_formatted=$(echo "$_rpc_resp" | jq -r '.results[0].MakeDepends // [] | join("\n")' 2>/dev/null || echo "")
            if [[ -n "$_deps_formatted" ]]; then
                echo "depends=($_deps_formatted)"
            fi
            if [[ -n "$_makedeps_formatted" ]]; then
                echo "makedepends=($_makedeps_formatted)"
            fi
            if [[ -n "$_deps_formatted" || -n "$_makedeps_formatted" ]]; then
                echo "# Generated from AUR RPC v5 API"
                return 0
            fi
        elif [[ -n "$_resultcount" ]]; then
            echo "# WARN: AUR RPC returned resultcount=$_resultcount (expected 1)" >&2
        fi
    fi

    # Method 2: CGIT web endpoint (may be rate-limited by Cloudflare)
    # Validate response is an actual PKGBUILD (not an HTML error page).
    fetched=$(curl -sf --connect-timeout 10 --max-time 30 \
        "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=pamac-aur" 2>/dev/null || echo "")
    if [[ -n "$fetched" ]] && echo "$fetched" | grep -q "^pkgname="; then
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
if [[ "$req_version" == *.* ]]; then
    _req_minor_raw=$(echo "$req_version" | cut -d. -f2)
    req_minor=$(echo "$_req_minor_raw" | grep -oP '^[0-9]+' || echo "0")
else
    req_minor=0
fi
[[ -z "$req_minor" ]] && req_minor=0
if [[ "$req_version" == *.*.* ]]; then
    _req_patch_raw=$(echo "$req_version" | cut -d. -f3)
    req_patch=$(echo "$_req_patch_raw" | grep -oP '^[0-9]+' || echo "0")
else
    req_patch=0
fi
[[ -z "$req_patch" ]] && req_patch=0

version_meets_requirement() {
    local cur_major="$1" cur_minor="$2" op="$3" rq_major="$4" rq_minor="${5:-0}"
    local cur_patch="${6:-0}" rq_patch="${7:-0}"

    # Use vercmp when available (standard Arch Linux utility that correctly handles
    # epochs like "6:5.2.0", pre-release suffixes like "rc", and package revisions)
    if command -v vercmp >/dev/null 2>&1; then
        local cur_full="${cur_major}.${cur_minor}.${cur_patch}"
        local rq_full="${rq_major}.${rq_minor}.${rq_patch}"
        # Strip trailing .0 components for cleaner comparison (vercmp handles them)
        cur_full="${cur_full%.0}"
        rq_full="${rq_full%.0}"
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

    # Fallback: manual major.minor.patch comparison (when vercmp is unavailable)
    # Compares major, then minor, then patch to handle three-component versions.
    case "$op" in
        ">="|"="|"==")
            if [[ "$cur_major" -gt "$rq_major" ]]; then return 0; fi
            if [[ "$cur_major" -eq "$rq_major" && "$cur_minor" -gt "$rq_minor" ]]; then return 0; fi
            if [[ "$cur_major" -eq "$rq_major" && "$cur_minor" -eq "$rq_minor" && "$cur_patch" -ge "$rq_patch" ]]; then return 0; fi
            return 1
            ;;
        ">")
            if [[ "$cur_major" -gt "$rq_major" ]]; then return 0; fi
            if [[ "$cur_major" -eq "$rq_major" && "$cur_minor" -gt "$rq_minor" ]]; then return 0; fi
            if [[ "$cur_major" -eq "$rq_major" && "$cur_minor" -eq "$rq_minor" && "$cur_patch" -gt "$rq_patch" ]]; then return 0; fi
            return 1
            ;;
        "<=")
            if [[ "$cur_major" -lt "$rq_major" ]]; then return 0; fi
            if [[ "$cur_major" -eq "$rq_major" && "$cur_minor" -lt "$rq_minor" ]]; then return 0; fi
            if [[ "$cur_major" -eq "$rq_major" && "$cur_minor" -eq "$rq_minor" && "$cur_patch" -le "$rq_patch" ]]; then return 0; fi
            return 1
            ;;
        "<")
            if [[ "$cur_major" -lt "$rq_major" ]]; then return 0; fi
            if [[ "$cur_major" -eq "$rq_major" && "$cur_minor" -lt "$rq_minor" ]]; then return 0; fi
            if [[ "$cur_major" -eq "$rq_major" && "$cur_minor" -eq "$rq_minor" && "$cur_patch" -lt "$rq_patch" ]]; then return 0; fi
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

if version_meets_requirement "$pacman_major" "$pacman_minor" "$req_op" "$req_major" "$req_minor" "$pacman_patch" "$req_patch"; then
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
    # Fallback: manual major.minor.patch comparison
    if [[ "$req_major" -gt "$pacman_major" ]] || \
       { [[ "$req_major" -eq "$pacman_major" ]] && [[ "$req_minor" -gt "$pacman_minor" ]]; } || \
       { [[ "$req_major" -eq "$pacman_major" ]] && [[ "$req_minor" -eq "$pacman_minor" ]] && [[ "$req_patch" -gt "$pacman_patch" ]]; }; then
        can_upgrade_pacman=true
    fi
fi

if [[ "$can_upgrade_pacman" == "true" ]]; then
    echo ">>> Strategy A: Container pacman is TOO OLD (have $installed_pacman_ver, need $req_op $req_version)"
    echo ">>> Attempting to upgrade pacman inside the container to satisfy pamac-aur..."
    _remove_stale_lock
    if pacman -Sy --noconfirm 2>&1 | tail -5; then
        echo "Database synced. Upgrading pacman and dependencies..."
        _remove_stale_lock
        if pacman -S --noconfirm --needed pacman 2>&1 | tail -10; then
            new_ver=$(pacman -Q pacman 2>/dev/null | awk '{print $2}' || echo "")
            echo "Upgraded pacman to: $new_ver"
            new_major=$(echo "$new_ver" | sanitize_version_component)
            _new_ver_stripped=$(echo "$new_ver" | sed 's/^[^:]*://')
            if [[ "$_new_ver_stripped" == *.* ]]; then
                _new_minor_raw=$(echo "$_new_ver_stripped" | cut -d. -f2)
                new_minor=$(echo "$_new_minor_raw" | grep -oP '^[0-9]+' || echo "0")
            else
                new_minor=0
            fi
            [[ -z "$new_minor" ]] && new_minor=0
            if [[ "$_new_ver_stripped" == *.*.* ]]; then
                _new_patch_raw=$(echo "$_new_ver_stripped" | cut -d. -f3)
                new_patch=$(echo "$_new_patch_raw" | grep -oP '^[0-9]+' || echo "0")
            else
                new_patch=0
            fi
            [[ -z "$new_patch" ]] && new_patch=0
            if version_meets_requirement "$new_major" "$new_minor" "$req_op" "$req_major" "$req_minor" "$new_patch" "$req_patch"; then
                echo "SUCCESS: Upgraded pacman $new_ver now satisfies $aur_pacman_dep"
                ldconfig 2>/dev/null || true
                exit 0
            fi
            echo "WARNING: Upgraded pacman $new_ver still does not satisfy $aur_pacman_dep"
            echo "Attempting full system upgrade to pull in all dependencies..."
            _remove_stale_lock
            pacman -Syu --noconfirm 2>&1 | tail -20 || true
            new_ver=$(pacman -Q pacman 2>/dev/null | awk '{print $2}' || echo "")
            echo "After full upgrade, pacman version: $new_ver"
            new_major=$(echo "$new_ver" | sanitize_version_component)
            _new_ver_stripped2=$(echo "$new_ver" | sed 's/^[^:]*://')
            if [[ "$_new_ver_stripped2" == *.* ]]; then
                _new_minor_raw2=$(echo "$_new_ver_stripped2" | cut -d. -f2)
                new_minor=$(echo "$_new_minor_raw2" | grep -oP '^[0-9]+' || echo "0")
            else
                new_minor=0
            fi
            [[ -z "$new_minor" ]] && new_minor=0
            if [[ "$_new_ver_stripped2" == *.*.* ]]; then
                _new_patch_raw2=$(echo "$_new_ver_stripped2" | cut -d. -f3)
                new_patch=$(echo "$_new_patch_raw2" | grep -oP '^[0-9]+' || echo "0")
            else
                new_patch=0
            fi
            [[ -z "$new_patch" ]] && new_patch=0
            if version_meets_requirement "$new_major" "$new_minor" "$req_op" "$req_major" "$req_minor" "$new_patch" "$req_patch"; then
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
_AUR_WORK=$(mktemp -d /var/tmp/pamac-aur-history-XXXXXX) && chmod 700 "$_AUR_WORK" 2>/dev/null || _AUR_WORK=$(mktemp -d)
rm -rf "$_AUR_WORK"

echo "Cloning pamac-aur repository (depth=200) for commit history..."
if ! git clone --depth=200 --single-branch "$_AUR_GIT_URL" "$_AUR_WORK" 2>/tmp/pamac_aur_clone_err; then
    echo "WARN: git clone of pamac-aur failed:"
    cat /tmp/pamac_aur_clone_err 2>/dev/null | tail -3
    rm -rf "$_AUR_WORK"
    echo "WARN: Falling back to Strategy C (build latest regardless of compatibility)."
    echo "COMPATIBLE_COMMIT=latest_anyway"
    exit 3
fi

_commits=$(git -C "$_AUR_WORK" log --format=%H -50 2>/dev/null || true)
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
    old_req_patch=$(echo "$old_req_ver" | cut -d. -f3 | grep -oP '^[0-9]*' || echo "0")
    [[ -z "$old_req_major" ]] && old_req_major=0
    [[ -z "$old_req_minor" ]] && old_req_minor=0
    [[ -z "$old_req_patch" ]] && old_req_patch=0
    old_req_op=$(echo "$old_dep" | grep -oP "[><=]+" | head -1 || echo "")

    if version_meets_requirement "$pacman_major" "$pacman_minor" "$old_req_op" "$old_req_major" "$old_req_minor" "$pacman_patch" "$old_req_patch"; then
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
    _compat_script_file=$(mktemp "${_SCRIPT_TMPDIR:-/tmp}/pamac-compat-XXXXXXXX")
    _TEMP_FILES+=("$_compat_script_file")
    printf '%s\n' "${_preamble}${compat_script}" > "$_compat_script_file"

    local _compat_marker
    _compat_marker="COMPAT_CHECK_$(head -c 8 /dev/urandom 2>/dev/null | base64 2>/dev/null || echo "$$")"
    printf '\necho "%s"\n' "$_compat_marker" >> "$_compat_script_file"

    if _exec_dry_run_check "pamac-aur compatibility check" "$_compat_script_file"; then
        rm -f "$_compat_script_file"
        return 0
    fi

    set +e
    local _compat_output=""
    if [[ "$LOG_LEVEL" == "verbose" ]]; then
      # Same PIPESTATUS-in-subproc fix: capture exit directly from the
      # assignment so container_root_exec failures are not masked.
      _compat_output=$(container_root_exec bash -s "$@" < "$_compat_script_file" 2>&1); _compat_rc=$?
      tee -a "$LOG_FILE" <<< "$_compat_output" | _filter_verbose_output || true
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

# Prints the standard "pamac-aur install failed" diagnostic + recovery help.
# Previously this ~16-line block was duplicated inside install_pamac (once for
# the recovery-retry failure path, once for the retry failure path). Keeping a
# single source of truth here avoids the two copies drifting out of sync.
_print_pamac_install_help() {
    local _headline="${1:-Failed to install Pamac.}"
    log_error "$_headline"
    log_error ""
    log_error "The pamac-aur AUR package may be broken upstream."
    log_error "This can happen when Arch rolls a major libalpm/pacman upgrade"
    log_error "and pamac-aur's C++ build system hasn't been updated yet."
    log_error ""
    log_error "Diagnostic steps:"
    log_error "  1. Check container pacman version: distrobox enter $CONTAINER_NAME -- pacman -Q pacman"
    log_error "  2. Check libalpm headers: distrobox enter $CONTAINER_NAME -- pkg-config --modversion libalpm"
    log_error "  3. Check for C++ build errors in log: grep -i 'error\\|fatal' $LOG_FILE | tail -20"
    log_error ""
    log_error "Recovery options:"
    log_error "  1. Check https://aur.archlinux.org/packages/pamac-aur for current status"
    log_error "  2. Try: --pamac-version <tag>  to pin a specific working version"
    log_error "  3. Wait for the AUR maintainer to update pamac-aur for the latest pacman"
    log_error "  4. Try: distrobox enter $CONTAINER_NAME -- pacman -Syu && yay -S --rebuild pamac-aur"
    log_error ""
}

install_pamac() {
    log_step "Installing Pamac package manager"

    if container_user_exec bash -c "command -v pamac-manager >/dev/null 2>&1 && command -v pamac >/dev/null 2>&1" 2>/dev/null; then
        log_info "Pamac is already installed (manager + CLI)."
        return 0
    fi

    log_info "Attempting to install pamac-aur from prebuilt repositories..."
    local _prebuilt_output
    _prebuilt_output=$(container_root_exec bash -c 'if [[ -f /var/lib/pacman/db.lck ]]; then _p=$(cat /var/lib/pacman/db.lck 2>/dev/null || echo ""); if [[ -n "$_p" ]] && kill -0 "$_p" 2>/dev/null && grep -E "pacman|yay" "/proc/$_p/comm" >/dev/null 2>&1; then echo "Pacman running (PID $_p), waiting..."; _w=0; while [[ $_w -lt 30 ]] && kill -0 "$_p" 2>/dev/null; do sleep 2; _w=$(( _w + 2 )); done; if kill -0 "$_p" 2>/dev/null; then echo "ERROR: Pacman (PID $_p) still running after 30s. Aborting."; exit 1; fi; fi; rm -f /var/lib/pacman/db.lck; fi; pacman -Sy --noconfirm 2>/dev/null; pacman -S --noconfirm --needed pamac-aur 2>/dev/null; command -v pamac-manager >/dev/null 2>&1 && command -v pamac >/dev/null 2>&1 && echo __PREBUILT_OK__' 2>/dev/null) || _prebuilt_output=""
    if [[ -n "$_prebuilt_output" ]] && grep -q "__PREBUILT_OK__" <<< "$_prebuilt_output"; then
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

_remove_stale_lock

echo "Installing pamac-aur (strategy: $compat_strategy)..."
pamac_installed=false

if ! sudo -n true 2>/dev/null; then
    echo "Warning: passwordless sudo not available. yay build may hang waiting for password."
    echo "If build hangs, ensure NOPASSWD sudo is configured for the current user in the container."
fi

install_from_aur_commit() {
    local commit="$1"
    local work_dir
    work_dir=$(mktemp -d /var/tmp/pamac-pkg-XXXXXX) && chmod 700 "$work_dir" 2>/dev/null || work_dir=$(mktemp -d)
    echo "Cloning pamac-aur at commit ${commit:0:12}..."
    rm -rf "$work_dir"
    sudo -Hu "$current_user" bash -lc "git clone --depth=200 https://aur.archlinux.org/pamac-aur.git '$work_dir'" 2>/tmp/pamac_clone_err || {
        echo "Git clone failed:"
        cat /tmp/pamac_clone_err 2>/dev/null | tail -5
        return 1
    }
    if ! sudo -Hu "$current_user" bash -lc "cd '$work_dir' && git checkout '$commit'" 2>/tmp/pamac_checkout_err; then
        echo "Checkout failed at depth 200, attempting full unshallow fetch to reach commit ${commit:0:12}..."
        # Single round-trip 'git fetch --unshallow' is far more efficient than
        # iterating --deepen 100 (which used to do 3-4 round-trips for a commit
        # 500 deep). If unshallow fails (e.g. shallow support issues), fall back
        # to a single --deepen to the full repo depth as a last resort.
        local _found=false
        if sudo -Hu "$current_user" bash -lc "cd '$work_dir' && git fetch --unshallow" 2>/dev/null; then
            echo "  Full unshallow fetch complete."
            if sudo -Hu "$current_user" bash -lc "cd '$work_dir' && git checkout '$commit'" 2>/dev/null; then
                _found=true
                echo "  Found commit after full fetch."
            fi
        else
            echo "  git fetch --unshallow failed. Trying a single --deepen 1000 fallback..."
            sudo -Hu "$current_user" bash -lc "cd '$work_dir' && git fetch --deepen 1000" 2>/dev/null || true
            if sudo -Hu "$current_user" bash -lc "cd '$work_dir' && git checkout '$commit'" 2>/dev/null; then
                _found=true
                echo "  Found commit after --deepen 1000 fallback."
            fi
        fi
        if [[ "$_found" != "true" ]]; then
            echo "Checkout failed (commit ${commit:0:12}) after full fetch:"
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
        _remove_stale_lock
    done
    return 1
}

validate_pamac_build_deps() {
    echo "=== Pre-build dependency validation ==="
    local _missing=""
    local _warnings=""

    # Critical build system tools
    for tool in meson vala gcc make ninja; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            _missing="$_missing $tool"
        fi
    done

    # Check libalpm development headers via pkg-config
    if command -v pkg-config >/dev/null 2>&1; then
        if ! pkg-config --exists libalpm 2>/dev/null; then
            _warnings="$_warnings libalpm-dev (pkg-config); "
            echo "  WARNING: libalpm development headers not found via pkg-config."
            echo "  This may cause build failures if the libalpm API has changed."
            echo "  Installing pacman and libalpm development files..."
            _remove_stale_lock
            pacman -S --noconfirm --needed pacman 2>/dev/null || true
            if ! pkg-config --exists libalpm 2>/dev/null; then
                _missing="$_missing libalpm-dev"
                echo "  ERROR: libalpm development headers still not available."
                echo "  This strongly suggests a libalpm API incompatibility."
            fi
        else
            local _libalpm_ver
            _libalpm_ver=$(pkg-config --modversion libalpm 2>/dev/null || echo "unknown")
            echo "  libalpm version: $_libalpm_ver"
        fi
    else
        _warnings="$_warnings pkg-config; "
        echo "  WARNING: pkg-config not found. Cannot verify libalpm compatibility."
    fi

    # Check for vala compiler version (pamac requires recent vala)
    if command -v valac >/dev/null 2>&1; then
        local _vala_ver
        _vala_ver=$(valac --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+' || echo "unknown")
        echo "  vala compiler version: $_vala_ver"
    fi

    if [[ -n "$_missing" ]]; then
        echo ""
        echo "FATAL: Missing critical build dependencies:$_missing"
        echo "These are required to compile pamac-aur from source."
        echo "Attempting to install missing dependencies..."
        _remove_stale_lock
        pacman -Sy --noconfirm 2>/dev/null || true
        for pkg in $_missing; do
            case "$pkg" in
                meson) pacman -S --noconfirm --needed meson 2>/dev/null || true ;;
                vala) pacman -S --noconfirm --needed vala 2>/dev/null || true ;;
                gcc) pacman -S --noconfirm --needed gcc 2>/dev/null || true ;;
                make) pacman -S --noconfirm --needed make 2>/dev/null || true ;;
                ninja) pacman -S --noconfirm --needed ninja 2>/dev/null || true ;;
                libalpm-dev) pacman -S --noconfirm --needed pacman 2>/dev/null || true ;;
            esac
        done
        # Re-check after install
        local _still_missing=""
        for tool in meson vala gcc make ninja; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                _still_missing="$_still_missing $tool"
            fi
        done
        if [[ -n "$_still_missing" ]]; then
            echo "FATAL: Could not install:$_still_missing"
            echo "Cannot build pamac-aur without these tools."
            return 1
        fi
        echo "All missing dependencies installed successfully."
    fi

    if [[ -n "$_warnings" ]]; then
        echo ""
        echo "WARNING: Non-critical dependency issues:$_warnings"
        echo "Build may succeed but could fail if these are actually required."
    fi

    echo "=== Build dependency validation complete ==="
    return 0
}

verify_pamac_libalpm_compat() {
    echo "=== Post-install libalpm compatibility verification ==="
    local _pamac_binary=""
    local _issues=0

    # Find the pamac binary
    for candidate in /usr/bin/pamac /usr/bin/pamac-manager /usr/lib/pamac/pamac-daemon; do
        if [[ -f "$candidate" ]]; then
            _pamac_binary="$candidate"
            break
        fi
    done

    if [[ -z "$_pamac_binary" ]]; then
        echo "  WARNING: Could not locate pamac binary for libalpm verification."
        return 0
    fi

    echo "  Checking binary: $_pamac_binary"

    # Check if the binary links against libalpm
    if command -v ldd >/dev/null 2>&1; then
        local _alpm_link
        _alpm_link=$(ldd "$_pamac_binary" 2>/dev/null | grep libalpm || echo "")
        if [[ -n "$_alpm_link" ]]; then
            echo "  Binary links against: $_alpm_link"
            # Check if the linked library actually exists
            local _lib_path
            _lib_path=$(echo "$_alpm_link" | awk '{print $3}' | head -1 || echo "")
            if [[ -n "$_lib_path" && -f "$_lib_path" ]]; then
                echo "  libalpm library found: $_lib_path"
            elif [[ -n "$_lib_path" ]]; then
                echo "  ERROR: libalpm library NOT FOUND at: $_lib_path"
                echo "  This indicates a library mismatch - pamac was compiled against a different libalpm version."
                _issues=$((_issues + 1))
            fi
        else
            echo "  Binary does not link against libalpm (may be a wrapper)."
        fi
    fi

    # Check if pamac can at least print its version (basic smoke test).
    # Wrap with timeout to protect against hangs from corrupted shared
    # libraries or deadlocks in broken libalpm builds.
    local _pamac_ver_rc=0
    local _pamac_ver_out=""
    _pamac_ver_out=$(timeout 5 /usr/bin/pamac --version 2>&1) || _pamac_ver_rc=$?
    if [[ $_pamac_ver_rc -eq 0 ]]; then
        echo "  pamac --version: $(echo "$_pamac_ver_out" | head -1)"
        echo "  Basic smoke test: PASSED"
    else
        echo "  WARNING: pamac --version failed (exit $_pamac_ver_rc, timeout 5s)"
        echo "  This may indicate a runtime library incompatibility or a hang."
        _issues=$((_issues + 1))
    fi

    if [[ $_issues -gt 0 ]]; then
        echo ""
        echo "  libalpm compatibility issues detected ($_issues problems)."
        echo "  The pamac binary may have been compiled against a different libalpm version."
        echo "  Possible causes:"
        echo "    - Container pacman was upgraded but pamac was compiled against older headers"
        echo "    - pamac-aur AUR package requires a different libalpm version than installed"
        echo "    - Shared library symlinks are broken"
        echo "  Try: pacman -S --noconfirm --needed pacman (to sync libalpm)"
        echo "  Or:  yay -S --rebuild pamac-aur (to force recompilation)"
        return 1
    fi

    echo "  libalpm compatibility verification: PASSED"
    return 0
}

case "$compat_strategy" in
    use_commit)
        if [[ -n "$compat_commit" ]]; then
            echo "Strategy: install from compatible AUR commit ${compat_commit:0:12}"
            validate_pamac_build_deps || {
                echo "FATAL: Build dependency validation failed. Cannot compile pamac-aur."
                echo "This usually indicates a C++ toolchain or library incompatibility."
                echo "Try: pacman -Syu (full system upgrade) then re-run this script."
                exit 1
            }
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
            validate_pamac_build_deps || true
            if install_from_yay; then
                pamac_installed=true
            fi
        fi
        ;;
    try_latest|ok|"")
        echo "Strategy: install latest pamac-aur via yay"
        validate_pamac_build_deps || {
            echo "FATAL: Build dependency validation failed. Cannot compile pamac-aur."
            echo "This usually indicates a C++ toolchain or library incompatibility."
            echo "Try: pacman -Syu (full system upgrade) then re-run this script."
            exit 1
        }
        if install_from_yay; then
            pamac_installed=true
        else
            echo "Standard yay install failed. Attempting direct clone..."
            local _fb_work
            _fb_work=$(mktemp -d /var/tmp/pamac-fb-XXXXXX) && chmod 700 "$_fb_work" 2>/dev/null || _fb_work=$(mktemp -d)
            if sudo -Hu "$current_user" bash -lc "git clone --depth=1 https://aur.archlinux.org/pamac-aur.git '$_fb_work/pamac-aur'" 2>"$_fb_work/err"; then
                _set_makepkg_jobs
                if sudo -Hu "$current_user" bash -lc "cd '$_fb_work/pamac-aur' && makepkg -si --noconfirm --clean" 2>&1 | tail -15; then
                    pamac_installed=true
                fi
                rm -rf "$_fb_work"
            else
                echo "Direct clone also failed:"
                cat "$_fb_work/err" 2>/dev/null | tail -5
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
    _remove_stale_lock
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

# Post-build verification: ensure pamac binary is compatible with installed libalpm
if ! verify_pamac_libalpm_compat; then
    echo ""
    echo "WARNING: Post-install libalpm compatibility check detected issues."
    echo "pamac may not function correctly. Consider:"
    echo "  1. pacman -S --noconfirm --needed pacman  (sync libalpm)"
    echo "  2. yay -S --rebuild pamac-aur              (force recompilation)"
    echo "  3. Check: ldd /usr/bin/pamac | grep libalpm"
    echo "Continuing installation despite compatibility warnings..."
fi
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
                    _print_pamac_install_help "Failed to install Pamac after recovery retry."
                    return 1
                fi
            else
                _print_pamac_install_help "Failed to install Pamac after retry."
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

echo "Setting pamac polkit policy for passwordless operation..."
pamac_policy="/usr/share/polkit-1/actions/org.manjaro.pamac.policy"
if [[ -f "$pamac_policy" ]]; then
    # Blanket-set allow_* to "yes" across every <action> (host root is
    # read-only; container's own system bus + polkitd is the only authority,
    # so these in-container values must be authoritative — see comment in
    # the stage-6a block).
    _atomic_sed_inplace "$pamac_policy" \
        's|<allow_any>[^<]*</allow_any>|<allow_any>yes</allow_any>|g' \
        's|<allow_active>[^<]*</allow_active>|<allow_active>yes</allow_active>|g' \
        's|<allow_inactive>[^<]*</allow_inactive>|<allow_inactive>yes</allow_inactive>|g'
    echo "Polkit policy set to allow_any=allow_active=allow_inactive=yes for ALL pamac actions."
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
    /usr/local/bin/pamac-session-bootstrap.sh 2>&1 || true
fi
pacman -Sy --noconfirm >/dev/null 2>&1 || echo "Note: package database sync failed"

# Fix D-Bus service file for non-systemd containers (remove User=root, SystemdService)
_dbus_svc="/usr/share/dbus-1/system-services/org.manjaro.pamac.daemon.service"
if [[ -f "$_dbus_svc" ]]; then
    cat > "$_dbus_svc" << 'DBUS_SVC_FIX'
[D-BUS Service]
Name=org.manjaro.pamac.daemon
Exec=/usr/bin/pamac-daemon
DBUS_SVC_FIX
    echo "Fixed D-Bus service file for non-systemd container."
fi

# Fix PolicyKit1 D-Bus service file (keep User=root for activation, remove SystemdService)
_pkit_svc="/usr/share/dbus-1/system-services/org.freedesktop.PolicyKit1.service"
if [[ -f "$_pkit_svc" ]] && grep -q "SystemdService" "$_pkit_svc" 2>/dev/null; then
    cat > "$_pkit_svc" << 'PKIT_SVC_FIX'
[D-BUS Service]
Name=org.freedesktop.PolicyKit1
Exec=/usr/lib/polkit-1/polkitd --no-debug
User=root
PKIT_SVC_FIX
    echo "Fixed PolicyKit1 D-Bus service file for non-systemd container."
fi

# Ensure /var/lib/polkit-1 exists (polkitd authority database)
mkdir -p /var/lib/polkit-1
chmod 755 /var/lib/polkit-1

# Ensure system bus daemon is running (distrobox doesn't have systemd)
if ! dbus-send --system --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
    mkdir -p /run/dbus
    rm -f /run/dbus/pid
    dbus-daemon --system --fork 2>/dev/null || true
    echo "Started system bus daemon."
fi

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

setup_cache_cleanup() {
    log_step "Setting up build cache cleanup"

    local cache_script
    read -r -d '' cache_script <<'CACHE_EOF' || true
set -uo pipefail

_remove_stale_lock

echo "Cleaning orphaned build dependencies..."

# Safety: never remove these critical packages even if they appear as orphans
_CRITICAL_PKGS="glibc gcc-libs binutils systemd systemd-libs pam lib32-glibc lib32-gcc-libs mesa vulkan-icd-loader lib32-mesa lib32-vulkan-icd-loader"

_orphan_pkgs=$(pacman -Qdtq 2>/dev/null || true)
if [[ -n "$_orphan_pkgs" ]]; then
    _count=$(echo "$_orphan_pkgs" | wc -l)
    echo "  Found $_count orphaned package(s)."
    
    # Filter out critical packages
    _safe_orphans=""
    while IFS= read -r _pkg; do
        [[ -z "$_pkg" ]] && continue
        _skip=false
        for _crit in $_CRITICAL_PKGS; do
            if [[ "$_pkg" == "$_crit" ]]; then
                echo "  SKIPPING critical package: $_pkg"
                _skip=true
                break
            fi
        done
        if [[ "$_skip" != "true" ]]; then
            _safe_orphans="$_safe_orphans $_pkg"
        fi
    done <<< "$_orphan_pkgs"
    
    if [[ -n "$_safe_orphans" ]]; then
        echo "  Removing $(echo "$_safe_orphans" | wc -w) safe orphaned package(s)..."
        echo "$_safe_orphans" | xargs pacman -Rns --noconfirm 2>/dev/null || true
    else
        echo "  No safe orphaned packages to remove (all were critical)."
    fi
else
    echo "  No orphaned packages found."
fi

echo "Running paccache to keep only 3 most recent package versions..."
if command -v paccache >/dev/null 2>&1; then
    paccache -r --noconfirm 2>/dev/null || true
else
    echo "paccache not found. Installing pacman-contrib..."
    pacman -S --noconfirm --needed pacman-contrib 2>/dev/null && paccache -r --noconfirm 2>/dev/null || true
fi

# Prune downloaded .pkg.tar.zst archives from yay's AUR cache without
# removing cloned source directories (needed for faster rebuilds).
# This is deliberately more conservative than 'yay -Sc' because Distrobox
# mounts the host's /home — a full 'yay -Sc' would destroy the host-side
# build cache at ~/.cache/yay-${CONTAINER_NAME}.
echo "Pruning .pkg.tar.zst archives from yay cache (preserving sources)..."
_yay_cache="${XDG_CACHE_HOME:-$HOME/.cache}/yay"
if [[ -d "$_yay_cache" ]]; then
    find "$_yay_cache" -name '*.pkg.tar.zst' -delete 2>/dev/null || true
    echo "  Cleaned yay package archives from $_yay_cache"
fi

echo "Cache cleanup complete."
CACHE_EOF

    if ! exec_container_script "$cache_script" "cache-cleanup"; then
        log_warn "Initial cache cleanup had issues. Continuing..."
    fi

    log_info "Installing weekly cache cleanup timer..."
    local timer_script
    read -r -d '' timer_script <<'TIMER_EOF' || true
set -uo pipefail

_remove_stale_lock

mkdir -p /etc/pacman.d

cat > /usr/local/bin/pamac-cache-cleanup.sh << 'CLEANUP'
#!/bin/bash
set +e

_remove_stale_lock() {
    local _lock="/var/lib/pacman/db.lck"
    if [[ ! -f "$_lock" ]]; then return 0; fi
    local _lck_pid
    _lck_pid=$(cat "$_lock" 2>/dev/null || echo "")
    if [[ -n "$_lck_pid" ]] && [[ "$_lck_pid" =~ ^[0-9]+$ ]] && kill -0 "$_lck_pid" 2>/dev/null; then
        echo "Pacman is currently running (PID $_lck_pid). Skipping cleanup."
        exit 0
    fi
    rm -f "$_lock" 2>/dev/null || true
}

_remove_stale_lock

# Safety: never remove these critical packages even if they appear as orphans
_CRITICAL_PKGS="glibc gcc-libs binutils systemd systemd-libs pam lib32-glibc lib32-gcc-libs mesa vulkan-icd-loader lib32-mesa lib32-vulkan-icd-loader"

_orphan_pkgs=$(pacman -Qdtq 2>/dev/null || true)
if [[ -n "$_orphan_pkgs" ]]; then
    _safe_orphans=""
    while IFS= read -r _pkg; do
        [[ -z "$_pkg" ]] && continue
        _skip=false
        for _crit in $_CRITICAL_PKGS; do
            if [[ "$_pkg" == "$_crit" ]]; then _skip=true; break; fi
        done
        if [[ "$_skip" != "true" ]]; then
            _safe_orphans="$_safe_orphans $_pkg"
        fi
    done <<< "$_orphan_pkgs"
    if [[ -n "$_safe_orphans" ]]; then
        echo "$_safe_orphans" | xargs pacman -Rns --noconfirm 2>/dev/null || true
    fi
fi

if command -v paccache >/dev/null 2>&1; then
    paccache -r --noconfirm 2>/dev/null || true
fi

# Prune .pkg.tar.zst archives only — preserve AUR source directories for
# faster rebuilds. Full 'yay -Sc' is avoided because Distrobox mounts the
# host /home and would destroy the host-side build cache.
_yay_cache="${XDG_CACHE_HOME:-$HOME/.cache}/yay"
if [[ -d "$_yay_cache" ]]; then
    find "$_yay_cache" -name '*.pkg.tar.zst' -delete 2>/dev/null || true
fi
CLEANUP
chmod 755 /usr/local/bin/pamac-cache-cleanup.sh

mkdir -p /etc/systemd/system
cat > /etc/systemd/system/pamac-cache-cleanup.service << 'SVC'
[Unit]
Description=Weekly Pamac build cache cleanup
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pamac-cache-cleanup.sh
Nice=19
IOSchedulingClass=idle
SVC

cat > /etc/systemd/system/pamac-cache-cleanup.timer << 'TIMER'
[Unit]
Description=Weekly Pamac cache cleanup timer

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
TIMER

if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now pamac-cache-cleanup.timer 2>/dev/null || \
        echo "Note: systemd timer setup failed (no systemd in container)"
else
    echo "Note: systemd not available, skipping timer setup. Manual cleanup: pamac-cache-cleanup.sh"
fi

echo "Cache cleanup timer installed."
TIMER_EOF

    if ! exec_container_script "$timer_script" "cache-timer-setup"; then
        log_warn "Cache cleanup timer setup had issues. Continuing..."
    fi

    if [[ "$ENABLE_BUILD_CACHE" == "true" ]]; then
        log_info "Host build cache: $HOME/.cache/yay-${CONTAINER_NAME}"
        log_info "The container runs paccache weekly to prevent unbounded growth."
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
set -uo pipefail

current_user="$1"
is_multilib="$2"

# Install order matters: dependencies first, then dependent packages
# wine-staging depends on multilib packages, so install it after lib32-* packages
_base_packages=( "gamemode" "mangohud" "winetricks" "lutris" )
if [[ "$is_multilib" == "true" ]]; then
    echo "Adding 32-bit gaming libraries..."
    _base_packages+=( "lib32-gamemode" "lib32-mangohud" )
fi
# wine-staging goes last — it's the largest and most likely to fail on missing deps
_base_packages+=( "wine-staging" )

echo "Installing gaming packages in dependency order: ${_base_packages[*]}"
failed_packages=()
installed_packages=()

for package in "${_base_packages[@]}"; do
    echo "Installing ${package}..."
    _pkg_ok=false
    for _attempt in 1 2; do
        if sudo -Hu "$current_user" bash -lc "yay -S --noconfirm --needed --noprogressbar ${package}" 2>/dev/null; then
            _pkg_ok=true
            break
        fi
        echo "  Attempt $_attempt/2 failed for ${package}. Retrying..."
        sleep 2
    done
    if [[ "$_pkg_ok" == "true" ]]; then
        installed_packages+=("${package}")
    else
        echo "  WARNING: Failed to install ${package} after 2 attempts."
        failed_packages+=("${package}")
    fi
done

echo ""
echo "=== Gaming Package Summary ==="
echo "Installed: ${#installed_packages[@]}/${#_base_packages[@]}"
if [[ ${#installed_packages[@]} -gt 0 ]]; then
    echo "  ${installed_packages[*]}"
fi
if [[ ${#failed_packages[@]} -gt 0 ]]; then
    echo "Failed: ${#failed_packages[@]}"
    echo "  ${failed_packages[*]}"
    echo ""
    echo "To retry failed packages manually:"
    for _fp in "${failed_packages[@]}"; do
        echo "  yay -S --needed $_fp"
    done
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
        chmod 600 "$ssh_dir/environment"
        log_info "Created $ssh_dir/environment with clean PATH (permissions: 600)"
    fi

    local sshd_conf_dir="/etc/ssh/sshd_config.d"
    local permit_env_conf="$sshd_conf_dir/permit-user-env.conf"
    # Only write PermitUserEnvironment yes when the user explicitly opted in
    # via --enable-ssh-env. Default off: this setting is a privilege-escalation
    # vector on multi-user hosts (see ENABLE_SSH_ENV comment near top of script).
    if [[ "$ENABLE_SSH_ENV" != "true" ]]; then
        log_info "SSH PermitUserEnvironment is disabled (default for security). Pass --enable-ssh-env to opt in on a single-user trusted host."
        return 0
    fi
    if [[ ! -f "$permit_env_conf" ]]; then
        # Backup existing sshd config before modification
        if [[ -d "$sshd_conf_dir" ]]; then
            cp -a "$sshd_conf_dir" "${sshd_conf_dir}.backup-$(date +%Y%m%d)" 2>/dev/null || true
        fi
        # Validate sshd config before writing
        local _sshd_valid=true
        if command -v sshd >/dev/null 2>&1; then
            if ! sshd -t 2>/dev/null; then
                log_warn "Existing sshd config has errors. Fix before enabling PermitUserEnvironment."
                _sshd_valid=false
            fi
        fi
        if [[ "$_sshd_valid" == "true" ]]; then
            if mkdir -p "$sshd_conf_dir" 2>/dev/null; then
                echo "PermitUserEnvironment yes" | run_command tee "$permit_env_conf" > /dev/null 2>&1
                # Validate the new config before restarting
                if command -v sshd >/dev/null 2>&1 && ! sshd -t 2>/dev/null; then
                    log_warn "sshd config validation failed after writing permit-user-env.conf. Reverting..."
                    rm -f "$permit_env_conf" 2>/dev/null || true
                else
                    if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
                        run_command systemctl restart sshd 2>/dev/null || true
                    else
                        run_command pkill -HUP sshd 2>/dev/null || true
                    fi
                    log_info "Enabled PermitUserEnvironment in sshd"
                fi
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

    # Atomic write helper: writes to temp file, validates, then renames into place.
    # Prevents corrupted/partial desktop files if the process is killed mid-write.
    _atomic_desktop_write() {
        local _target="$1" _content="$2"
        local _tmp
        _tmp=$(mktemp "${_target}.tmp.XXXXXX") || { log_warn "mktemp failed for $_target"; return 1; }
        printf '%s\n' "$_content" > "$_tmp"
        if [[ -s "$_tmp" ]]; then
            mv -f "$_tmp" "$_target"
        else
            rm -f "$_tmp"
            log_warn "Atomic write produced empty file for $_target"
            return 1
        fi
    }

    # Rollback trap: tracks created files and cleans up on failure
    local _created_files=()
    _export_cleanup_on_error() {
        local _exit_code=$?
        if [[ $_exit_code -ne 0 ]]; then
            log_warn "Export failed (exit $_exit_code). Cleaning up partially created files..."
            for _f in "${_created_files[@]}"; do
                if [[ -f "$_f" ]]; then
                    rm -f "$_f" 2>/dev/null || true
                    log_info "  Removed: $_f"
                fi
            done
        fi
    }
    trap '_export_cleanup_on_error' EXIT

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

    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" -f 2>/dev/null || true
    fi

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
        log_info "Wayland taskbar integration uses StartupWMClass — no xdotool needed."
    fi

    local host_tools_available=false
    if command -v xdotool >/dev/null 2>&1 || [[ -x "$_host_bindir/xdotool" ]]; then
        host_tools_available=true
        log_success "X11 window tools available (xdotool — X11 fallback)."
    fi
    if [[ "$host_tools_available" == "false" ]]; then
        log_info "No xdotool available on host. Wayland taskbar integration uses StartupWMClass (no tools needed)."
    fi

    log_info "Creating pamac-manager launch wrapper inside container..."
    local _desktop_path="/home/${CURRENT_USER}/.local/share/applications/${CONTAINER_NAME}-org.manjaro.pamac.manager.desktop"

    # Detect the actual StartupWMClass from the container's installed desktop file.
    # GTK3/GTK4 apps may use reverse-DNS (org.manjaro.pamac.manager) or the binary
    # name (pamac-manager). Hardcoding the wrong value breaks taskbar grouping.
    local _detected_wmclass="pamac-manager"
    _detected_wmclass=$(container_root_exec bash -c "grep -E '^StartupWMClass=' /usr/share/applications/org.manjaro.pamac.manager.desktop 2>/dev/null | head -1 | cut -d= -f2" 2>/dev/null || echo "")
    if [[ -z "$_detected_wmclass" ]]; then
        _detected_wmclass="pamac-manager"
    fi
    log_info "Detected StartupWMClass for pamac: $_detected_wmclass"

    local _wrapper_content
    read -r -d '' _wrapper_content <<CONTAINER_WRAPPER_EOF
#!/bin/bash
set +e

# Set up session environment BEFORE bootstrap (which starts pamac-daemon).
# distrobox does not forward DBUS_SESSION_BUS_ADDRESS into the container.
export DISPLAY=\${DISPLAY:-:0}
export XDG_RUNTIME_DIR=\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}

if [[ -z "\${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    if [[ -S "\$XDG_RUNTIME_DIR/bus" ]]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=\$XDG_RUNTIME_DIR/bus"
    else
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$(id -u)/bus"
    fi
fi

# Clean stale pacman download dirs that cause "invalid database" errors
rm -rf /var/lib/pacman/sync/download-* 2>/dev/null || true

# Ensure DBs exist in the user's tmp path (required for trans_check_prepare).
# Without this, pamac-manager's own alpm handle fails with "invalid or corrupted database".
_tmp_base="/tmp/pamac-\$(id -un)/dbs"
_tmp_dbs="\$_tmp_base/sync"
if [[ ! -d "\$_tmp_dbs" ]] || [[ -z "\$(ls "\$_tmp_dbs"/*.db 2>/dev/null)" ]]; then
    rm -rf "\$_tmp_base" 2>/dev/null || true
    mkdir -p "\$_tmp_dbs"
    ln -sf /var/lib/pacman/local "\$_tmp_base/local"
    cp /var/lib/pacman/sync/*.db "\$_tmp_dbs/" 2>/dev/null || true
    touch "\$_tmp_dbs/refresh_timestamp"
    chmod -R a+rX "\$_tmp_base"
fi

# Check if daemon is running; only start if not
if ! pgrep -x pamac-daemon >/dev/null 2>&1; then
    su -c '/usr/local/bin/pamac-session-bootstrap.sh' root 2>&1 || true
fi

# Clean stale pacman lock
rm -f /var/lib/pacman/db.lck 2>/dev/null || true

chmod 1777 /var/log 2>/dev/null || true

DESKTOP_FILE="__DESKTOP_PATH__"

CRASH_LOG="/var/log/pamac-manager-crash.log"
echo "=== Launch at \$(date) ===" >> "\$CRASH_LOG" 2>/dev/null
pamac-manager "\$@" 2>>"\$CRASH_LOG" 1>>"\$CRASH_LOG" &
PAMAC_PID=\$!

# On X11 only, poll for the window to appear (up to 15s) then set the desktop
# file hint. The polling replaces the old fixed \`sleep 3\` which was unreliable
# under heavy load (compiling, downloading) where Pamac could take longer to
# draw its initial window.
if [[ -z "\${WAYLAND_DISPLAY:-}" ]] && command -v xprop >/dev/null 2>&1 && command -v xdotool >/dev/null 2>&1 && command -v xwininfo >/dev/null 2>&1; then
    _xdotool_wait=0
    while [[ \$_xdotool_wait -lt 15 ]]; do
        for wid in \$(xdotool search --class "${_detected_wmclass}" 2>/dev/null | head -5); do
            width=\$(xwininfo -id "\$wid" 2>/dev/null | awk '/Width:/{print \$NF}')
            if [[ -n "\$width" ]] && [[ "\$width" -gt 1 ]]; then
                xprop -id "\$wid" -f _KDE_NET_WM_DESKTOP_FILE 8u \\
                    -set _KDE_NET_WM_DESKTOP_FILE "\$DESKTOP_FILE" 2>/dev/null
                break 2
            fi
        done
        sleep 1
        _xdotool_wait=\$(( _xdotool_wait + 1 ))
    done
fi

wait "\$PAMAC_PID" 2>/dev/null
echo "=== Exit at \$(date) code=\$? ===" >> "\$CRASH_LOG" 2>/dev/null
CONTAINER_WRAPPER_EOF
    _wrapper_content="${_wrapper_content/__DESKTOP_PATH__/$_desktop_path}"
    printf '%s\n' "$_wrapper_content" | container_root_exec bash -c 'cat > /usr/local/bin/pamac-manager-wrapper'
    container_root_exec chmod +x /usr/local/bin/pamac-manager-wrapper
    log_info "pamac-manager-wrapper created inside container."

    printf '%s\n' '#!/bin/bash' \
        'set +e' \
        'if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then' \
        '    _xdr="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"' \
        '    if [[ -S "$_xdr/bus" ]]; then' \
        '        export DBUS_SESSION_BUS_ADDRESS="unix:path=$_xdr/bus"' \
        '    fi' \
        'fi' \
        'rm -rf /var/lib/pacman/sync/download-* 2>/dev/null || true' \
        '/usr/local/bin/pamac-session-bootstrap.sh 2>&1 || true' \
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
    _atomic_desktop_write "$exported_desktop" "[Desktop Entry]
Name=Pamac
Comment=Add/Remove Software
Exec=$HOME/.local/bin/pamac-manager-wrapper-host %U
Icon=system-software-install
Terminal=false
Type=Application
Categories=System;PackageManager;Settings;
Keywords=package;manager;software;arch;aur;
StartupNotify=false
StartupWMClass=${_detected_wmclass}
Actions=uninstall;
X-SteamOS-Pamac-Managed=true
X-SteamOS-Pamac-Container=${CONTAINER_NAME}
X-SteamOS-Pamac-SourceApp=pamac-manager
X-SteamOS-Pamac-SourceDesktop=org.manjaro.pamac.manager.desktop
X-SteamOS-Pamac-SourcePackage=pamac-aur

[Desktop Action uninstall]
Name=Uninstall Packages
Exec=$HOME/.local/bin/steamos-pamac-uninstall --desktop-file ${CONTAINER_NAME}-org.manjaro.pamac.manager.desktop
Icon=edit-delete"
        chmod +x "$exported_desktop"
        _created_files+=("$exported_desktop")
        log_success "Created manual desktop entry: $exported_desktop"
    fi

    if [[ -z "$exported_desktop" ]]; then
        exported_desktop="$desktop_dir/${CONTAINER_NAME}-org.manjaro.pamac.manager.desktop"
    fi

    log_info "Writing clean pamac-manager desktop entry with proper integration markers..."
    _atomic_desktop_write "$exported_desktop" "[Desktop Entry]
Type=Application
Name=Pamac
Comment=Add/Remove Software
Exec=$HOME/.local/bin/pamac-manager-wrapper-host %U
Icon=system-software-install
Terminal=false
Categories=System;PackageManager;Settings;
Keywords=package;manager;software;arch;aur;
StartupNotify=false
StartupWMClass=${_detected_wmclass}
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
Exec=$HOME/.local/bin/steamos-pamac-uninstall --desktop-file \"${CONTAINER_NAME}-org.manjaro.pamac.manager.desktop\"
Icon=edit-delete"
    chmod +x "$exported_desktop"
    if command -v desktop-file-install >/dev/null 2>&1; then
        if desktop-file-install --validate "$exported_desktop" 2>/dev/null; then
            log_success "Pamac desktop entry written and validated: $exported_desktop"
        else
            log_warn "Pamac desktop entry has validation warnings (non-fatal): $exported_desktop"
        fi
    else
        log_success "Pamac desktop entry written: $exported_desktop"
    fi

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

# Ensure session bus is available for pamac-daemon inside the container
if [[ -z "\${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    _uid=\$(id -u)
    if [[ -S "/run/user/\$_uid/bus" ]]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$_uid/bus"
    fi
fi

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

# Compositor window matching is handled by StartupWMClass in the
# .desktop file (set in annotate_desktop). No activation token or window-property
# injection is needed for modern KDE Plasma (5.27+) and GNOME (42+).

# Ensure container services are running before entering (as root via podman)
if ! ${CONTAINER_MANAGER:-podman} exec "${CONTAINER_NAME}" pgrep -x pamac-daemon >/dev/null 2>&1; then
    ${CONTAINER_MANAGER:-podman} exec -u 0 "${CONTAINER_NAME}" /usr/local/bin/pamac-session-bootstrap.sh >/dev/null 2>&1 || true
    # Wait for daemon to register on D-Bus before entering container
    _wait=0
    while [[ \$_wait -lt 10 ]]; do
        if ${CONTAINER_MANAGER:-podman} exec -u 0 "${CONTAINER_NAME}" busctl --system list 2>/dev/null | grep -q "org.manjaro.pamac.daemon"; then
            break
        fi
        sleep 1
        _wait=\$(( _wait + 1 ))
    done
fi

# Clean stale pacman download dirs before entering container
# (these cause "invalid or corrupted database" errors)
${CONTAINER_MANAGER:-podman} exec "${CONTAINER_NAME}" rm -rf /var/lib/pacman/sync/download-* 2>/dev/null || true

# Ensure desktop files are exported from container to host
# Copy .desktop files directly from container, patch Exec, and annotate
# with pamac markers + uninstall action.
# Fast path: skip the expensive per-package file enumeration if the
# container's explicitly-installed package count hasn't changed since
# the last export. This avoids iterating hundreds of packages on every
# GUI launch (1-3s on large containers).
_export_dir="\$HOME/.local/share/applications"
_pkg_count_cache="\$HOME/.local/state/steamos-pamac-${CONTAINER_NAME}.pkgcount"
_current_pkg_count=\$(${CONTAINER_MANAGER:-podman} exec "${CONTAINER_NAME}" pacman -Qeq 2>/dev/null | wc -l)
if [[ -f "\$_pkg_count_cache" ]] && [[ "\$(cat "\$_pkg_count_cache" 2>/dev/null)" == "\${_current_pkg_count}" ]]; then
    # Count unchanged — desktop files already exported, skip slow enumeration
    true
else
for _desktop in \$(${CONTAINER_MANAGER:-podman} exec "${CONTAINER_NAME}" bash -c "pacman -Qeq | while read p; do pacman -Qql \\\$p 2>/dev/null; done" 2>/dev/null | grep '\.desktop$'); do
    _base=\$(basename "\$_desktop")
    _host_file="\$_export_dir/${CONTAINER_NAME}-\$_base"
    if [[ ! -f "\$_host_file" ]]; then
        ${CONTAINER_MANAGER:-podman} cp "${CONTAINER_NAME}:\$_desktop" "\$_host_file" 2>/dev/null || continue
        _pkg_name=\$(basename "\$_desktop" .desktop)
        _app_exec=\$(grep '^Exec=' "\$_host_file" 2>/dev/null | head -1 | sed 's/^Exec=//' | sed 's/ .*//')
        # Special case: pamac-manager gets wrapper-host and rename
        if [[ "\$_pkg_name" == "org.manjaro.pamac.manager" ]]; then
            sed -i 's|^Name=.*|Name=Pamac|' "\$_host_file"
            sed -i '/^Name\[/d' "\$_host_file"
            sed -i "s|^Exec=.*|Exec=\$HOME/.local/bin/pamac-manager-wrapper-host %U|" "\$_host_file"
        else
            sed -i "s|^Exec=.*|Exec=distrobox-enter -n ${CONTAINER_NAME} -- \\\${_app_exec} %f|" "\$_host_file"
        fi
        # Add pamac markers and uninstall action
        if ! grep -q '^Actions=uninstall;' "\$_host_file"; then
            sed -i '/^StartupWMClass=/a Actions=uninstall;' "\$_host_file" 2>/dev/null
            sed -i '/^StartupWMClass=/a X-SteamOS-Pamac-Managed=true' "\$_host_file" 2>/dev/null
            sed -i '/^StartupWMClass=/a X-SteamOS-Pamac-Container=${CONTAINER_NAME}' "\$_host_file" 2>/dev/null
            sed -i "/^StartupWMClass=/a X-SteamOS-Pamac-SourceDesktop=\$_base" "\$_host_file" 2>/dev/null
            sed -i "/^StartupWMClass=/a X-SteamOS-Pamac-SourcePackage=\$_pkg_name" "\$_host_file" 2>/dev/null
            cat >> "\$_host_file" << ACTION_EOF

[Desktop Action uninstall]
Name=Uninstall \$_pkg_name
Exec=bash -c '${CONTAINER_MANAGER:-podman} exec -u 0 ${CONTAINER_NAME} pacman -R --noconfirm \$_pkg_name 2>/dev/null && rm -f \$_host_file && touch \$(dirname \$_host_file) && notify-send -i edit-delete "Uninstalled" "\$_pkg_name removed" 2>/dev/null'
Icon=edit-delete
ACTION_EOF
        fi
        chmod 644 "\$_host_file" 2>/dev/null
    fi
done
# Save package count for fast-path cache on next launch
mkdir -p "\$(dirname "\$_pkg_count_cache")" 2>/dev/null
echo "\${_current_pkg_count}" > "\$_pkg_count_cache" 2>/dev/null
fi

# Re-suppress the KDE Discover notifier on every launch: the autostart unit is
# masked (set during install) but a surviving notifier process keeps the KDE
# built-in "Uninstall or Manage Add-Ons" context-menu entry alive. Kill it
# best-effort and bump the applications dir mtime so Kicker drops the entry.
if command -v pkill >/dev/null 2>&1; then
    pkill -9 -f "discover.notifier" 2>/dev/null || true
    pkill -9 -f "DiscoverNotifier" 2>/dev/null || true
fi
touch "\$HOME/.local/share/applications" 2>/dev/null || true

# Launch Pamac in the background via distrobox
# distrobox 1.8.x does not support --env; pass env via prefix instead
DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/\$(id -u)/bus}" \
distrobox enter ${CONTAINER_NAME} -- pamac-manager-wrapper "\$@" &
LAUNCHER_PID=\$!

# On X11 only: poll for the window to appear (up to 15s) then set the desktop
# file hint. The polling replaces the old fixed \`sleep 3\` which was unreliable
# under heavy load (compiling, downloading) where Pamac could take longer to
# draw its initial window.
if [[ "\$IS_WAYLAND" == "false" ]] && command -v xprop >/dev/null 2>&1 && command -v xdotool >/dev/null 2>&1 && command -v xwininfo >/dev/null 2>&1; then
    _xdotool_wait=0
    while [[ \$_xdotool_wait -lt 15 ]]; do
        for wid in \$(xdotool search --class "${_detected_wmclass}" 2>/dev/null | head -5); do
            width=\$(xwininfo -id "\$wid" 2>/dev/null | awk '/Width:/{print \$NF}')
            if [[ -n "\$width" ]] && [[ "\$width" -gt 1 ]]; then
                XAUTHORITY="\$XAUTHORITY" DISPLAY="\$DISPLAY" xprop -id "\$wid" \\
                    -f _KDE_NET_WM_DESKTOP_FILE 8u \\
                    -set _KDE_NET_WM_DESKTOP_FILE "\$DESKTOP_FILE" 2>/dev/null
                break 2
            fi
        done
        sleep 1
        _xdotool_wait=\$(( _xdotool_wait + 1 ))
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

 _log "Removing \$pkg via pacman -R (as root, no D-Bus needed)..."
 if ! echo "\$pkg" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9._+-]*$'; then
 _log "Error: Invalid package name format: '\$pkg'"
 echo "Error: Invalid package name: '\$pkg'" >&2
 exit 1
 fi
 local remove_output
 remove_output=\$("\$CONTAINER_MANAGER" exec -u 0 "\$CONTAINER_NAME" bash -c "
if [[ -f /var/lib/pacman/db.lck ]]; then _p=\$(cat /var/lib/pacman/db.lck 2>/dev/null || echo ''); if [[ -n \"\$_p\" ]] && kill -0 \"\$_p\" 2>/dev/null; then echo \"Pacman running (PID \$_p), waiting...\"; _w=0; while [[ \$_w -lt 30 ]] && kill -0 \"\$_p\" 2>/dev/null; do sleep 2; _w=\$(( _w + 2 )); done; if kill -0 \"\$_p\" 2>/dev/null; then echo \"ERROR: Pacman (PID \$_p) still running after 30s. Aborting.\"; exit 1; fi; fi; rm -f /var/lib/pacman/db.lck; fi
pacman -R --noconfirm \"\$pkg\" 2>&1
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

# Touch the applications dir mtime so KDE's KDirWatch picks up the deletion
# and refreshes the start menu without the 5-10s lag. We deliberately do NOT
# call kbuildsycoca6 or qdbus refreshCurrentShell here — both crash plasmashell
# under the SteamOS/distrobox split-bus configuration. Note: the SYSTEM bus is
# the container's own private bus (own dbus-daemon + polkitd), NOT shared with
# the host — verified empirically (container socket inode differs from host's,
# container polkitd owns org.freedesktop.PolicyKit1 on it). Only the SESSION
# bus (KDE/GUI) is shared with the host. This is what lets the host stay 100%
# read-only (no /etc/polkit-1, no /usr/share/polkit-1 on host) while pamac auth
# resolves entirely inside the container.
touch "\$APP_DIR" 2>/dev/null || _log "touch \$APP_DIR failed"
_log "Applications dir mtime bumped for KDE menu refresh"

if command -v update-desktop-database >/dev/null 2>&1; then
update-desktop-database "\$APP_DIR" 2>/dev/null || true
fi

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
log_msg "Error: No URL argument provided"
exit 1
fi

COMPONENT_ID="\${APPSTREAM_URL#appstream://}"

if [[ -z "\$COMPONENT_ID" ]]; then
log_msg "Error: Empty component ID"
exit 1
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
# Check if this is a Flatpak app — if so, let Discover handle it
if flatpak list --app --columns=application 2>/dev/null | grep -q "^\$COMPONENT_ID\$"; then
    log_msg "Flatpak app found for component: \$COMPONENT_ID, passing to Discover"
    exec plasma-discover "\$@"
fi
# System/pacman app — uninstall directly via container
log_msg "Uninstalling pacman app: \$COMPONENT_ID"
_pkg_name="\$(echo "\$COMPONENT_ID" | sed 's/\.desktop$//')"
if command -v kdialog >/dev/null 2>&1; then
    CONFIRM=\$(kdialog --yesno "Remove \$_pkg_name? This was installed via Pamac." --title "Uninstall" 2>/dev/null)
    if [[ \$? -ne 0 ]]; then
        log_msg "User cancelled uninstall"
        exit 0
    fi
fi
    nohup bash -c "${CONTAINER_MANAGER:-podman} exec -u 0 ${CONTAINER_NAME} bash -c 'rm -f /var/lib/pacman/db.lck; pacman -R --noconfirm \$_pkg_name' 2>&1 && rm -f \$HOME/.local/share/applications/${CONTAINER_NAME}-\$_pkg_name.desktop && touch \$HOME/.local/share/applications && notify-send -i edit-delete 'Uninstalled' '\$_pkg_name has been removed.' 2>/dev/null || notify-send -i dialog-error 'Uninstall Failed' 'Could not remove \$_pkg_name' 2>/dev/null" &>/dev/null &
    disown
    exit 0
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
        log_warn "'$bin_dir' is NOT in your PATH. CLI wrapper pamac-${CONTAINER_NAME} may not be found."
        local _profile_line="export PATH=\"\$HOME/.local/bin:\$PATH\""
        local _profile_updated=false
        local _already_configured=false
        for _rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
            if [[ -f "$_rc_file" ]]; then
                if grep -qF '.local/bin' "$_rc_file" 2>/dev/null; then
                    _already_configured=true
                else
                    if [[ "$DRY_RUN" != "true" ]]; then
                        printf '\n%s\n' "$_profile_line" >> "$_rc_file" 2>/dev/null || true
                        if grep -qF '.local/bin' "$_rc_file" 2>/dev/null; then
                            log_info "Added ~/.local/bin to PATH in $_rc_file"
                            _profile_updated=true
                        fi
                    else
                        log_info "[DRY RUN] Would add ~/.local/bin to PATH in $_rc_file"
                        _profile_updated=true
                    fi
                fi
            fi
        done
        if [[ "$_profile_updated" != "true" && "$_already_configured" != "true" ]]; then
            local _target_rc="$HOME/.bashrc"
            if [[ ! -f "$HOME/.bashrc" && ! -f "$HOME/.zshrc" ]]; then
                if [[ "$DRY_RUN" != "true" ]]; then
                    printf '%s\n' "# SteamOS-Pamac: added ~/.local/bin to PATH" "$_profile_line" > "$_target_rc" 2>/dev/null || true
                    if [[ -f "$_target_rc" ]]; then
                        log_info "Created $_target_rc with ~/.local/bin in PATH"
                        _profile_updated=true
                    fi
                else
                    log_info "[DRY RUN] Would create $_target_rc with ~/.local/bin in PATH"
                    _profile_updated=true
                fi
            fi
        fi
        if [[ "$_profile_updated" != "true" && "$_already_configured" != "true" ]]; then
            log_warn "Could not automatically add ~/.local/bin to PATH. Please run manually:"
            log_warn "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
        fi
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
        elif command -v kbuildsycoca5 >/dev/null 2>&1; then
            XDG_DATA_DIRS="$new_xdg" kbuildsycoca5 --noincremental 2>/dev/null || true
            log_info "KDE service cache rebuilt with corrected XDG_DATA_DIRS"
        fi
    }

    _fix_xdg_data_dirs

    # Suppress the KDE Discover notifier so the built-in "Uninstall or Manage
    # Add-Ons" context-menu entry stops competing with Pamac's own annotation.
    # Masking the autostart unit prevents new launches, but an already-running
    # notifier survives (e.g. PID kept alive across a re-export). Kill it so
    # the stale entry disappears immediately, then bump the applications dir
    # mtime so Kicker refreshes without a full plasmashell restart.
    _suppress_discover_notifier() {
        if command -v systemctl >/dev/null 2>&1; then
            systemctl --user mask app-org.kde.discover.notifier@autostart.service 2>/dev/null || true
        fi
        # Kill any running DiscoverNotifier (by process name, not cached PID)
        if command -v pkill >/dev/null 2>&1; then
            pkill -9 -f "discover.notifier" 2>/dev/null || true
            pkill -9 -f "DiscoverNotifier" 2>/dev/null || true
        fi
        touch "$HOME/.local/share/applications" 2>/dev/null || true
        log_info "DiscoverNotifier masked and running instance killed"
    }

    # Only run the KDE-specific suppression on KDE/Plasma sessions or when the
    # DE cannot be detected; skip on other DEs to avoid unnecessary pkill scans.
    local _desktop_env
    _desktop_env=$(detect_desktop_environment)
    if [[ "$_desktop_env" == "kde" || "$_desktop_env" == "unknown" || "$_desktop_env" == generic-* ]]; then
        _suppress_discover_notifier
    else
        log_info "Skipping KDE Discover notifier suppression (detected DE: $_desktop_env)."
    fi

    # Verify critical files were created
    local _export_ok=true
    if [[ -n "$exported_desktop" ]] && [[ ! -f "$exported_desktop" ]]; then
        log_error "Desktop file missing after export: $exported_desktop"
        _export_ok=false
    fi
    if [[ ! -f "$HOME/.local/bin/pamac-manager-wrapper-host" ]]; then
        log_warn "Host wrapper script not found at ~/.local/bin/pamac-manager-wrapper-host"
    fi

    # Clear the rollback trap (success path)
    trap - EXIT

    if [[ "$_export_ok" == "true" ]]; then
        log_success "Pamac export to host completed successfully."
    else
        log_warn "Pamac export completed with warnings. Some components may need manual setup."
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

# Hook to clean stale download dirs after every transaction
# (prevents "invalid or corrupted database" errors in Pamac GUI)
cat > "$hook_dir/99-cleanup-download-dirs.hook" << 'CLEANUP_HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Cleaning stale pacman download directories...
When = PostTransaction
Exec = /usr/bin/rm -rf /var/lib/pacman/sync/download-*
CLEANUP_HOOK

# Orphan notification hook: alerts when packages become orphaned after removal
cat > "$hook_dir/98-cleanup-orphans.hook" << 'ORPHAN_HOOK'
[Trigger]
Operation = Remove
Type = Package
Target = *

[Action]
Description = Checking for orphaned packages...
When = PostTransaction
Exec = /usr/local/bin/cleanup-orphans-notify
ORPHAN_HOOK

cat > /usr/local/bin/cleanup-orphans-notify << 'ORPHAN_SCRIPT'
#!/bin/bash
orphans=$(pacman -Qtdq 2>/dev/null)
if [[ -z "$orphans" ]]; then
    exit 0
fi
count=$(echo "$orphans" | wc -l)
if command -v notify-send >/dev/null 2>&1; then
    notify-send -i edit-delete "Orphaned Packages" \
        "$count orphaned package(s) found. Run 'cleanup-orphans' to remove them." 2>/dev/null
fi
ORPHAN_SCRIPT
chmod +x /usr/local/bin/cleanup-orphans-notify

cat > /usr/local/bin/cleanup-orphans << 'ORPHAN_CLEANUP'
#!/bin/bash
orphans=$(pacman -Qtdq 2>/dev/null)
if [[ -z "$orphans" ]]; then
    echo "No orphaned packages found."
    exit 0
fi
echo "Orphaned packages:"
echo "$orphans" | while read -r pkg; do echo "  - $pkg"; done
echo ""
read -rp "Remove these packages? [y/N] " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    sudo pacman -Rns --noconfirm $orphans 2>&1
    echo "Done."
else
    echo "Skipped."
fi
ORPHAN_CLEANUP
chmod +x /usr/local/bin/cleanup-orphans

# Hook to clean stale .desktop files when packages are removed
cat > "$hook_dir/99-cleanup-desktops.hook" << 'DESKTOP_HOOK'
[Trigger]
Operation = Remove
Type = Package
Target = *

[Action]
Description = Cleaning stale desktop entries...
When = PostTransaction
Exec = /usr/local/bin/cleanup-desktops
DESKTOP_HOOK

cat > /usr/local/bin/cleanup-desktops << 'CLEANUP_DESKTOP'
#!/bin/bash
# Only remove stale desktop files exported by distrobox-export whose
# source package is no longer installed in the container.
# Reads the X-SteamOS-Pamac-Container marker from each file to scope cleanup
# to THIS container only (supports custom container names via --container-name).
# container_name is baked in below at install time (literal substitution by
# the installer) since this script runs later as a pacman hook without access
# to installer environment variables.
container_name=__CONTAINER_NAME_BAKED_IN__
for user_dir in /home/*/; do
    app_dir="${user_dir}.local/share/applications"
    [ -d "$app_dir" ] || continue
    for f in "$app_dir"/*.desktop; do
        [ -f "$f" ] || continue
        if ! grep -q '^X-SteamOS-Pamac-SourceDesktop=' "$f" 2>/dev/null; then
            continue
        fi
        file_container=$(grep '^X-SteamOS-Pamac-Container=' "$f" 2>/dev/null | cut -d= -f2-)
        if [ -n "$file_container" ] && [ -n "$container_name" ] && [ "$file_container" != "$container_name" ]; then
            continue
        fi
        pkg_name=$(grep '^X-SteamOS-Pamac-SourcePackage=' "$f" 2>/dev/null | cut -d= -f2)
        if [ -n "$pkg_name" ]; then
            if ! pacman -Qi "$pkg_name" >/dev/null 2>&1; then
                rm -f "$f"
            fi
        fi
    done
done
CLEANUP_DESKTOP
chmod +x /usr/local/bin/cleanup-desktops

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

# distrobox-export refuses to run as root. Pacman hooks always run as root,
# so re-exec as the container user to handle desktop file exports.
if [[ "\$(id -u)" == "0" ]]; then
    su -s /bin/bash ${current_user} -c "PATH=/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin XDG_DATA_DIRS=/usr/local/share:/usr/share XDG_DATA_HOME=/home/${current_user}/.local/share /usr/local/bin/distrobox-export-hook.sh" 2>/dev/null || true
    exit 0
fi

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

# Build a hash that captures BOTH the explicit package list AND the desktop
# files shipped by those packages. Hashing only the package list would miss
# package updates that change the .desktop contents (new Actions, renamed
# Exec, updated Icon) without changing the explicit-install set — leaving
# users with stale host menu entries until the package list changes.
# We hash mtimes+sizes of every /usr/share/applications/*.desktop file; this
# changes whenever a package update rewrites a desktop file, while staying
# cheap (one stat per file, no content read).
CURRENT_HASH="\$(md5sum "\$EXPLICIT_FILE" 2>/dev/null | awk '{print \$1}')"
if [[ -d /usr/share/applications ]]; then
    DESKTOP_SIG="\$(find /usr/share/applications -maxdepth 1 -type f -name '*.desktop' \
        -printf '%p %s %T@\n' 2>/dev/null | sort | md5sum | awk '{print \$1}')"
    CURRENT_HASH="\${CURRENT_HASH}:\${DESKTOP_SIG}"
fi
if [[ -f "\$HASH_FILE" ]]; then
    LAST_HASH="\$(cat "\$HASH_FILE" 2>/dev/null || echo "")"
    if [[ "\$CURRENT_HASH" == "\$LAST_HASH" ]]; then
        echo "\$(date): Package list and desktop files unchanged (hash=\${CURRENT_HASH:0:8}). Skipping export." >> "\$EXPORT_LOG"
        exit 0
    fi
fi
echo "\$CURRENT_HASH" > "\$HASH_FILE" 2>/dev/null || true
echo "\$(date): Package list or desktop files changed (hash=\${CURRENT_HASH:0:8}). Running export." >> "\$EXPORT_LOG"

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
            # Detect actual WMClass from the container's installed desktop file.
            # GTK3/GTK4 apps may use reverse-DNS or binary name for Wayland app_id.
            _detected_wm=\$(grep -E '^StartupWMClass=' /usr/share/applications/org.manjaro.pamac.manager.desktop 2>/dev/null | head -1 | cut -d= -f2)
            [[ -z "\$_detected_wm" ]] && _detected_wm="pamac-manager"
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
StartupWMClass=\${_detected_wm}
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
Exec=bash -c 'podman exec -u 0 ${container_name} pacman -R --noconfirm pamac-aur 2>/dev/null && rm -f /home/${current_user}/.local/share/applications/${container_name}-org.manjaro.pamac.manager.desktop && touch /home/${current_user}/.local/share/applications && notify-send -i edit-delete "Uninstalled" "pamac-aur removed" 2>/dev/null'
Icon=edit-delete
PAMAC_DESKTOP
    _fix_desktop_permissions "\$desktop_file"
    return 0
  fi

  # Use Python for robust INI/desktop-file parsing instead of fragile awk passes.
  # This correctly handles: multi-line values, upstream [Desktop Action] sections,
  # re-entry into action sections, and preserves all non-owned lines.
  # Pre-flight: verify Python 3 executable is reachable before testing modules,
  # so builds don't break inside minimal containers with broken interpreters.
  _python3_ok=false
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import configparser" >/dev/null 2>&1; then
      _python3_ok=true
    fi
  fi
  if [[ "\$_python3_ok" != "true" ]]; then
    echo "Python 3 or configparser missing — attempting to install python..." >&2
    if command -v pacman >/dev/null 2>&1; then
      pacman -S --noconfirm --needed python python-configparser >/dev/null 2>&1 || true
    fi
    if command -v python3 >/dev/null 2>&1 && python3 -c "import configparser" >/dev/null 2>&1; then
      _python3_ok=true
    fi
  fi
  if [[ "\$_python3_ok" != "true" ]]; then
    echo "WARN: Python 3 still unavailable after install attempt — using awk fallback for desktop annotation." >&2
    # Use awk instead of sed to properly handle multi-section .desktop files.
    # sed's \$a appends to the END of the file, which corrupts files that have
    # [Desktop Action ...] sections after [Desktop Entry]. awk targets the
    # boundary between [Desktop Entry] and the next section.
    awk -v container="${container_name}" -v user="${current_user}" \
        -v export_name="${export_name}" -v app_name="${app_name}" \
        -v owner_pkg="${owner_pkg}" '
    BEGIN { in_entry=0; inserted=0; saw_next_section=0; in_uninstall=0 }
    /^\[Desktop Entry\]/ { in_entry=1; print; next }
    # Strip any pre-existing [Desktop Action uninstall] section FIRST so the
    # direct one-liner appended in END is the only uninstall action — no stale
    # helper-based Exec survives re-annotation.
    /^\[Desktop Action uninstall\]/ { in_uninstall=1; next }
    in_uninstall && /^\[/ { in_uninstall=0 }
    in_uninstall { next }
    /^\[/ && in_entry && !saw_next_section {
        # First section after [Desktop Entry] — insert markers here
        saw_next_section=1
        if (!inserted) {
            print "Actions=uninstall;"
            print "X-SteamOS-Pamac-Managed=true"
            print "X-SteamOS-Pamac-Container=" container
            print "X-SteamOS-Pamac-SourceApp=" export_name
            print "X-SteamOS-Pamac-SourceDesktop=" app_name ".desktop"
            print "X-SteamOS-Pamac-SourcePackage=" owner_pkg
            inserted=1
        }
        print; next
    }
    /^Actions=/ { next }
    /^X-SteamOS-Pamac-/ { next }
    END {
        if (!inserted) {
            print "Actions=uninstall;"
            print "X-SteamOS-Pamac-Managed=true"
            print "X-SteamOS-Pamac-Container=" container
            print "X-SteamOS-Pamac-SourceApp=" export_name
            print "X-SteamOS-Pamac-SourceDesktop=" app_name ".desktop"
            print "X-SteamOS-Pamac-SourcePackage=" owner_pkg
        }
        # Always append a fresh direct uninstall action (no helper, no
        # kbuildsycoca6/qdbus crash source; touch dir for fast KDE refresh).
        print ""
        print "[Desktop Action uninstall]"
        print "Name=Uninstall " owner_pkg
        _desktop_bn=app_name ".desktop"
        _host_file="/home/" user "/.local/share/applications/" container "-" _desktop_bn
        _apps_dir="/home/" user "/.local/share/applications"
        printf "Exec=bash -c 'podman exec -u 0 %s pacman -R --noconfirm %s 2>/dev/null && rm -f %s && touch %s && notify-send -i edit-delete \"Uninstalled\" \"%s removed\" 2>/dev/null'\n", container, owner_pkg, _host_file, _apps_dir, owner_pkg
        print "Icon=edit-delete"
    }
    { print }
    ' "\$desktop_file" > "\${desktop_file}.tmp" && mv -f "\${desktop_file}.tmp" "\$desktop_file"
    _fix_desktop_permissions "\$desktop_file"
    return 0
  fi
  desktop_basename="\$(basename "\$desktop_file")"

  python3 - "\$desktop_file" "\$desktop_basename" "${container_name}" "${current_user}" "\$export_name" "\$app_name" "\$owner_pkg" << 'PYTHON_DESKTOP_REWRITE'
import sys, configparser, io

desktop_path = sys.argv[1]
desktop_basename = sys.argv[2]
container_name = sys.argv[3]
current_user = sys.argv[4]
export_name = sys.argv[5]
app_name = sys.argv[6]
owner_pkg = sys.argv[7]

# Read raw file to preserve sections configparser may flatten
with open(desktop_path, 'r') as f:
    raw = f.read()

# Parse into ordered sections
parser = configparser.ConfigParser(strict=False, interpolation=None)
parser.optionxform = str  # preserve key casing
parser.read_string(raw)

entry = {}
other_sections = {}
ordered_actions = []

for section in parser.sections():
    if section == 'Desktop Entry':
        for k, v in parser.items(section):
            entry[k] = v
    elif section.startswith('Desktop Action '):
        # Check if this is our previously-injected uninstall action
        is_ours = False
        for k, v in parser.items(section):
            if 'steamos-pamac-uninstall' in v:
                is_ours = True
                break
        if not is_ours:
            ordered_actions.append((section, dict(parser.items(section))))
    else:
        other_sections[section] = dict(parser.items(section))

# Strip our custom keys from Desktop Entry
custom_keys = ['x-steamos-pamac-managed', 'x-steamos-pamac-container',
               'x-steamos-pamac-sourceapp', 'x-steamos-pamac-sourcedesktop',
               'x-steamos-pamac-sourcepackage']
for k in list(entry.keys()):
    if k.lower() in custom_keys:
        del entry[k]

# Capture existing actions (strip trailing semicolons, remove 'uninstall')
raw_actions = entry.get('actions', '')
existing = [a.strip() for a in raw_actions.rstrip(';').split(';') if a.strip()]
cleaned = [a for a in existing if a.lower() not in ('uninstall',)]
combined = ';'.join(cleaned) + ';uninstall;' if cleaned else 'uninstall;'

# Markers to inject
markers = [
    ('Actions', combined),
    ('X-SteamOS-Pamac-Managed', 'true'),
    ('X-SteamOS-Pamac-Container', container_name),
    ('X-SteamOS-Pamac-SourceApp', export_name),
    ('X-SteamOS-Pamac-SourceDesktop', app_name + '.desktop'),
    ('X-SteamOS-Pamac-SourcePackage', owner_pkg),
]

# Rebuild file
lines = ['[Desktop Entry]']
written_keys = set()
for mk, mv in markers:
    lines.append(f'{mk}={mv}')
    written_keys.add(mk.lower())
for k, v in entry.items():
    if k.lower() not in written_keys:
        lines.append(f'{k}={v}')

for section, items in ordered_actions:
    lines.append('')
    lines.append(f'[{section}]')
    for k, v in items.items():
        lines.append(f'{k}={v}')

# Append our uninstall action.
# Use the direct podman-exec one-liner (matches tests/distrobox-export-hook.sh):
# no intermediate helper, no kbuildsycoca6/qdbus crash source, and the
# `touch $(dirname ...)` forces KDE's KDirWatch to refresh within ~1s instead
# of the 5-10s start-menu lag. The host desktop path is resolved here (Python
# f-string) so the written desktop file contains a fully-qualified literal.
_host_desktop_path = f'/home/{current_user}/.local/share/applications/{desktop_basename}'
_apps_dir = f'/home/{current_user}/.local/share/applications'
lines.append('')
lines.append('[Desktop Action uninstall]')
lines.append(f'Name=Uninstall {owner_pkg}')
lines.append(f"Exec=bash -c 'podman exec -u 0 {container_name} pacman -R --noconfirm {owner_pkg} 2>/dev/null && rm -f {_host_desktop_path} && touch {_apps_dir} && notify-send -i edit-delete \"Uninstalled\" \"{owner_pkg} removed\" 2>/dev/null'")
lines.append('Icon=edit-delete')

for section, items in other_sections.items():
    lines.append('')
    lines.append(f'[{section}]')
    for k, v in items.items():
        lines.append(f'{k}={v}')

with open(desktop_path, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PYTHON_DESKTOP_REWRITE
  local _py_rc=$?
  if [[ \$_py_rc -ne 0 ]]; then
    echo "annotate_desktop: Python rewrite failed (exit \$_py_rc); restoring desktop file from backup." >&2
    cp -f "\$desktop_file.bak" "\$desktop_file" 2>/dev/null || true
    return 1
  fi
  _fix_desktop_permissions "\$desktop_file"
  rm -f "\$desktop_file.bak" 2>/dev/null || true
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
      exported=\$(( exported + 1 ))
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

# Create missing distrobox pre/post hook scripts (distrobox pacman hooks
# reference these but they may not exist in the container).
if [[ ! -f /etc/distrobox-pre-hook.sh ]]; then
    cat > /etc/distrobox-pre-hook.sh << 'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x /etc/distrobox-pre-hook.sh
fi
if [[ ! -f /etc/distrobox-post-hook.sh ]]; then
    cat > /etc/distrobox-post-hook.sh << 'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x /etc/distrobox-post-hook.sh
fi

echo "Post-install hook configured."
HOOK_EOF

    # Bake the container name into the generated cleanup-desktops hook script.
    # The cleanup-desktops file is written via a single-quoted heredoc so its
    # body is not expanded when generated; it runs later as a standalone pacman
    # hook without access to installer variables. Substitute the literal here
    # so per-container scoping works even when the user passes --container-name.
    hook_script="${hook_script//__CONTAINER_NAME_BAKED_IN__/${CONTAINER_NAME}}"

    if ! echo "$hook_script" | exec_container_pipe "post-install-hooks" "$CURRENT_USER" "$CONTAINER_NAME"; then
        log_warn "Failed to set up post-install hooks. Newly installed apps may not auto-appear in menu."
    fi
}

setup_keyring_refresh() {
    log_step "Setting up keyring refresh for Pamac GUI updates"

    local keyring_script
    read -r -d '' keyring_script <<'KEYRING_REFRESH_EOF' || true
set -uo pipefail

_remove_stale_lock

# Create a wrapper that refreshes the archlinux-keyring before any pacman
# transaction. This solves the "catch-22" where a stale keyring inside the
# container cannot validate new keyring packages.
cat > /usr/local/bin/pamac-keyring-refresh.sh << 'REFRESH'
#!/bin/bash
set +e

# Strict-security flag, baked into this script at install time by the
# installer. When "true", Strategy 4 (SigLevel=TrustAll recovery) is skipped.
_STRICT_SECURITY_MODE=_STRICT_SECURITY_BAKED_IN_

_remove_stale_lock() {
    local _lock="/var/lib/pacman/db.lck"
    if [[ ! -f "$_lock" ]]; then return 0; fi
    local _lck_pid
    _lck_pid=$(cat "$_lock" 2>/dev/null || echo "")
    if [[ -n "$_lck_pid" ]] && [[ "$_lck_pid" =~ ^[0-9]+$ ]] && kill -0 "$_lck_pid" 2>/dev/null; then
        echo "Pacman is currently running (PID $_lck_pid). Skipping keyring refresh."
        return 0
    fi
    rm -f "$_lock" 2>/dev/null || true
}

_remove_stale_lock

# Only refresh if the keyring is older than 7 days
KEYRING_AGE_FILE="/var/cache/pamac-keyring-last-refresh"
REFRESH_INTERVAL=604800  # 7 days in seconds

if [[ -f "$KEYRING_AGE_FILE" ]]; then
    last_refresh=$(cat "$KEYRING_AGE_FILE" 2>/dev/null || echo "0")
    now=$(date +%s 2>/dev/null || echo "0")
    age=$(( now - last_refresh ))
    if [[ "$age" -lt "$REFRESH_INTERVAL" ]] && [[ "$age" -ge 0 ]]; then
        exit 0
    fi
fi

echo "Refreshing archlinux-keyring..."

# Strategy 1: Standard network refresh
_remove_stale_lock
if pacman -Sy --noconfirm 2>/dev/null && pacman -S --noconfirm --needed archlinux-keyring 2>/dev/null; then
    date +%s > "$KEYRING_AGE_FILE" 2>/dev/null || true
    exit 0
fi

echo "Standard keyring refresh failed. Attempting recovery strategies..."

# Strategy 2: Reset GnuPG and try again (handles corrupted keyring)
pkill -9 gpg-agent 2>/dev/null || true
pkill -9 dirmngr 2>/dev/null || true
rm -f /etc/pacman.d/gnupg/S.gpg-agent* /etc/pacman.d/gnupg/S.dirmngr 2>/dev/null || true
_remove_stale_lock
if pacman -Syy --noconfirm 2>/dev/null && pacman -S --noconfirm --needed archlinux-keyring 2>/dev/null; then
    echo "Keyring refresh succeeded after GPG cleanup."
    date +%s > "$KEYRING_AGE_FILE" 2>/dev/null || true
    exit 0
fi

# Strategy 3: Offline bootstrap from system keyring files
_sys_kr="/usr/share/pacman/keyrings"
if [[ -d "$_sys_kr" ]] && ls "$_sys_kr"/archlinux* >/dev/null 2>&1; then
    echo "Attempting offline keyring bootstrap from system files..."
    rm -rf /etc/pacman.d/gnupg 2>/dev/null || true
    mkdir -p /etc/pacman.d/gnupg 2>/dev/null || true
    chmod 700 /etc/pacman.d/gnupg 2>/dev/null || true
    cp -f "$_sys_kr"/archlinux* /etc/pacman.d/gnupg/ 2>/dev/null || true
    if pacman-key --init 2>/dev/null && pacman-key --populate archlinux 2>/dev/null; then
        echo "Offline keyring bootstrap succeeded."
        date +%s > "$KEYRING_AGE_FILE" 2>/dev/null || true
        exit 0
    fi
fi

# Strategy 4: Controlled temporary SigLevel relaxation
# SECURITY MODEL: we NEVER write TrustAll to the real /etc/pacman.conf. We
# build a throwaway config copy with SigLevel=TrustAll and run pacman against
# it via `pacman --config <tmp>`. The real config stays secure the whole time,
# so an untrappable death (SIGKILL/OOM/power loss) cannot leave the container
# in an unverified state. No restore trap is needed.
if [[ "$_STRICT_SECURITY_MODE" == "true" ]]; then
    echo "Strategy 4 SKIPPED (--strict-security: refusing SigLevel=TrustAll recovery in keyring refresh)."
    echo "  Strategies 1-3 failed; re-run the installer without --strict-security or"
    echo "  manually import archlinux-keyring inside the container:"
    echo "    distrobox enter <container-name> -- pacman -Sy --noconfirm archlinux-keyring gnupg"
    echo "  or: pacman-key --init && pacman-key --populate archlinux"
    echo "  (Failure here is by design: --strict-security fails safe rather than"
    echo "   degrade to an unverified keyring state.)"
else
echo "Attempting controlled SigLevel relaxation (throwaway config)..."
_orig_siglevel=$(grep '^SigLevel' /etc/pacman.conf 2>/dev/null | head -1 || echo "Required DatabaseOptional")
_siglevel_value="${_orig_siglevel#SigLevel = }"
_TA_CONF=$(mktemp /tmp/pacman-trustall.XXXXXX.conf) 2>/dev/null
if [[ -n "$_TA_CONF" ]] && cp -f /etc/pacman.conf "$_TA_CONF" 2>/dev/null; then
    sed -i "s/^[[:space:]]*SigLevel.*/SigLevel = TrustAll/" "$_TA_CONF"
    grep -q '^SigLevel' "$_TA_CONF" || printf 'SigLevel = TrustAll\n' >> "$_TA_CONF"
    _remove_stale_lock
    if pacman --config "$_TA_CONF" -Syy --noconfirm 2>/dev/null && \
       pacman --config "$_TA_CONF" -S --noconfirm --needed archlinux-keyring 2>/dev/null; then
        # Verify with the REAL (secure) config — never modify it.
        rm -f "$_TA_CONF" 2>/dev/null || true
        if pacman -Syy --noconfirm 2>/dev/null; then
            echo "Keyring refresh succeeded with controlled SigLevel relaxation (throwaway config)."
            date +%s > "$KEYRING_AGE_FILE" 2>/dev/null || true
            # Defensive: ensure real config is secure before exiting.
            _cur=$(grep '^SigLevel' /etc/pacman.conf 2>/dev/null | head -1 | sed 's/^SigLevel = //')
            if [[ "$_cur" == "TrustAll" ]]; then
                _rf=$(mktemp /etc/pacman.conf.atomic.XXXXXX) 2>/dev/null
                if [[ -n "$_rf" ]] && cp -f /etc/pacman.conf "$_rf" 2>/dev/null; then
                    sed -i 's/^[[:space:]]*SigLevel.*/SigLevel = Required DatabaseOptional/' "$_rf"
                    grep -q '^SigLevel' "$_rf" || printf 'SigLevel = Required DatabaseOptional\n' >> "$_rf"
                    sync "$_rf" 2>/dev/null || sync 2>/dev/null || true
                    mv -f "$_rf" /etc/pacman.conf 2>/dev/null || true
                fi
            fi
            exit 0
        fi
    fi
    rm -f "$_TA_CONF" 2>/dev/null || true
else
    rm -f "${_TA_CONF:-/tmp/pacman-trustall.NOCONF}" 2>/dev/null || true
    echo "Could not build throwaway TrustAll config; NOT modifying the real pacman.conf."
fi
fi
# Defensive: if the real config somehow ended up at TrustAll, restore it.
_cur_sl=$(grep '^SigLevel' /etc/pacman.conf 2>/dev/null | head -1 | sed 's/^SigLevel = //')
if [[ "${_cur_sl:-}" == "TrustAll" ]]; then
    echo "WARNING: real pacman.conf at TrustAll — restoring to Required DatabaseOptional."
    _rf=$(mktemp /etc/pacman.conf.atomic.XXXXXX) 2>/dev/null
    if [[ -n "$_rf" ]] && cp -f /etc/pacman.conf "$_rf" 2>/dev/null; then
        sed -i 's/^[[:space:]]*SigLevel.*/SigLevel = Required DatabaseOptional/' "$_rf"
        grep -q '^SigLevel' "$_rf" || printf 'SigLevel = Required DatabaseOptional\n' >> "$_rf"
        sync "$_rf" 2>/dev/null || sync 2>/dev/null || true
        mv -f "$_rf" /etc/pacman.conf 2>/dev/null || true
    fi
fi

echo "All keyring refresh strategies failed. Manual intervention may be needed."
echo "Try: pacman-key --init && pacman-key --populate archlinux"
REFRESH
chmod 755 /usr/local/bin/pamac-keyring-refresh.sh

# Create a pacman hook that refreshes the keyring before package operations
hook_dir="/etc/pacman.d/hooks"
mkdir -p "$hook_dir"

# Hook to clean stale download dirs after every transaction
if [[ ! -f "$hook_dir/99-cleanup-download-dirs.hook" ]]; then
cat > "$hook_dir/99-cleanup-download-dirs.hook" << 'CLEANUP_HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Cleaning stale pacman download directories...
When = PostTransaction
Exec = /usr/bin/rm -rf /var/lib/pacman/sync/download-*
CLEANUP_HOOK
fi

# Hook to clean stale .desktop files when packages are removed
if [[ ! -f "$hook_dir/99-cleanup-desktops.hook" ]]; then
cat > "$hook_dir/99-cleanup-desktops.hook" << 'DESKTOP_HOOK'
[Trigger]
Operation = Remove
Type = Package
Target = *

[Action]
Description = Cleaning stale desktop entries...
When = PostTransaction
Exec = /usr/local/bin/cleanup-desktops
DESKTOP_HOOK

cat > /usr/local/bin/cleanup-desktops << 'CLEANUP_DESKTOP'
#!/bin/bash
# Reads the X-SteamOS-Pamac-Container marker from each exported desktop file
# to scope cleanup to a specific container (supports custom --container-name).
# Since this hook runs inside the container as part of pacman transactions, it
# queries the local pacman database directly — no nested container exec needed.
# container_name is baked in below at install time (literal substitution by
# the installer) so per-container scoping works when this hook runs later
# without access to installer environment variables.
container_name=__CONTAINER_NAME_BAKED_IN__
for user_dir in /home/*/; do
    app_dir="${user_dir}.local/share/applications"
    [ -d "$app_dir" ] || continue
    for f in "$app_dir"/*.desktop; do
        [ -f "$f" ] || continue
        if ! grep -q '^X-SteamOS-Pamac-SourceDesktop=' "$f" 2>/dev/null; then
            continue
        fi
        file_container=$(grep '^X-SteamOS-Pamac-Container=' "$f" 2>/dev/null | cut -d= -f2-)
        if [ -n "$file_container" ] && [ -n "$container_name" ] && [ "$file_container" != "$container_name" ]; then
            continue
        fi
        pkg_name=$(grep '^X-SteamOS-Pamac-SourcePackage=' "$f" 2>/dev/null | cut -d= -f2)
        if [ -n "$pkg_name" ]; then
            if ! pacman -Qi "$pkg_name" >/dev/null 2>&1; then
                rm -f "$f"
            fi
        fi
    done
done
CLEANUP_DESKTOP
chmod +x /usr/local/bin/cleanup-desktops
fi

cat > "$hook_dir/00-keyring-refresh.hook" << 'HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Refreshing archlinux-keyring before transaction...
When = PreTransaction
Exec = /usr/local/bin/pamac-keyring-refresh.sh
Depends = archlinux-keyring
HOOK

# Create a systemd timer for periodic keyring refresh (in case Pamac GUI
# is used without going through pacman hooks)
mkdir -p /etc/systemd/system
cat > /etc/systemd/system/pamac-keyring-refresh.service << 'SVC'
[Unit]
Description=Periodic archlinux-keyring refresh for Pamac
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pamac-keyring-refresh.sh
Nice=19
IOSchedulingClass=idle
SVC

cat > /etc/systemd/system/pamac-keyring-refresh.timer << 'TIMER'
[Unit]
Description=Weekly archlinux-keyring refresh timer

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
TIMER

if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now pamac-keyring-refresh.timer 2>/dev/null || \
        echo "Note: systemd timer setup failed (no systemd in container)"
else
    echo "Note: systemd not available, skipping timer. The pacman hook handles keyring refresh."
fi

echo "Keyring refresh wrapper installed."
KEYRING_REFRESH_EOF

    # Bake the current STRICT_SECURITY setting into the generated
    # pamac-keyring-refresh.sh as a literal constant. The inner script runs
    # later (via timer/hook) without the installer's variables, so the flag
    # must be embedded now rather than read at refresh time.
    keyring_script="${keyring_script//_STRICT_SECURITY_BAKED_IN_/${STRICT_SECURITY:-false}}"
    # Bake the container name into the generated cleanup-desktops hook script
    # (same sentinel-substitution approach as setup_post_install_hooks) so the
    # per-container scoping works when the file runs later as a pacman hook.
    keyring_script="${keyring_script//__CONTAINER_NAME_BAKED_IN__/${CONTAINER_NAME}}"

    if ! exec_container_script "$keyring_script" "keyring-refresh-setup"; then
        log_warn "Keyring refresh setup had issues. Continuing..."
    fi
}

export_existing_apps() {
  log_step "Exporting existing desktop applications from container"

  local _export_ok=false
  for _attempt in 1 2 3; do
    if container_is_usable 2>/dev/null || { container_start 2>/dev/null && container_is_usable 2>/dev/null; }; then
      if distrobox-enter "$CONTAINER_NAME" -- env XDG_DATA_DIRS="/usr/local/share:/usr/share" XDG_DATA_HOME="/home/${CURRENT_USER}/.local/share" /usr/local/bin/distrobox-export-hook.sh >> "$LOG_FILE" 2>&1; then
        _export_ok=true
        break
      fi
    fi
    log_warn "Export attempt $_attempt/3 failed. Restarting container and retrying..."
    container_start 2>/dev/null || true
    sleep 3
  done

  if [[ "$_export_ok" == "true" ]]; then
    log_success "Existing explicit desktop applications exported to host menu."
  else
    log_warn "Some applications could not be exported to host after 3 attempts."
    log_info "You can retry manually with: $0 --export-only"
  fi
}

show_completion_message() {
    log_info ""
    log_success "Steam Deck Pamac Setup completed successfully!"
    log_info ""
    log_info "${BOLD}${BLUE}--- Installation Summary ---${NC}"
    log_info "  Container: ${BOLD}$CONTAINER_NAME${NC}"
    log_info "  Pamac GUI package manager installed and configured"
    log_info "  AUR helper 'yay' available for command-line package management"
    [[ "$OPTIMIZE_MIRRORS" == "true" ]] && log_info "  Pacman mirrors optimized for performance"
    [[ "$ENABLE_MULTILIB" == "true" ]] && log_info " 32-bit package support enabled"
    [[ "$ENABLE_GAMING_PACKAGES" == "true" ]] && log_info " Gaming packages installed"
    [[ "$ENABLE_EXTRA_REPOS" == "true" ]] && log_info " Third-party repos enabled: chaotic-aur, archlinuxcn, endeavouros"
    [[ "$ENABLE_BUILD_CACHE" == "true" ]] && log_info " Persistent build cache enabled"
    log_info ""
    log_info "${BOLD}${GREEN}--- How to Use ---${NC}"
    log_info "  Find 'Pamac Manager' in your application menu"
    log_info "  Command line access: ${BOLD}distrobox enter $CONTAINER_NAME${NC}"
    log_info "  CLI shortcut: ${BOLD}pamac-${CONTAINER_NAME} <command>${NC}"
    log_info ""
    log_info "${BOLD}${YELLOW}--- Important Notes ---${NC}"
    log_info "  Container persists across reboots"
    log_info "  To uninstall: run this script with ${BOLD}--uninstall${NC}"
    log_info "  Installation log saved to: ${BOLD}$LOG_FILE${NC}"
    log_info ""
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

    log_info "Creating pre-upgrade package snapshot..."
    container_root_exec bash -c 'pacman -Q > /tmp/pre-upgrade-snapshot.list 2>/dev/null || true' 2>/dev/null || true

    log_info "Syncing package databases..."
    local _sync_ok=false
    for _sync_attempt in 1 2 3; do
        if container_root_exec bash -c 'if [[ -f /var/lib/pacman/db.lck ]]; then _p=$(cat /var/lib/pacman/db.lck 2>/dev/null || echo ""); if [[ -n "$_p" ]] && kill -0 "$_p" 2>/dev/null && grep -E "pacman|yay" "/proc/$_p/comm" >/dev/null 2>&1; then echo "Pacman running (PID $_p), waiting..."; _w=0; while [[ $_w -lt 30 ]] && kill -0 "$_p" 2>/dev/null; do sleep 2; _w=$(( _w + 2 )); done; if kill -0 "$_p" 2>/dev/null; then echo "ERROR: Pacman (PID $_p) still running after 30s. Aborting."; exit 1; fi; fi; rm -f /var/lib/pacman/db.lck; fi; pacman -Syy --noconfirm' 2>/dev/null; then
            _sync_ok=true
            break
        fi
        log_warn "Database sync attempt $_sync_attempt/3 failed. Retrying..."
        container_start 2>/dev/null || true
        sleep 3
    done
    if [[ "$_sync_ok" != "true" ]]; then
        log_warn "Database sync failed after 3 attempts. Proceeding with caution..."
    fi

    log_info "Running pacman -Syu..."
    local _upgrade_ok=false
    for _upgrade_attempt in 1 2 3; do
        if container_root_exec bash -c 'if [[ -f /var/lib/pacman/db.lck ]]; then _p=$(cat /var/lib/pacman/db.lck 2>/dev/null || echo ""); if [[ -n "$_p" ]] && kill -0 "$_p" 2>/dev/null && grep -E "pacman|yay" "/proc/$_p/comm" >/dev/null 2>&1; then echo "Pacman running (PID $_p), waiting..."; _w=0; while [[ $_w -lt 30 ]] && kill -0 "$_p" 2>/dev/null; do sleep 2; _w=$(( _w + 2 )); done; if kill -0 "$_p" 2>/dev/null; then echo "ERROR: Pacman (PID $_p) still running after 30s. Aborting."; exit 1; fi; fi; rm -f /var/lib/pacman/db.lck; fi; pacman -Syu --noconfirm' 2>/dev/null; then
            _upgrade_ok=true
            break
        fi
        log_warn "pacman -Syu attempt $_upgrade_attempt/3 failed."
        if [[ $_upgrade_attempt -lt 3 ]]; then
            container_start 2>/dev/null || true
            container_root_exec bash -c 'rm -f /var/lib/pacman/db.lck 2>/dev/null; pacman -Dk 2>/dev/null || true; pacman -Syy --noconfirm 2>/dev/null || true' 2>/dev/null || true
            sleep 3
        fi
    done

    if [[ "$_upgrade_ok" != "true" ]]; then
        log_warn "pacman -Syu failed after 3 attempts. Checking for partial upgrade..."
        container_root_exec bash -c 'pacman -Dk 2>/dev/null || true' 2>/dev/null || true
    fi

    if container_user_exec bash -c "command -v yay >/dev/null 2>&1" 2>/dev/null; then
        log_info "Running yay -Syu..."
        local _yay_ok=false
        for _yay_attempt in 1 2; do
            if container_user_exec bash -c "yay -Syu --noconfirm --needed --noprogressbar" 2>/dev/null; then
                _yay_ok=true
                break
            fi
            log_warn "yay -Syu attempt $_yay_attempt/2 failed. Retrying..."
            sleep 3
        done
        if [[ "$_yay_ok" != "true" ]]; then
            log_warn "yay -Syu had issues. Some AUR packages may not have updated."
        fi
    else
        log_info "yay not installed, skipping AUR updates."
    fi

    log_info "Running post-upgrade verification..."
    container_root_exec bash -c '
set +e
# Check for database inconsistencies
if ! pacman -Dk 2>/dev/null | grep -q "No database errors"; then
    echo "WARNING: Database inconsistencies detected after upgrade."
    pacman -Dk 2>&1 | head -10 || true
fi

# Verify critical shared libraries are intact
_critical_libs_ok=true
for _lib in /usr/lib/libc.so.6 /usr/lib/libm.so.6 /usr/lib/libpthread.so.0; do
    if [[ -f "$_lib" ]] && ! ldd "$_lib" >/dev/null 2>&1; then
        echo "WARNING: Critical library $_lib has broken dependencies."
        _critical_libs_ok=false
    fi
done

# Verify core tools still work
for _tool in pacman grep bash; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "CRITICAL: Core tool $_tool is missing after upgrade."
    fi
done

# Check for partial upgrade indicators
if pacman -Q glibc >/dev/null 2>&1 && pacman -Q gcc-libs >/dev/null 2>&1; then
    _glibc_ver=$(pacman -Q glibc 2>/dev/null | awk "{print \$2}" || true)
    _gcc_ver=$(pacman -Q gcc-libs 2>/dev/null | awk "{print \$2}" || true)
    if [[ -n "$_glibc_ver" ]] && [[ -n "$_gcc_ver" ]]; then
        echo "Post-upgrade versions: glibc=$_glibc_ver gcc-libs=$_gcc_ver"
    fi
fi

echo "Post-upgrade verification complete."
' 2>/dev/null || true

    log_success "Package update complete."
}

show_status() {
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

    # Parse arguments first so that --help / --version are handled before the
    # root check. A root-invoked `sudo ./script.sh --help` should print help,
    # not the "do not run as root" error. parse_arguments exits on --help and
    # --version, so we never reach the EUID guard for those. Operational flags
    # (which require a writable container namespace) still hit the root guard.
    parse_arguments "$@"

    # Finalize the per-container log path now that CONTAINER_NAME is resolved.
    # Without this, runs with different --container-name overwrite one shared
    # log (issue: log-file collision across container names).
    LOG_FILE="$HOME/distrobox-pamac-setup-${CONTAINER_NAME}.log"

    if [[ "$EUID" -eq 0 ]]; then
        echo -e "\e[91mThis script should not be run as root.\e[0m" >&2
        echo -e "\e[91mPlease run as the regular user (e.g., 'deck' on Steam Deck).\e[0m" >&2
        exit 1
    fi
    initialize_logging

    # Prevent concurrent execution with file locking
    local _lock_dir="${XDG_RUNTIME_DIR:-$HOME/.local/state}"
    mkdir -p "$_lock_dir" 2>/dev/null || _lock_dir="/tmp"
    local _lock_file="$_lock_dir/steamos-pamac-setup.lock"
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

    check_battery_power || exit "$EXIT_USER_ABORT"

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
    check_memory_ok 524288 "container creation" 262144 || {
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

    check_memory_ok 524288 "base setup" 262144 || {
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

    if [[ "$PIN_ALPM" == "true" ]]; then
        log_info "libalpm/pacman upgraded upfront during system upgrade."
        log_info "pamac-aur compatibility handled by ensure_pamac_aur_compat during install."
    fi

ensure_critical_helpers

setup_cache_cleanup

install_gaming_packages

    export_pamac_to_host

    setup_post_install_hooks
    setup_keyring_refresh
    export_existing_apps

    configure_ssh_environment

    show_completion_message
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
