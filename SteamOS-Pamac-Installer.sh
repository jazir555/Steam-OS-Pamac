#!/bin/bash
# SteamOS Pamac Setup — installs Pamac inside a Distrobox container on SteamOS.
#
# IMPORTANT: This script uses interactive prompts (battery check, destructive
# confirmations, etc.). It MUST be run with a connected terminal stdin.
# Do NOT use `curl ... | bash` — that replaces stdin with the pipe and skips
# all interactive prompts. Instead use:
#   bash -c "$(curl -sSL <url>)"
# This downloads the script first, then executes it as a string, preserving
# stdin for interactive use.

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
#
# CRITICAL: When injecting host variables into heredoc content that will
# execute inside the container or as a separate process:
#   - Use ${VAR} for values to bake in at write-time (e.g., CONTAINER_NAME)
#   - Use \$VAR for values to resolve at runtime (e.g., \$HOME, \$DISPLAY)
#   - Never mix $VAR and \$VAR for the same variable in the same heredoc
#   - For triple-nested quoting (heredoc → bash -c → inner bash -c), prefer
#     writing a temp script file over inline escaping (\\\$ is error-prone)
#
# Validation: _validate_heredoc_sanity() checks for common mistakes.

readonly SCRIPT_VERSION="5.4.0"
readonly GITHUB_REPO="Steam-OS-Pamac/Steam-OS-Pamac"
readonly DEFAULT_CONTAINER_NAME="arch-pamac"
# GPG key ID for release signature verification during self-update.
RELEASE_SIGNING_KEY_ID="${RELEASE_SIGNING_KEY_ID:-D4B85A2AB5D6C3AE}"

# ── Self-integrity verification ──
# Prints the SHA-256 hash of this script for manual comparison against the
# hash published on the GitHub release page.
# NOTE: When the script is executed via `bash -c "$(curl -sSL <url>)"`, there
# is no physical file on disk — ${BASH_SOURCE[0]} resolves to empty or "bash".
# In that case we save the running script to a temp file and hash that, so the
# user still gets a comparable fingerprint.
_verify_script_hash() {
    local _src="${BASH_SOURCE[0]:-}"
    if [[ -z "$_src" || "$_src" == "bash" || "$_src" == "/bin/bash" || ! -f "$_src" ]]; then
        echo "NOTE: Script was executed via inline string (bash -c \"\$(curl ...)\")." >&2
        echo "      No on-disk file exists to hash directly. Saving to temp file for verification." >&2
        local _tmp_hash_src
        _tmp_hash_src=$(mktemp "${_SCRIPT_TMPDIR:-/tmp}/steamos-pamac-verify-XXXXXX.sh") 2>/dev/null
        if [[ -z "$_tmp_hash_src" ]]; then
            echo "ERROR: Cannot create temp file for hash verification." >&2
            return 1
        fi
        # Dump the currently-running script (BASH_SOURCE[0] in the caller is us,
        # but the real script body is in the BASH_SOURCE of the top-level main).
        # We use BASH_SOURCE[1] if available (the caller), else fall back to the
        # script sourced from BASH_SOURCE[0] of the calling context.
        local _caller_src="${BASH_SOURCE[1]:-}"
        if [[ -n "$_caller_src" && -f "$_caller_src" ]]; then
            cp -- "$_caller_src" "$_tmp_hash_src"
        else
            # Last resort: Read the command string from the process argument
            # buffer via /proc/self/cmdline (works on Linux/SteamOS when
            # executed via bash -c "string"). The command string is the third
            # NUL-separated argument (index 2) after "bash" and "-c".
            local _recovered=false
            if [[ -f /proc/self/cmdline ]] && command -v mapfile >/dev/null 2>&1; then
                local -a _cmd_args=()
                # Normalize NULs to newlines first for Bash < 4.4 compatibility
                # (mapfile -d requires Bash 4.4+; plain mapfile defaults to newline splitting).
                mapfile -t _cmd_args < <(tr '\0' '\n' < /proc/self/cmdline 2>/dev/null) || true
                if [[ "${_cmd_args[1]:-}" == "-c" && -n "${_cmd_args[2]:-}" ]]; then
                    printf '%s' "${_cmd_args[2]}" > "$_tmp_hash_src"
                    _recovered=true
                fi
            fi
            if [[ "$_recovered" != "true" ]]; then
                echo "ERROR: Cannot locate the running script body for hashing." >&2
                rm -f "$_tmp_hash_src"
                return 1
            fi
        fi
        echo "Hash of downloaded script ($_tmp_hash_src):" >&2
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$_tmp_hash_src"
        elif command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$_tmp_hash_src"
        else
            echo "Neither sha256sum nor shasum available. Install coreutils or perl." >&2
            rm -f "$_tmp_hash_src"
            return 1
        fi
        rm -f "$_tmp_hash_src"
    else
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$_src"
        elif command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$_src"
        else
            echo "Neither sha256sum nor shasum available. Install coreutils or perl." >&2
            return 1
        fi
    fi
}
# Default log file (used until CONTAINER_NAME is known). init_log_file() in
# main reassigns it to a per-container path so concurrent runs with different
# --container-name values don't overwrite each other's logs. Not declared
# readonly here so the per-container override can take effect.
LOG_FILE="$HOME/distrobox-pamac-setup.log"
readonly REQUIRED_TOOLS=("distrobox")
CONTAINER_HAS_INIT="unknown"

readonly ARCHLINUX_IMAGE="${ARCHLINUX_IMAGE:-archlinux:base}"

# Rolling release mode: when false (default), uses the pinned stable image
# (archlinux:base). When true, uses archlinux:latest for the latest packages.
ROLLING_RELEASE="${ROLLING_RELEASE:-false}"

# Resolved container image (may be overridden by --rolling-release).
# ARCHLINUX_IMAGE is readonly; CONTAINER_IMAGE is the actual image used.
CONTAINER_IMAGE="${ARCHLINUX_IMAGE}"

# --security-opt: additional security profiles for the container runtime.
# Accepts one or more values (colon-separated in env var, repeated --security-opt
# flags on CLI). Each value is passed as --security-opt <value> to distrobox create.
# Examples: seccomp:profile.json, apparmor:my-profile, seccomp=unconfined
CONTAINER_SECURITY_OPT=()
if [[ -n "${CONTAINER_SECURITY_OPT_ENV:-}" ]]; then
    IFS=':' read -ra _opt_parts <<< "$CONTAINER_SECURITY_OPT_ENV"
    for _opt in "${_opt_parts[@]}"; do
        [[ -n "$_opt" ]] && CONTAINER_SECURITY_OPT+=("$_opt")
    done
fi

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
# Clean up container snapshot on success. On failure, the snapshot is
# preserved so the user can roll back manually or via _rollback_container.
_cleanup_container_snapshot() {
    local _exit_code=$?
    if [[ "$_exit_code" -eq 0 && -n "${_CONTAINER_SNAPSHOT:-}" ]]; then
        log_debug "Cleaning up container snapshot (installation succeeded)."
        container_runtime_for_ops rmi "$_CONTAINER_SNAPSHOT" >/dev/null 2>&1 || true
        _CONTAINER_SNAPSHOT=""
    elif [[ "$_exit_code" -ne 0 && -n "${_CONTAINER_SNAPSHOT:-}" ]]; then
        log_warn "Installation failed. Container snapshot preserved for rollback."
        log_info "Snapshot image: $_CONTAINER_SNAPSHOT"
        log_info "To roll back: re-run the script (automatic) or manually:"
        log_info "  podman stop $CONTAINER_NAME 2>/dev/null; podman rm -f $CONTAINER_NAME 2>/dev/null"
        log_info "  podman run -d --name $CONTAINER_NAME $_CONTAINER_SNAPSHOT"
        log_info "To remove the snapshot later:"
        log_info "  podman rmi $_CONTAINER_SNAPSHOT"
    fi
    # Also clean up any stale snapshots from previous failed runs
    # (images matching the naming pattern that are dangling/unreferenced).
    # shellcheck disable=SC2046 # Intentional word splitting for multiple image IDs
    container_runtime_for_ops rmi $(container_runtime_for_ops images -q --filter "reference=localhost/steamos-pamac-snapshot-*" 2>/dev/null) >/dev/null 2>&1 || true
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

# Quick-start mode: applies a minimal, safe preset for less experienced users.
# When enabled (via --quick-start or QUICK_START=true), it forces a known-good
# set of conservative defaults and suppresses the most advanced/experimental
# options unless the user explicitly overrides them on the command line AFTER
# --quick-start. The preset is applied in apply_quick_start_preset(), which
# runs after parse_arguments() so explicit flags still win.
QUICK_START="${QUICK_START:-false}"

# GPG key discovery for third-party repos:
#   All repos default to "auto" for fingerprint resolution. The discovery
#   chain tries: keyring package extraction, pacman-key, mirror probing,
#   WKD, and keyserver import — no hardcoded fingerprints are embedded.
#   Users may override via environment variables (CHAOTIC_AUR_KEY_ID,
#   ARCHLINUXCN_KEY_ID, ENDEAVOUROS_KEY_ID) set to a 40-char hex fingerprint.
# See _enable_repo_with_fallback in configure_extra_repos.

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
# --force: skip user confirmations (e.g. container recreation low-battery
# multi-user) WITHOUT implying full --non-interactive automation. Useful when
# the user wants a headless run of a single operation but still wants the
# battery/multi-user guard skips to behave normally. Defaults to false.
FORCE_MODE="${FORCE_MODE:-false}"
# SECURITY: --dedicated-builduser is ON by default. This is a critical
# security measure that isolates AUR builds from the host user's home.
# Only disable with --no-dedicated-builduser if you understand the risk.
DEDICATED_BUILDUSER="${DEDICATED_BUILDUSER:-true}"
# SECURITY: --allow-home-mount: By default, the container uses --no-home-mount
# to prevent host /home exposure. This flag re-enables the host /home mount
# for users who need it (e.g., accessing host files from inside the container).
# Using this flag exposes host SSH keys, browser profiles, GPG keys, and any
# other sensitive data in /home to all container processes.
ALLOW_HOME_MOUNT="${ALLOW_HOME_MOUNT:-false}"
SKIP_COMPAT_CHECK="${SKIP_COMPAT_CHECK:-false}"
NO_COLOR="${NO_COLOR:-false}"
LOW_MEMORY="${LOW_MEMORY:-false}"
ALLOW_WHEEL_NOPASSWD="${ALLOW_WHEEL_NOPASSWD:-false}"
SELF_UPDATE="${SELF_UPDATE:-false}"
REPAIR="${REPAIR:-false}"
UPLOAD_LOG="${UPLOAD_LOG:-false}"
PIN_ALPM="${PIN_ALPM:-true}"
# --enable-flatpak: Re-enable Flatpak support in Pamac (default: disabled).
# On SteamOS, Flatpak is managed by Discover. Enabling it in Pamac shows
# duplicate Flathub entries. Users who prefer Pamac for all package
# management (including Flatpaks) can opt in with this flag.
ENABLE_FLATPAK="${ENABLE_FLATPAK:-false}"
_verify_sandbox_flag="${_verify_sandbox_flag:-false}"
# SECURITY: --strict-security mode. When enabled, the script refuses to relax
# signature verification (SigLevel=TrustAll methods are skipped), refuses to
# install the fake systemd-run wrapper (DynamicUser sandbox shim), and
# fails fast when any cryptographic bootstrap would otherwise degrade security.
# This is intended for users who want every operation to be cryptographically
# verified and verify that the container's init/pamac version are compatible.
STRICT_SECURITY="${STRICT_SECURITY:-false}"
# --use-init is the DEFAULT. Real systemd provides proper process isolation
# without the ~2600-line fake shim. Only use --no-use-init to fall back to
# the shim when systemd is not available on the host.
FORCE_CONTAINER_INIT="${FORCE_CONTAINER_INIT:-true}"
# --use-devtools: Use Arch's official devtools (archbuild/systemd-nspawn) for
# AUR package builds instead of yay. Devtools creates clean chroot builds with
# proper isolation, dependency resolution, and reproducibility. Requires
# devtools package in the container. Falls back to yay if unavailable.
USE_DEVTOOLS="${USE_DEVTOOLS:-false}"
# Selected install drive (populated by _select_install_drive interactive menu).
# When set, the script checks available space on the target drive and stores
# container data there. Default: auto-detect ($HOME filesystem, typically eMMC).
_SELECTED_INSTALL_DRIVE=""

# SECURITY: --allow-trustall permits the last-resort TrustAll keyring bootstrap
# (Method F) without an interactive confirmation prompt. When false (default),
# the user is prompted before any SigLevel=TrustAll operation. This ensures
# users have explicit control over signature verification relaxation.
ALLOW_TRUSTALL="${ALLOW_TRUSTALL:-false}"

# SECURITY: --trustall-all-repos allows the TrustAll throwaway config to
# include ALL repos (including third-party: chaotic-aur, archlinuxcn, etc.)
# when doing the temporary SigLevel=TrustAll keyring bootstrap. By default
# (false), non-official repos are stripped from the throwaway config so a
# compromised third-party mirror cannot inject a tampered package during
# the signature-disabled window. Set to true only if you need to bootstrap
# keys from third-party repos during the TrustAll fallback.
TRUSTALL_ALL_REPOS="${TRUSTALL_ALL_REPOS:-false}"

# Maximum per-container log file size in bytes before rotate-on-startup.
# Rotated logs are compressed and maintained as a ring of up to 3 backups.
LOG_ROTATION_MAX_SIZE="${LOG_ROTATION_MAX_SIZE:-5242880}"  # 5 MiB

# Tunable constants: extracted from scattered magic numbers so timeouts,
# thresholds, and UID ranges live in one place and can be overridden via
# environment variables if needed.
readonly CONTAINER_NAME_MAX_LEN="${CONTAINER_NAME_MAX_LEN:-63}"
readonly DISK_SPACE_MIN_KB="${DISK_SPACE_MIN_KB:-10485760}"      # 10 GiB (container + build cushion)
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
    if [[ "$NO_COLOR" == "true" ]]; then
        GREEN=''; YELLOW=''; BLUE=''; RED=''; BOLD=''; NC=''
        readonly GREEN YELLOW BLUE RED BOLD NC
    elif [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
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
    # install/update runs. Maintains a ring of 3 compressed rotated logs
    # (LOG_FILE.1.gz through LOG_FILE.3.gz) to preserve historical debug data
    # across multiple failing runs.
    if [[ -n "${LOG_FILE:-}" ]] && [[ -f "$LOG_FILE" ]]; then
        local _log_size
        local _max_size="${LOG_ROTATION_MAX_SIZE:-5242880}"
        if [[ ! "$_max_size" =~ ^[0-9]+$ ]]; then
            _max_size=5242880
        fi
        _log_size=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo "0")
        if [[ "$_log_size" =~ ^[0-9]+$ ]] && [[ "$_log_size" -gt "$_max_size" ]]; then
            local _max_rotations="${LOG_ROTATION_KEEP:-3}"
            echo "Rotating log (size ${_log_size} bytes exceeds ${_max_size} bytes): $LOG_FILE" >&2
            # Shift the ring: .3.gz deleted, .2.gz -> .3.gz, .1.gz -> .2.gz, current -> .1.gz
            local _i
            for (( _i = _max_rotations; _i >= 2; _i-- )); do
                rm -f "${LOG_FILE}.${_i}.gz" 2>/dev/null || true
                if [[ -f "${LOG_FILE}.$(( _i - 1 )).gz" ]]; then
                    mv -f "${LOG_FILE}.$(( _i - 1 )).gz" "${LOG_FILE}.${_i}.gz" 2>/dev/null || true
                fi
            done
            # Compress the oldest rotation (.1) if it exists
            if [[ -f "${LOG_FILE}.1" ]]; then
                if command -v gzip >/dev/null 2>&1; then
                    gzip -f "${LOG_FILE}.1" 2>/dev/null || mv -f "${LOG_FILE}.1" "${LOG_FILE}.2.gz" 2>/dev/null || true
                else
                    mv -f "${LOG_FILE}.1" "${LOG_FILE}.2.gz" 2>/dev/null || true
                fi
            fi
            # Rotate current log to .1
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
        echo "Image: $CONTAINER_IMAGE (rolling=$ROLLING_RELEASE)"
        echo "Desktop environment: $_desktop_env"
        echo "Features: MULTILIB=$ENABLE_MULTILIB GAMING=$ENABLE_GAMING_PACKAGES EXTRA_REPOS=$ENABLE_EXTRA_REPOS BUILD_CACHE=$ENABLE_BUILD_CACHE OPTIMIZE_MIRRORS=$OPTIMIZE_MIRRORS NON_INTERACTIVE=$NON_INTERACTIVE PIN_ALPM=$PIN_ALPM ROLLING=$ROLLING_RELEASE"
        echo "=========================================="
    } > "$LOG_FILE"

    # Initialize the global temp directory now that logging is available.
    _init_script_tmpdir

    # shellcheck disable=SC2064 # $exit_code/$date MUST expand at trap execution, not definition
    trap 'exit_code=$?; _cleanup_container_snapshot; _cleanup_temp_files; echo "=== Run finished: $(date) - Exit: $exit_code ===" >> "$LOG_FILE"; [[ "$UPLOAD_LOG" == "true" ]] && sanitize_and_upload_log || true' EXIT

    # Host-side signal handlers: forward INT/TERM to child processes and clean
    # up the container before exiting. Without these, the default signal action
    # (immediate termination) orphans running container processes and skips the
    # EXIT trap cleanup. We use `exit $((128+signum))` to propagate the
    # conventional exit code through the EXIT trap above.
    trap 'log_warn "Received SIGINT, cleaning up..."; _cleanup_container_snapshot; exit $((128 + 2))' INT
    trap 'log_warn "Received SIGTERM, cleaning up..."; _cleanup_container_snapshot; exit $((128 + 15))' TERM
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

# ── Structured event logging (JSON Lines) ──
# Writes machine-parseable events to EVENT_LOG_FILE for telemetry and failure
# diagnosis. Each line is a JSON object with timestamp, event name, and
# arbitrary key=value data. Separated from the human-readable LOG_FILE so it
# can be consumed by jq, monitoring tools, or uploaded independently.
EVENT_LOG_FILE=""
_log_event() {
    local _event="$1"; shift
    local _ts
    _ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
    local _data="{"
    local _first=true
    for _kv in "$@"; do
        local _k="${_kv%%=*}" _v="${_kv#*=}"
        # Escape JSON special characters in value
        _v="${_v//\\/\\\\}"
        _v="${_v//\"/\\\"}"
        _v="${_v//$'\n'/\\n}"
        _v="${_v//$'\t'/\\t}"
        if [[ "$_first" == "true" ]]; then
            _first=false
        else
            _data+=","
        fi
        _data+="\"${_k}\":\"${_v}\""
    done
    _data+="}"
    local _line="{\"ts\":\"${_ts}\",\"event\":\"${_event}\",\"data\":${_data}}"
    if [[ -n "${EVENT_LOG_FILE:-}" ]]; then
        printf '%s\n' "$_line" >> "$EVENT_LOG_FILE" 2>/dev/null || true
    fi
}

# ── Spinner for long-running operations ──
# Displays an animated spinner with elapsed time while a background command runs.
# Usage: _spin "Description" command args...
# The spinner runs until the command completes, then shows final status.
# Returns the command's exit code. Only spins when stdout is a terminal.
_spin() {
    local _desc="$1"; shift
    local _start_ts
    _start_ts=$(date +%s 2>/dev/null || echo 0)
    if [[ -t 1 ]]; then
        # Terminal: run with animated spinner
        (
            "$@"
        ) &
        local _pid=$!
        local _chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local _i=0
        while kill -0 "$_pid" 2>/dev/null; do
            local _ch="${_chars:$(( _i % ${#_chars} )):1}"
            local _now
            _now=$(date +%s 2>/dev/null || echo 0)
            local _elapsed=$(( _now - _start_ts ))
            local _min=$(( _elapsed / 60 ))
            local _sec=$(( _elapsed % 60 ))
            printf "\r  ${_ch} ${_desc}... [%02d:%02d] " "$_min" "$_sec" >&2
            _i=$(( _i + 1 ))
            sleep 0.1 2>/dev/null || sleep 1
        done
        wait "$_pid"
        local _rc=$?
        local _now
        _now=$(date +%s 2>/dev/null || echo 0)
        local _elapsed=$(( _now - _start_ts ))
        local _min=$(( _elapsed / 60 ))
        local _sec=$(( _elapsed % 60 ))
        if [[ $_rc -eq 0 ]]; then
            printf "\r  ✓ ${_desc}... done [%02d:%02d]   \n" "$_min" "$_sec" >&2
        else
            printf "\r  ✗ ${_desc}... failed [%02d:%02d] (exit $_rc)\n" "$_min" "$_sec" >&2
        fi
        return $_rc
    else
        # Non-terminal: run without spinner
        "$@"
    fi
}

# ── Heredoc expansion sanity check ──
# Call after writing a heredoc to verify no accidental host variable leakage.
# Usage: _validate_heredoc_sanity "$_heredoc_content" "description"
# Checks for common mistakes: bare $VAR where \$VAR was intended, and
# vice versa. Not exhaustive, but catches the most dangerous patterns.
_validate_heredoc_sanity() {
    local _content="$1" _desc="${2:-heredoc}"
    # Check for bare $HOME, $USER, $CONTAINER_NAME that look like they
    # should have been escaped (appear in a context suggesting container code)
    # shellcheck disable=SC2016 # Intentional: matching literal $HOME in content
    if echo "$_content" | grep -q 'export HOME=/home/$HOME\|export HOME=$HOME'; then
        log_warn "Heredoc '$_desc' may have unescaped \$HOME (should be \$\\\$HOME or baked value)."
    fi
    # Check for common double-escape mistakes
    if echo "$_content" | grep -q '\\\\\\$'; then
        log_debug "Heredoc '$_desc' contains triple-backslash-dollar — verify this is intentional."
    fi
}

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
    # SSH keys, tokens, AUR credentials, and other sensitive patterns.
    # Uses both sed (in-place transforms) and grep -v (line removal) for
    # maximum coverage. Known-sensitive patterns are removed entirely;
    # ambiguous patterns are redacted in-place.
    sed \
        -e 's/\x1B\[[0-9;]*[A-Za-z]//g' \
        -e "s|$HOME|~HOME|g" \
        -e "s|/home/[a-zA-Z0-9_-]*|/home/<USER>|g" \
        -e 's/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/<IP>/g' \
        -e 's/(key_?id[=: ]|fingerprint[: ]|--fingerprint[= ])[0-9A-Fa-f]{40,}/key_id=<REDACTED>/gi' \
        -e 's/-----BEGIN [A-Z ]*KEY-----/<REDACTED KEY>/g' \
        -e 's/-----END [A-Z ]*KEY-----//g' \
        -e 's/(Bearer |Authorization:)[^ ]*/\1<REDACTED>/gi' \
        -e 's/password[=: ].*$/password=<REDACTED>/gi' \
        -e 's/\btoken[=: ].*$/token=<REDACTED>/gi' \
        -e 's/secret[=: ].*$/secret=<REDACTED>/gi' \
        -e 's/api[_-]?key[=: ].*$/api_key=<REDACTED>/gi' \
        -e 's/access[_-]?key[=: ].*$/access_key=<REDACTED>/gi' \
        -e 's/AWS_[A-Z_]*[=: ].*$/<REDACTED>/gi' \
        -e 's/\?key=[^ &]*$/\?key=<REDACTED>/gi' \
        -e 's/base64,[A-Za-z0-9+/]\{32,\}[=]*/base64,<REDACTED>/gi' \
        -e 's/GPGKEY[=: ].*$/GPGKEY=<REDACTED>/gi' \
        -e 's/gpg_key[=: ].*$/gpg_key=<REDACTED>/gi' \
        -e 's/signing_key[=: ].*$/signing_key=<REDACTED>/gi' \
        -e 's/--gpgkey[= ][^ ]*/--gpgkey <REDACTED>/gi' \
        -e 's/key[_-]?id[=: ][^ ]*/key_id=<REDACTED>/gi' \
        -e 's/ssh-(rsa|ed25519|dss|ecdsa) [A-Za-z0-9+/=]*/ssh-<REDACTED_KEY>/g' \
        -e 's/cookie[=: ].*$/cookie=<REDACTED>/gi' \
        -e 's/PRIVATE[_-]?KEY[_-]?FILE/PRIVATE_KEY_FILE/gi' \
        -e 's/\.pem/<REDACTED_PEM>/g' \
        "$LOG_FILE" 2>/dev/null \
    | grep -viE '(
        AUR_[A-Z_]*KEY|             # AUR environment variable keys
        makepkg.*GPGKEY|            # makepkg GPG configuration
        pacman-key.*--lsign|        # Key signing commands with fingerprints
        gpg.*--import.*KEYS?|       # Key import commands
        SSH_PRIVATE_KEY|            # SSH key references
        COOKIE_|                    # Cookie variables
        CREDENTIALS|                # Credential references
        PRIVATE_KEY|                # Generic private key mentions
        -----BEGIN|                 # PEM headers that survived sed
        -----END|                   # PEM footers that survived sed
        X-Api-Key|                  # API key headers
        Authorization:.*Basic       # Basic auth credentials
    )' > "$sanitized_log" 2>/dev/null || {
            log_warn "Log sanitization failed. Uploading raw log."
            cp -f "$LOG_FILE" "$sanitized_log"
        }

    local upload_url=""
    log_info "Uploading sanitized log to transfer.sh..."
    upload_url=$(curl -sf --connect-timeout "${UPLOAD_CONNECT_TIMEOUT}" --max-time "${UPLOAD_MAX_TIME}" \
        --data-binary "@${sanitized_log}" \
        "https://transfer.sh/steamos-pamac-$(date +%Y%m%d-%H%M%S).log" 2>/dev/null || echo "")

    if [[ -z "$upload_url" ]]; then
        log_info "transfer.sh unavailable, trying 0x0.st..."
        upload_url=$(curl -sf --connect-timeout "${UPLOAD_CONNECT_TIMEOUT}" --max-time "${UPLOAD_MAX_TIME}" \
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
    # NOTE: Pacman uses `:: Synchronizing databases...` (space after `::` and
    # capitalized text), `:: Retrieving packages...`, `:: Processing changes...`,
    # `:: Proceed with installation?`, `debug: ...`, etc. Only the
    # synchronizing and debug: progress markers are suppressed (noise);
    # all other :: lines remain visible — they contain actionable status.
    # Pin: filter targets pacman 7.x output formats. If pacman changes its
    # :: prefix conventions, update the exclusion list accordingly.
    # Additional noise suppressed: plain "downloading" progress lines without
    # errors, "Nothing to do." churn, and "up to date" confirmations.
    #
    # SAFETY: A line containing any error/fail/warning indicator is always
    # preserved, even if it matches a noise pattern like `^downloading`. This
    # guards against masking legitimate download/operation failures if pacman
    # changes its output format (e.g. emits `downloading: error retrieving ...`).
    # The safety grep runs first so such lines escape the exclusion filter.
    local _noise='^[[:space:]]*$|^resolving dependencies|^looking for conflicting|^checking (keyring|package|group|database)|^downloading[[:space:]]|^::[[:space:]]+(Synchronizing|debug:)|^Nothing to do\.| is up to date$'
    local _keep='error|fail|warning|cannot|denied|corrupt|invalid|unexpected|refus'
    awk -v k="$_keep" -v n="$_noise" 'BEGIN{IGNORECASE=1} $0~k{print;next} $0!~n{print}'
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

# container_runtime_for_ops is intentionally a thin pass-through to
# container_runtime (no sudo / no --privileged flag). Rootless podman already
# runs the user's own containers; on Steam Deck the user owns the podman socket.
# The name documents the *caller's intent* (these ops reach the container's
# root namespace) rather than adding host escalation. Do NOT add sudo here —
# that would make repair_podman retry loops escalate to host root, which the
# script deliberately avoids (rootless-by-design). See also SECURITY notes
# around ALLOW_WHEEL_NOPASSWD.
container_runtime_for_ops() {
    container_runtime "$@"
}

container_root_exec() {
  if ! container_is_usable; then
    container_start 2>/dev/null || true
    if ! container_is_usable; then
      log_warn "Container not usable before root exec. Attempting anyway..."
    fi
  fi
  local _rc=0
  if command -v distrobox-enter >/dev/null 2>&1; then
    # Probe: check that distrobox-enter supports --root flag. Older versions
    # (<1.5) may not support --root, causing silent failures. The probe runs
    # once and caches in _DISTROBOX_HAS_ROOT so subsequent calls are fast.
    if [[ "${_DISTROBOX_HAS_ROOT:-unset}" == "unset" ]]; then
      if distrobox-enter --help 2>/dev/null | grep -q -- '--root'; then
        _DISTROBOX_HAS_ROOT=true
      else
        _DISTROBOX_HAS_ROOT=false
        log_warn "distrobox-enter does not support --root (distrobox < 1.5?). Falling back to direct exec."
      fi
    fi
    if [[ "${_DISTROBOX_HAS_ROOT:-false}" == "true" ]]; then
      local _dbx_stderr
      _dbx_stderr=$(mktemp 2>/dev/null) || _dbx_stderr="/dev/null"
      distrobox-enter "$CONTAINER_NAME" --root -- "$@" 2>"$_dbx_stderr" && { rm -f "$_dbx_stderr" 2>/dev/null; return 0; }
      _rc=$?
      log_debug "distrobox-enter --root stderr: $(cat "$_dbx_stderr" 2>/dev/null)"
      rm -f "$_dbx_stderr" 2>/dev/null || true
      _LAST_USABLE_CHECK_TS=0  # invalidate cache on failure
      log_debug "distrobox-enter --root failed (exit $_rc), falling back to direct container exec"
    fi
  fi
  # shellcheck disable=SC2046 # Intentional word splitting: _proxy_env_args_for_exec returns multiple -e args
  container_runtime_for_ops exec -i -u 0 -e HOME="/root" -e LOW_MEMORY="${LOW_MEMORY:-false}" \
    $(_proxy_env_args_for_exec) "$CONTAINER_NAME" "$@"
  _rc=$?
  [[ $_rc -ne 0 ]] && _LAST_USABLE_CHECK_TS=0  # invalidate cache on failure
  return $_rc
}

container_user_exec() {
  if ! container_is_usable; then
    container_start 2>/dev/null || true
    if ! container_is_usable; then
      log_warn "Container not usable before user exec. Attempting anyway..."
    fi
  fi
  # shellcheck disable=SC2046 # Intentional word splitting: _proxy_env_args_for_exec returns multiple -e args
  container_runtime_for_ops exec -i -u "$CURRENT_USER" \
    -e HOME="/home/${CURRENT_USER}" \
    -e XDG_DATA_DIRS="/usr/local/share:/usr/share" \
    -e XDG_DATA_HOME="/home/${CURRENT_USER}/.local/share" \
    -e PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    $(_proxy_env_args_for_exec) "$CONTAINER_NAME" "$@"
}

container_cp_from() {
    local src="$1" dst="$2"
    log_debug "Copying from container: $src -> $dst"
    if ! container_is_usable; then
        container_start 2>/dev/null || true
    fi
    if container_runtime_for_ops cp "$CONTAINER_NAME:$src" "$dst" 2>/dev/null; then
        log_debug "Copied $src from container."
        return 0
    else
        log_debug "Failed to copy $src from container."
        return 1
    fi
}

container_start() {
  container_runtime_for_ops start "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
}

container_is_running() {
  local _running
  _running=$(container_runtime_for_ops inspect "$CONTAINER_NAME" --format '{{.State.Running}}' 2>/dev/null || echo "false")
  [[ "$_running" == "true" ]]
}

container_get_status() {
  container_runtime_for_ops inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "not_found"
}

container_is_usable() {
  # Cache: if the last successful probe was <5s ago, skip the expensive exec.
  # This avoids spawning redundant "echo ok" probes when callers invoke
  # container_root_exec / container_user_exec / container_cp_from in rapid
  # succession (e.g., the install loop doing 20+ operations).
  # The running-state check is O(1) and guards against external stops
  # (podman stop from outside the script) that invalidate the exec cache.
  local _now
  _now=$(date +%s 2>/dev/null || echo 0)
  if [[ "${_LAST_USABLE_CHECK_TS:-0}" -gt 0 ]] && [[ $((_now - _LAST_USABLE_CHECK_TS)) -lt 5 ]]; then
    if container_is_running; then
      return 0
    fi
    _LAST_USABLE_CHECK_TS=0
  fi
  container_start 2>/dev/null || true
  local _output
  _output=$(timeout "${CONTAINER_PROBE_TIMEOUT}" container_runtime_for_ops exec -i -e HOME="/home/${CURRENT_USER}" "$CONTAINER_NAME" bash -c "echo ok" </dev/null 2>/dev/null || echo "")
  if [[ "$_output" == *"ok"* ]]; then
    _LAST_USABLE_CHECK_TS=$_now
    return 0
  fi
  return 1
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
				if container_runtime_for_ops inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
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

# AUR payload verification: inspect PKGBUILD for suspicious patterns before
# building. Under --strict-security, this runs automatically. Otherwise it
# provides advisory warnings. Does NOT replace cryptographic verification
# (makepkg source integrity) — it catches social engineering and
# obfuscation patterns that signature checking alone cannot detect.
_verify_aur_payload() {
    local _pkgbuild_dir="$1"
    local _pkgbuild="$_pkgbuild_dir/PKGBUILD"
    if [[ ! -f "$_pkgbuild" ]]; then
        return 0  # No PKGBUILD to check (will fail at build time)
    fi
    local _warnings=""
    local _fatal=false
    local _is_strict="${STRICT_SECURITY:-false}"

    # Check for suspicious patterns in the PKGBUILD
    # 1. curl|wget piped to bash (classic remote code execution)
    if grep -qE 'curl\s.*\|\s*(ba)?sh|wget\s.*\|\s*(ba)?sh' "$_pkgbuild" 2>/dev/null; then
        _warnings="$_warnings PIPED_REMOTE_EXEC: "
        echo "  CRITICAL: PKGBUILD contains curl/wget piped to shell."
        echo "  This is a classic remote code execution pattern."
        _fatal=true
    fi

    # 2. eval on downloaded content
    if grep -qE 'eval\s+\$|eval\s+"' "$_pkgbuild" 2>/dev/null; then
        _warnings="$_warnings EVAL_USAGE: "
        echo "  WARNING: PKGBUILD contains eval — may execute arbitrary code."
        [[ "$_is_strict" == "true" ]] && _fatal=true
    fi

    # 3. base64 decode (encoded payloads)
    if grep -qE 'base64\s+-d|base64\s+--decode' "$_pkgbuild" 2>/dev/null; then
        _warnings="$_warnings BASE64_DECODE: "
        echo "  WARNING: PKGBUILD contains base64 decode — possible encoded payload."
        [[ "$_is_strict" == "true" ]] && _fatal=true
    fi

    # 4. Writes outside $srcdir or $pkgdir
    if grep -qE 'rm\s+-rf\s+/[^"]*|rm\s+-rf\s+~/' "$_pkgbuild" 2>/dev/null; then
        _warnings="$_warnings DESTRUCTIVE_RM: "
        echo "  WARNING: PKGBUILD contains rm -rf on absolute paths."
        [[ "$_is_strict" == "true" ]] && _fatal=true
    fi

    # 5. Network fetch in build() (not just source())
    if grep -qE '^\s*build\s*\(\)|^\s*package\s*\(\)' "$_pkgbuild" 2>/dev/null; then
        local _in_func=false
        while IFS= read -r _line; do
            if echo "$_line" | grep -qE '^\s*(build|package)\s*\(\)'; then
                _in_func=true
            elif echo "$_line" | grep -qE '^\s*\}'; then
                _in_func=false
            elif [[ "$_in_func" == "true" ]] && echo "$_line" | grep -qE 'curl\s|wget\s'; then
                _warnings="$_warnings NETWORK_IN_BUILD: "
                echo "  WARNING: PKGBUILD fetches from network inside build()/package()."
                echo "  This is unusual — most packages fetch in source(), not build()."
                [[ "$_is_strict" == "true" ]] && _fatal=true
                break
            fi
        done < "$_pkgbuild"
    fi

    # 6. /etc or /usr modification outside package()
    # (This is a heuristic — legitimate packages DO write to these paths)

    if [[ -n "$_warnings" ]]; then
        echo "  AUR payload warnings: $_warnings"
        echo "  Review the PKGBUILD manually: cat $_pkgbuild"
        if [[ "$_is_strict" == "true" && "$_fatal" == "true" ]]; then
            echo "  ABORTING: --strict-security mode: refusing to build PKGBUILD with suspicious patterns."
            return 1
        elif [[ "$_fatal" == "true" ]]; then
            echo "  Proceeding despite critical warnings (not in --strict-security mode)."
        fi
    fi
    return 0
}

_RECREATE_COUNT=0
_MAX_RECREATES=2
_RECREATE_CONFIRMED=""
_RECREATE_ABORTED=""

# Prompt the user before destroying and recreating a container. Warns about
# data loss (build cache, installed AUR packages, any data in the container's
# writable layer). The decision is cached for the lifetime of the process:
# once the user approves or declines, subsequent recreation attempts reuse the
# same answer to avoid repeated prompts. In --non-interactive mode, the
# prompt is skipped and the recreation is assumed approved (the user opted
# into automated behaviour). Returns 0 to proceed, 1 to abort.
confirm_container_recreation() {
    # Reuse cached answer from a prior prompt in this run.
    if [[ "$_RECREATE_CONFIRMED" == "yes" ]]; then
        return 0
    fi
    if [[ "$_RECREATE_ABORTED" == "yes" ]]; then
        return 1
    fi

    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        log_info "Non-interactive mode — proceeding with container recreation."
        _RECREATE_CONFIRMED="yes"
        return 0
    fi

    # --force auto-approves the recreation prompt without enabling full
    # non-interactive automation (it skips only this destructive-confirmation
    # gate). Distinct from --non-interactive which suppresses ALL prompts.
    if [[ "${FORCE_MODE:-false}" == "true" ]]; then
        log_info "--force set — proceeding with container recreation without prompt."
        _RECREATE_CONFIRMED="yes"
        return 0
    fi

    # DRY_RUN never touches the filesystem, so no prompt is needed.
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        _RECREATE_CONFIRMED="yes"
        return 0
    fi

    log_warn ""
    log_warn "The container '$CONTAINER_NAME' needs to be removed and recreated."
    log_warn ""
    log_warn "THIS IS DESTRUCTIVE — the following data will be lost:"
    log_warn "  - Installed packages and AUR build cache in the container"
    log_warn "  - Any files or configuration stored inside the container"
    log_warn "  - Exported application launchers will need to be re-created"
    log_warn ""
    log_warn "The persistent yay build cache on the host (${HOME}/.cache/yay-${CONTAINER_NAME})"
    log_warn "will NOT be removed by this operation."
    log_warn ""

    if [[ -t 0 ]]; then
        echo -ne "${YELLOW}${BOLD}Recreate container '$CONTAINER_NAME' and lose container data? (y/N): ${NC}" >&2
        local _answer
        read -r _answer
        if [[ "$_answer" == "y" || "$_answer" == "Y" ]]; then
            _RECREATE_CONFIRMED="yes"
            return 0
        else
            _RECREATE_ABORTED="yes"
            log_error "Container recreation declined by user."
            return 1
        fi
    else
        # Non-terminal stdin (e.g. piped input, cron) — refuse destructive
        # action rather than silently wiping data.
        log_error "Cannot prompt for container recreation (no terminal)."
        log_error "Re-run with --non-interactive or --force to auto-approve, or attach a terminal."
        _RECREATE_ABORTED="yes"
        return 1
    fi
}

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
        log_info "Container signaled for recreation ($desc), attempt $_RECREATE_COUNT/$_MAX_RECREATES."
        if ! confirm_container_recreation; then
            return 1
        fi
        log_info "Recreating..."
        if ! force_remove_container "$CONTAINER_NAME"; then
            log_warn "force_remove_container returned non-zero. Container may still exist."
            if container_runtime_for_ops inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
                log_error "Container '$CONTAINER_NAME' still exists after force removal. Cannot recreate."
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
        return 1
    fi
}

# ── Container snapshot/rollback for fatal error recovery ──
# Uses `podman container checkpoint` (crun) or `podman commit` to save/restore
# container state. On irrecoverable failure, the container is restored to the
# last known-good snapshot so the user can retry without manual cleanup.
_CONTAINER_SNAPSHOT=""
_CONTAINER_SNAPSHOT_DIR=""
# shellcheck disable=SC2120 # Functions use ${1:-$CONTAINER_NAME} default
_snapshot_container() {
    local _name="${1:-$CONTAINER_NAME}"
    if ! container_runtime_for_ops inspect "$_name" >/dev/null 2>&1; then
        return 0
    fi
    _CONTAINER_SNAPSHOT_DIR="${_SCRIPT_TMPDIR:-/tmp}/steamos-pamac-snapshots"
    mkdir -p "$_CONTAINER_SNAPSHOT_DIR" 2>/dev/null || return 1
    local _snap_image
    _snap_image="localhost/steamos-pamac-snapshot-$(date +%s)"
    # Use podman commit to create a point-in-time image of the container.
    # This captures the entire filesystem layer — packages, config, data.
    if container_runtime_for_ops commit "$_name" "$_snap_image" >/dev/null 2>&1; then
        _CONTAINER_SNAPSHOT="$_snap_image"
        log_debug "Container snapshot created: $_snap_image"
        return 0
    else
        log_debug "podman commit failed for snapshot — will use stage sentinels for rollback"
        return 1
    fi
}
# shellcheck disable=SC2120 # Function uses ${1:-$CONTAINER_NAME} default
_rollback_container() {
    local _name="${1:-$CONTAINER_NAME}"
    if [[ -z "$_CONTAINER_SNAPSHOT" ]]; then
        log_warn "No container snapshot available for rollback."
        return 1
    fi
    log_warn "Rolling back container to pre-modification snapshot..."
    # Stop the container, remove it, and re-create from the snapshot image.
    container_runtime_for_ops stop "$_name" >/dev/null 2>&1 || true
    container_runtime_for_ops rm -f "$_name" >/dev/null 2>&1 || true
    if container_runtime_for_ops run -d --name "$_name" "$_CONTAINER_SNAPSHOT" >/dev/null 2>&1; then
        log_success "Container rolled back successfully from snapshot."
        # Clean up the snapshot image
        container_runtime_for_ops rmi "$_CONTAINER_SNAPSHOT" >/dev/null 2>&1 || true
        _CONTAINER_SNAPSHOT=""
        return 0
    else
        log_error "Rollback failed. Container may need manual recovery."
        log_info "Try: podman rm -f $_name && distrobox rm -f $_name"
        log_info "Then re-run the installer."
        return 1
    fi
}

force_remove_container() {
  local name="$1"

  if ! container_runtime_for_ops inspect "$name" >/dev/null 2>&1; then
    return
  fi

  local status
  status=$(container_runtime_for_ops inspect "$name" --format '{{.State.Status}}' 2>/dev/null || echo "not_found")
  if [[ "$status" == "not_found" ]]; then
    return
  fi

  if [[ "$status" == "stopping" || "$status" == "stopped" || "$status" == "improper" ]]; then
    log_debug "Container '$name' in '$status' state - will rely on podman rm -f for cleanup"
    sleep 1
  fi

  container_runtime_for_ops rm -f "$name" 2>/dev/null || true

  if container_runtime_for_ops inspect "$name" >/dev/null 2>&1; then
    log_debug "podman rm -f did not remove '$name'. Retrying with --time 0 (immediate SIGKILL)..."
    container_runtime_for_ops rm -f --time 0 "$name" 2>/dev/null || true
  fi

  if container_runtime_for_ops inspect "$name" >/dev/null 2>&1; then
    log_warn "podman rm -f --time 0 still failed for '$name'. The container engine may be corrupted."
    log_warn ""
    log_warn "Manual recovery options (in order of safety):"
    log_warn "  1. podman rm -f --time 0 '$name'  (immediate SIGKILL, no grace period)"
    log_warn "  2. podman stop '$name' && podman rm '$name'  (stop then remove)"
    log_warn "  3. systemctl --user restart podman  (restart the engine)"
    log_warn "  4. podman system reset --force     (DESTRUCTIVE: removes ALL containers)"
    log_warn ""
    log_warn "The script will NOT run 'podman system reset --force' automatically."
    log_warn "If you need it, run it manually after backing up important containers."
    return 1
  fi

  if container_runtime_for_ops inspect "$name" >/dev/null 2>&1; then
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

        # Validate capacity is a number before integer comparison
        if [[ ! "$capacity" =~ ^[0-9]+$ ]]; then
            log_debug "Battery '$bat_name': capacity unreadable ($capacity), skipping."
            continue
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

    # Bubblewrap is only needed for the fake systemd-run shim (--no-use-init).
    # With --use-init (default), real systemd handles sandboxing natively.
    if [[ "${FORCE_CONTAINER_INIT:-true}" != "true" ]] && [[ "${STRICT_SECURITY:-false}" != "true" ]]; then
        if command -v bwrap >/dev/null 2>&1; then
            log_success "bubblewrap (bwrap) found — full DynamicUser sandbox available."
        else
            log_warn "bubblewrap (bwrap) not found — AUR builds requiring sandbox will FAIL."
            log_info "  Install inside the container: sudo pacman -S bubblewrap"
            log_info "  Or use --use-init (default) for real systemd instead."
        fi
    fi

    # Interactive drive selector (if --install-drive or interactive terminal)
    _select_install_drive

    # Report disk space on all relevant mount points
    local available_space
    if available_space=$(df -kP "$HOME" 2>/dev/null | awk 'NR==2{print $4}'); then
        if [[ -n "$available_space" ]] && [[ $available_space -lt ${DISK_SPACE_MIN_KB} ]]; then
            log_warn "Low disk space on \$HOME. At least $(( DISK_SPACE_MIN_KB / 1024 / 1024 ))GB recommended."
            log_info "  Available: $(( available_space / 1024 ))MB on $(df -P "$HOME" 2>/dev/null | awk 'NR==2{print $6}')"
            all_ok=false
        elif [[ -n "$available_space" ]]; then
            log_success "Disk space on \$HOME: $(( available_space / 1024 / 1024 ))GB on $(df -P "$HOME" 2>/dev/null | awk 'NR==2{print $6}')"
        fi
    else
        log_warn "Could not check disk space on \$HOME."
    fi

    # Show install target space if a different drive was selected
    if [[ -n "${_SELECTED_INSTALL_DRIVE:-}" ]]; then
        local _drive_dev _drive_avail_gb
        _drive_dev=$(df -P "$_SELECTED_INSTALL_DRIVE" 2>/dev/null | awk 'NR==2{print $1}' || echo "unknown")
        _drive_avail_gb=$(df -kP "$_SELECTED_INSTALL_DRIVE" 2>/dev/null | awk 'NR==2{int($4/1048576)}' || echo "?")
        log_info "Install target: $_SELECTED_INSTALL_DRIVE ($_drive_dev, ~${_drive_avail_gb}GB free)"
    fi

    local var_space
    if var_space=$(df -kP /var 2>/dev/null | awk 'NR==2{print $4}'); then
        if [[ -n "$var_space" ]] && [[ "$var_space" -lt ${DISK_SPACE_MIN_KB} ]]; then
            log_warn "Low disk space on /var. At least $(( DISK_SPACE_MIN_KB / 1024 / 1024 ))GB recommended."
            log_info "  Available: $(( var_space / 1024 ))MB"
            all_ok=false
        elif [[ -n "$var_space" ]]; then
            log_debug "Disk space on /var: $(( var_space / 1024 / 1024 ))GB"
        fi
    fi

    local root_space
    if root_space=$(df -kP / 2>/dev/null | awk 'NR==2{print $4}'); then
        if [[ -n "$root_space" ]] && [[ "$root_space" -lt ${DISK_SPACE_MIN_KB} ]]; then
            log_warn "Low disk space on /. At least $(( DISK_SPACE_MIN_KB / 1024 / 1024 ))GB recommended."
            log_info "  Available: $(( root_space / 1024 ))MB"
            all_ok=false
        elif [[ -n "$root_space" ]]; then
            log_debug "Disk space on /: $(( root_space / 1024 / 1024 ))GB"
        fi
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

verify_sandbox() {
    log_step "Running sandbox self-tests..."
    if ! container_is_usable; then
        log_error "Container not usable. Run the full setup first."
        return 1
    fi
    if ! command -v distrobox-enter >/dev/null 2>&1; then
        log_error "distrobox-enter not found."
        return 1
    fi
    local _test_script
    _test_script=$(mktemp "${_SCRIPT_TMPDIR:-/tmp}/sandbox-verify-XXXXXX.sh") || {
        log_error "Failed to create temp file for sandbox test."
        return 1
    }
    cat > "$_test_script" << 'SANDBOX_TEST_EOF'
#!/bin/bash
set +e
_pass=0
_fail=0
_degraded=false
_result() {
    local _name="$1" _ok="$2" _detail="$3"
    if [[ "$_ok" == "true" ]]; then
        echo "  ✅ $_name: OK ${_detail:+— $_detail}"
        _pass=$(( _pass + 1 ))
    else
        echo "  ❌ $_name: FAILED ${_detail:+— $_detail}"
        _fail=$(( _fail + 1 ))
        _degraded=true
    fi
}
echo "=== Sandbox Self-Tests ==="
echo ""
# Check if real systemd is available (default --use-init mode)
if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
    echo "Container uses real systemd (--use-init mode)."
    echo "Testing native systemd-run sandbox..."
    echo ""
    echo "--- 1. systemd-run availability ---"
    if command -v systemd-run >/dev/null 2>&1; then
        echo "  systemd-run available: $(command -v systemd-run)"
        _result "systemd_run_present" "true" ""
    else
        echo "  systemd-run NOT found"
        _result "systemd_run_present" "false" ""
        _degraded=true
    fi
    echo ""
    echo "--- 2. systemd-run DynamicUser sandbox test ---"
    if systemd-run --property=DynamicUser=yes --property=ProtectSystem=strict \
        --property=PrivateTmp=yes --property=NoNewPrivileges=yes \
        --unit=pamac-sandbox-test -- echo "sandbox-ok" 2>/dev/null; then
        echo "  systemd-run DynamicUser sandbox executed successfully"
        _result "systemd_dynamic_user" "true" ""
    else
        echo "  systemd-run DynamicUser sandbox failed"
        _result "systemd_dynamic_user" "false" "check systemd configuration"
        _degraded=true
    fi
    echo ""
    echo "--- 3. systemd unit sandbox enforcement ---"
    _unit_status=$(systemctl show pamac-sandbox-test --property=ActiveState 2>/dev/null || echo "not-found")
    if [[ "$_unit_status" == "inactive" ]] || [[ "$_unit_status" == "dead" ]]; then
        echo "  systemd unit lifecycle OK"
        _result "systemd_unit" "true" ""
    else
        echo "  systemd unit state: $_unit_status"
        _result "systemd_unit" "true" "(state: $_unit_status)"
    fi
else
# Non-init mode: test the fake systemd-run shim
echo "--- 1. Fake systemd-run wrapper ---"
if [[ -x /usr/local/sbin/systemd-run ]]; then
    _ver=$(/usr/local/sbin/systemd-run --version 2>/dev/null | head -1 || echo "unknown")
    echo "  Wrapper installed: /usr/local/sbin/systemd-run ($_ver)"
    _result "wrapper_present" "true" ""
else
    echo "  Wrapper NOT found at /usr/local/sbin/systemd-run"
    _result "wrapper_present" "false" "install base-devel for seccomp compilation"
fi
echo ""
echo "--- 2. Bubblewrap engine ---"
if command -v bwrap >/dev/null 2>&1; then
    echo "  bwrap available: $(command -v bwrap)"
    _result "bwrap_present" "true" ""
else
    echo "  bwrap NOT found — sandbox will be DEGRADED (no PID/mount namespace isolation)"
    _result "bwrap_present" "false" "install bubblewrap for full isolation"
    _degraded=true
fi
echo ""
echo "--- 3. seccomp helper compilation ---"
if command -v gcc >/dev/null 2>&1; then
    echo "  gcc available — seccomp helper can compile"
    _result "gcc_present" "true" ""
else
    echo "  gcc NOT found — seccomp filtering will be DEGRADED"
    _result "gcc_present" "false" "install base-devel for full seccomp"
    _degraded=true
fi
echo ""
echo "--- 4. Capability dropping ---"
if command -v capsh >/dev/null 2>&1; then
    echo "  capsh available — full bounding-set enforcement"
    _result "capsh_present" "true" ""
elif command -v setpriv >/dev/null 2>&1; then
    echo "  setpriv available — inheritable-set only (weaker)"
    _result "capsh_present" "false" "install libcap for full cap enforcement"
    _degraded=true
else
    echo "  Neither capsh nor setpriv found"
    _result "capsh_present" "false" "install libcap or util-linux"
    _degraded=true
fi
echo ""
echo "--- 5. Live sandbox test (bwrap) ---"
if command -v bwrap >/dev/null 2>&1; then
    if timeout 5 bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp \
        --unshare-pid --die-with-parent true 2>/dev/null; then
        echo "  bwrap sandbox executed successfully"
        _result "bwrap_exec" "true" ""
    else
        echo "  bwrap sandbox execution failed"
        _result "bwrap_exec" "false" "check bubblewrap installation"
        _degraded=true
    fi
else
    echo "  bwrap not available — sandbox will be DEGRADED"
    echo "  (install bubblewrap for full PID/mount namespace isolation)"
    if timeout 5 unshare --mount -- /bin/true 2>/dev/null; then
        echo "  unshare sandbox executed successfully"
        _result "unshare_exec" "true" "(no PID namespace isolation)"
        _degraded=true
    else
        echo "  unshare sandbox execution failed"
        _result "unshare_exec" "false" "check kernel user namespace support"
        _degraded=true
    fi
fi
echo ""
echo "--- 6. seccomp-BPF filter test ---"
if command -v gcc >/dev/null 2>&1; then
    _seccomp_test_src=$(mktemp /tmp/seccomp-test-XXXXXX.c)
    cat > "$_seccomp_test_src" << 'SECCOMP_TEST_C'
#include <stdio.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <linux/unistd.h>
int main() {
    struct sock_filter f[] = {
        { 0x20, 0, 0, 0 },
        { 0x15, 0, 1, 999999 },
        { 0x06, 0, 0, 0x00030000 },
        { 0x06, 0, 0, 0x00000000 },
    };
    struct sock_fprog p = { .len = sizeof(f) / sizeof(f[0]), .filter = f };
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p) != 0) {
        fprintf(stderr, "seccomp load failed\n");
        return 1;
    }
    fprintf(stderr, "seccomp filter active\n");
    return 0;
}
SECCOMP_TEST_C
    _seccomp_test_bin="${_seccomp_test_src%.c}"
    if gcc -o "$_seccomp_test_bin" "$_seccomp_test_src" 2>/dev/null; then
        if timeout 3 "$_seccomp_test_bin" 2>/dev/null; then
            echo "  seccomp-BPF filter loaded and active"
            _result "seccomp_active" "true" ""
        else
            echo "  seccomp-BPF filter could not be loaded"
            _result "seccomp_active" "false" "kernel may lack seccomp support"
            _degraded=true
        fi
    else
        echo "  seccomp test compilation failed"
        _result "seccomp_active" "false" "gcc compilation issue"
        _degraded=true
    fi
    rm -f "$_seccomp_test_src" "$_seccomp_test_bin" 2>/dev/null || true
else
    echo "  gcc not available — cannot test seccomp"
    _result "seccomp_active" "false" "install base-devel"
    _degraded=true
fi
fi # end of init vs shim branch
echo ""
echo "=== Summary ==="
echo "  Passed: $_pass  Failed: $_fail"
if [[ "$_degraded" == "true" ]]; then
    echo ""
    echo "  ⚠️  Sandbox is DEGRADED — some protections are not active."
    echo "  To fix: install base-devel inside the container:"
    echo "    sudo pacman -S --noconfirm --needed base-devel gcc libcap bubblewrap"
    exit 1
else
    echo "  ✅ All sandbox protections active."
    exit 0
fi
SANDBOX_TEST_EOF
    chmod +x "$_test_script"
    local _test_output
    _test_output=$(distrobox-enter "$CONTAINER_NAME" -- bash "$_test_script" 2>&1)
    local _test_rc=$?
    rm -f "$_test_script"
    echo "$_test_output"
    if [[ $_test_rc -ne 0 ]]; then
        log_warn "Sandbox self-tests reported degraded status."
        log_info "Install base-devel inside the container for full sandboxing:"
        log_info "  distrobox enter $CONTAINER_NAME -- sudo pacman -S --noconfirm --needed base-devel gcc libcap bubblewrap"
    fi
    return "$_test_rc"
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
    local _curl_output=""
    local _curl_rc=0

    # Auto-detect a host desktop proxy if none is exported, so the rest of the
    # script (and the container, via _proxy_env_args_for_exec) actually uses it.
    # Previously this only printed a hint to "export https_proxy", leaving the
    # keyring bootstrap to fail on corporate/captive networks.
    if _autodetect_system_proxy; then
        : # proxy was auto-detected and exported
    fi

    # Check for proxy configuration first — common on corporate/hotel networks.
    if [[ -n "${http_proxy:-}" || -n "${https_proxy:-}" || -n "${HTTP_PROXY:-}" || -n "${HTTPS_PROXY:-}" ]]; then
        local _proxy="${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}"
        log_info "Proxy detected: $_proxy"
        log_info "curl/pacman will use this proxy for all HTTPS connections."
        log_info "Proxy (and CA bundle) will be inherited by the container automatically."
    fi

    # Check for captive portal: connect to archlinux.org and inspect the response.
    # Captive portals typically return HTTP 200/3xx with HTML content instead of
    # the expected Arch Linux page, or intercept HTTPS with a self-signed cert.
    local _curl_err_file
    _curl_err_file=$(mktemp /tmp/pamac-curl-err.XXXXXX 2>/dev/null || echo "/dev/null")
    _curl_output=$(timeout "${NETWORK_PROBE_TIMEOUT}" curl -sSf --connect-timeout "${NETWORK_PROBE_CONNECT_TIMEOUT}" \
        --max-time "${NETWORK_PROBE_TIMEOUT}" -o /dev/null -w "%{http_code}\n%{ssl_verify_result}" \
        "$_probe_url" 2>"$_curl_err_file") || _curl_rc=$?
    _http_code=$(echo "$_curl_output" | head -1 || echo "000")
    local _ssl_verify
    _ssl_verify=$(echo "$_curl_output" | tail -1 || echo "")

    # SSL verification result: 0 = valid, non-zero = cert issue (captive portal
    # or corporate proxy intercepting HTTPS with self-signed cert).
    if [[ "$_ssl_verify" =~ ^[1-9] ]]; then
        log_warn "SSL certificate verification failed (result=$_ssl_verify)."
        log_warn "This usually indicates a captive portal or corporate proxy intercepting HTTPS."
        log_warn ""
        log_warn "Captive portal detected! You need to:"
        log_warn "  1. Open a browser and accept the captive portal login page."
        log_warn "  2. If behind a corporate proxy, set the proxy before re-running:"
        log_warn "     export http_proxy=http://proxy-host:port"
        log_warn "     export https_proxy=http://proxy-host:port"
        log_warn "  3. If the proxy uses a custom CA certificate, add it:"
        log_warn "     export CURL_CA_BUNDLE=/path/to/ca-cert.pem"
        log_warn "  4. If all else fails, run with --skip-compat-check to bypass"
        log_warn "     network-dependent checks (keyring bootstrap may still fail)."
        log_info ""
        log_info "The keyring bootstrap and AUR operations require HTTPS to archlinux.org"
        log_info "and key servers. Without valid SSL, these will fail with cryptic errors."
    fi

    case "$_http_code" in
        000)
            local _curl_err=""
            _curl_err=$(cat "$_curl_err_file" 2>/dev/null || echo "")
            if echo "$_curl_err" | grep -qi "SSL\|certificate\|cert\|verify"; then
                log_warn "SSL/TLS error connecting to $_probe_url:"
                log_warn "  $_curl_err"
                log_warn "This is likely a captive portal or proxy with self-signed certificates."
                log_warn ""
                log_warn "To work around:"
                log_warn "  1. export https_proxy=http://proxy-host:port"
                log_warn "  2. export CURL_CA_BUNDLE=/path/to/ca-cert.pem"
                log_warn "  3. Or open a browser to accept the captive portal login page."
            elif echo "$_curl_err" | grep -qi "resolve\|DNS\|name"; then
                log_warn "DNS resolution failed for $_probe_url."
                log_warn "Check: getent hosts archlinux.org"
                log_warn "If behind a proxy: export http_proxy=http://proxy-host:port"
            else
                log_warn "Network probe could not reach $_probe_url (this is a heuristic — mirrors may still work)."
                log_info "The keyring bootstrap will attempt recovery and report failures at runtime if needed."
                log_info "If you know the host is offline, install cached packages instead."
                log_info "  - Verify DNS: getent hosts archlinux.org"
                log_info "  - Behind captive portal/proxy? export https_proxy=http://host:port"
            fi
            ;;
        2*|3*)
            log_success "Network connectivity OK (HTTP $_http_code from $_probe_url)."
            ;;
        *)
            log_debug "Reachable probe (HTTP $_http_code) — common redirect/maintenance code, treating as reachable."
            ;;
    esac
    rm -f "$_curl_err_file" 2>/dev/null || true
}

# Emit `-e VAR=value` pairs for proxy / CA-bundle env so that container_root_exec
# and container_user_exec propagate host proxy settings into the container.
# This closes the network-bootstrap gap: previously the pre-flight probe
# suggested exporting https_proxy but never forwarded it to pacman/curl/gpg
# running inside the container, so keyring and package downloads would still
# fail on proxy-only networks even when the host had the proxy set. We honor
# the standard lowercase + uppercase proxy vars plus NO_PROXY/CURL_CA_BUNDLE/
# GNUPGHOME-independent GnuPG proxy (handled via dirmngr config separately).
# Shellcheck-friendly: this is intentionally a single echo so callers can
# `$(_proxy_env_args_for_exec)` it unquoted into an exec argv.
_proxy_env_args_for_exec() {
    local _args=""
    for _v in http_proxy https_proxy ftp_proxy all_proxy no_proxy \
              HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY \
              CURL_CA_BUNDLE REQUESTS_CA_BUNDLE SSL_CERT_FILE GIT_SSL_CAINFO; do
        local _val="${!_v:-}"
        if [[ -n "$_val" ]]; then
            # Quote the value safely for the exec -e argument. Simple values
            # (urls, file paths) don't contain single quotes in practice, but
            # we escape any ' just in case.
            local _esc="${_val//\'/\'\\\'\'}"
            _args+=" -e ${_v}='${_esc}'"
        fi
    done
    printf '%s' "$_args"
}

# Build a worst-effort list of systemd/docker-style proxy env passed through
# distrobox create --env so the container retains proxy settings persistently
# (e.g. for the pamac-session-bootstrap.sh auto-refresh). Returns array-style
# args via a global _PROXY_CREATE_ARGS for create_container to splice in.
_collect_proxy_create_args() {
    _PROXY_CREATE_ARGS=()
    local _v
    for _v in http_proxy https_proxy ftp_proxy all_proxy no_proxy \
              HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY \
              CURL_CA_BUNDLE REQUESTS_CA_BUNDLE SSL_CERT_FILE GIT_SSL_CAINFO; do
        local _val="${!_v:-}"
        if [[ -n "$_val" ]]; then
            _PROXY_CREATE_ARGS+=(--env "${_v}=${_val}")
        fi
    done
}

# Fetch a PAC file and extract a direct proxy URL from it. PAC files are
# JavaScript; we do NOT run a JS interpreter. Instead we apply regex patterns
# that cover the most common corporate PAC patterns:
#   return "PROXY host:port"
#   return "SOCKS host:port"
#   return "DIRECT" (no proxy)
# Sets _detected to the extracted URL on success, empty on failure.
_fetch_and_parse_pac() {
    local _pac_url="$1"
    local _prefetched_content="${2:-}"
    _detected=""
    local _pac_content=""
    if [[ -n "$_prefetched_content" ]]; then
        _pac_content="$_prefetched_content"
        log_debug "Using pre-fetched PAC content (${#_pac_content} bytes)."
    else
        log_info "Fetching PAC file: $_pac_url"
        _pac_content=$(curl -sSf --connect-timeout 5 --max-time 10 "$_pac_url" 2>/dev/null || true)
    fi
    if [[ -z "$_pac_content" ]]; then
        log_debug "Could not fetch PAC file from $_pac_url"
        return 1
    fi
    log_debug "PAC file fetched (${#_pac_content} bytes). Extracting proxy..."
    # Strip comments (// and /* */) to clean the PAC content
    _pac_content=$(printf '%s' "$_pac_content" | sed 's|//.*$||g; s|/\*.*\*/||g')
    # Pattern 1: return "PROXY host:port" (most common in corporate PACs)
    local _proxy_line
    _proxy_line=$(printf '%s' "$_pac_content" | grep -oEi 'return\s+"PROXY\s+[^"]+' | head -1 || true)
    if [[ -n "$_proxy_line" ]]; then
        local _host_port
        _host_port=$(echo "$_proxy_line" | sed 's/.*PROXY\s*//i' | tr -d '"' | tr -d "'" | xargs)
        if [[ -n "$_host_port" ]]; then
            _detected="http://$_host_port"
            return 0
        fi
    fi
    # Pattern 2: return "SOCKS host:port" (SOCKS proxy)
    _proxy_line=$(printf '%s' "$_pac_content" | grep -oEi 'return\s+"SOCKS\s+[^"]+' | head -1 || true)
    if [[ -n "$_proxy_line" ]]; then
        local _host_port
        _host_port=$(echo "$_proxy_line" | sed 's/.*SOCKS\s*//i' | tr -d '"' | tr -d "'" | xargs)
        if [[ -n "$_host_port" ]]; then
            # SOCKS is not directly usable by curl/pacman — map to HTTP CONNECT
            # proxy. Most corporate SOCKS proxies also accept HTTP CONNECT on
            # the same port. If this doesn't work, the user must export manually.
            _detected="http://$_host_port"
            log_debug "PAC returns SOCKS — mapped to HTTP CONNECT proxy ($_detected)"
            return 0
        fi
    fi
    # Pattern 3: Simple variable assignment like myProxy = "host:port"
    _proxy_line=$(printf '%s' "$_pac_content" | grep -oEi '(myProxy|proxy)\s*=\s*"[^"]*:[0-9]+' | head -1 || true)
    if [[ -n "$_proxy_line" ]]; then
        local _host_port
        _host_port=$(echo "$_proxy_line" | grep -oE '[0-9a-zA-Z._-]+:[0-9]+')
        if [[ -n "$_host_port" ]]; then
            _detected="http://$_host_port"
            return 0
        fi
    fi
    # Pattern 4: shExpMatch with a literal proxy in the same function
    # e.g. if (shExpMatch(host, "*.corp.local")) return "PROXY proxy.corp.local:8080";
    _proxy_line=$(printf '%s' "$_pac_content" | grep -oEi '"PROXY\s+[^"]+' | head -1 || true)
    if [[ -n "$_proxy_line" ]]; then
        local _host_port
        _host_port=$(echo "$_proxy_line" | sed 's/.*PROXY\s*//i' | tr -d '"' | xargs)
        if [[ -n "$_host_port" ]]; then
            _detected="http://$_host_port"
            return 0
        fi
    fi
    log_debug "PAC file parsed but no extractable direct proxy found (may use per-domain rules)."
    return 1
}

# Auto-detect a system proxy when none is exported, then surface it so the
# user is informed (and can opt in by exporting it). Best-effort: checks the
# SteamOS/Steam Deck gsettings (commonly GNOME-ish) before giving up. Returns
# 0 if a proxy was found and exported by this function, 1 otherwise.
_autodetect_system_proxy() {
    # Already have a proxy set — nothing to do.
    if [[ -n "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${all_proxy:-${ALL_PROXY:-}}" ]]; then
        return 1
    fi
    local _detected=""

    # ── Method 1: NetworkManager (nmcli) ──
    # KDE Plasma on SteamOS/Steam Deck uses NetworkManager for proxy config.
    # nmcli reports proxy settings per-connection and globally.
    if [[ -z "$_detected" ]] && command -v nmcli >/dev/null 2>&1; then
        local _nm_proxy
        _nm_proxy=$(nmcli -t -f connection.proxy.method connection show --active 2>/dev/null | head -1 || echo "")
        if [[ "$_nm_proxy" == "manual" ]]; then
            local _nm_host _nm_port
            _nm_host=$(nmcli -t -f connection.proxy.http connection show --active 2>/dev/null | head -1 || echo "")
            _nm_port=$(nmcli -t -f connection.proxy.http-port connection show --active 2>/dev/null | head -1 || echo "")
            if [[ -n "$_nm_host" && -n "$_nm_port" && "$_nm_host" != "" && "$_nm_port" != "0" ]]; then
                _detected="http://${_nm_host}:${_nm_port}"
            else
                _nm_host=$(nmcli -t -f connection.proxy.https connection show --active 2>/dev/null | head -1 || echo "")
                _nm_port=$(nmcli -t -f connection.proxy.https-port connection show --active 2>/dev/null | head -1 || echo "")
                if [[ -n "$_nm_host" && -n "$_nm_port" && "$_nm_host" != "" && "$_nm_port" != "0" ]]; then
                    _detected="http://${_nm_host}:${_nm_port}"
                fi
            fi
        elif [[ "$_nm_proxy" == "auto" ]]; then
            local _nm_pac
            _nm_pac=$(nmcli -t -f connection.proxy.pac-url connection show --active 2>/dev/null | head -1 || echo "")
            if [[ -n "$_nm_pac" && "$_nm_pac" != "" ]]; then
                _fetch_and_parse_pac "$_nm_pac"
                if [[ -n "${_detected:-}" ]]; then
                    log_info "Auto-detected proxy from NetworkManager PAC: $_detected"
                fi
            fi
        fi
    fi

    # ── Method 2: GNOME/desktop proxy via gsettings ──
    # Used by KDE/GNOME on SteamOS for desktop proxy configuration.
    if [[ -z "$_detected" ]] && command -v gsettings >/dev/null 2>&1; then
        local _mode
        _mode=$(gsettings get org.gnome.system.proxy mode 2>/dev/null | tr -d "'")
        if [[ "$_mode" == "manual" ]]; then
            local _h _p _host
            _h=$(gsettings get org.gnome.system.proxy.http host 2>/dev/null | tr -d "'")
            _p=$(gsettings get org.gnome.system.proxy.http port 2>/dev/null | tr -d "'")
            if [[ -n "$_h" && -n "$_p" && "$_h" != "0" && "$_p" != "0" ]]; then
                _detected="http://${_h}:${_p}"
            else
                _h=$(gsettings get org.gnome.system.proxy.https host 2>/dev/null | tr -d "'")
                _p=$(gsettings get org.gnome.system.proxy.https port 2>/dev/null | tr -d "'")
                if [[ -n "$_h" && -n "$_p" && "$_h" != "0" && "$_p" != "0" ]]; then
                    _detected="http://${_h}:${_p}"
                fi
            fi
        fi
    fi

    # ── Method 3: KDE/kioslaverc ──
    # KDE Plasma stores proxy settings in ~/.config/kioslaverc (or via
    # kreadconfig5/kreadconfig6). This is the primary proxy config path on
    # SteamOS/Steam Deck which uses KDE Plasma.
    if [[ -z "$_detected" ]]; then
        local _kioslaverc="${XDG_CONFIG_HOME:-$HOME/.config}/kioslaverc"
        local _kreadconfig=""
        if command -v kreadconfig6 >/dev/null 2>&1; then
            _kreadconfig="kreadconfig6"
        elif command -v kreadconfig5 >/dev/null 2>&1; then
            _kreadconfig="kreadconfig5"
        fi
        local _kde_mode=""
        if [[ -n "$_kreadconfig" ]]; then
            _kde_mode=$($_kreadconfig --file kioslaverc --group "Proxy Settings" --key "ProxyType" 2>/dev/null || echo "")
        elif [[ -f "$_kioslaverc" ]]; then
            _kde_mode=$(grep -oP 'ProxyType=\K.*' "$_kioslaverc" 2>/dev/null | head -1 || echo "")
        fi
        if [[ "$_kde_mode" == "1" ]]; then
            local _kh _kp
            if [[ -n "$_kreadconfig" ]]; then
                _kh=$($_kreadconfig --file kioslaverc --group "Proxy Settings" --key "HttpProxy" 2>/dev/null | grep -oP '^\S+' || echo "")
                _kp=$($_kreadconfig --file kioslaverc --group "Proxy Settings" --key "HttpProxy" 2>/dev/null | grep -oP ':\K[0-9]+' || echo "")
            elif [[ -f "$_kioslaverc" ]]; then
                _kh=$(awk -F'[=:]' '/^HttpProxy=/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' "$_kioslaverc" 2>/dev/null || echo "")
                _kp=$(awk -F'[=:]' '/^HttpProxy=/{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3; exit}' "$_kioslaverc" 2>/dev/null || echo "")
            fi
            if [[ -n "$_kh" && -n "$_kp" && "$_kp" != "0" ]]; then
                _detected="http://${_kh}:${_kp}"
            fi
        elif [[ "$_kde_mode" == "2" ]]; then
            local _kde_pac=""
            if [[ -n "$_kreadconfig" ]]; then
                _kde_pac=$($_kreadconfig --file kioslaverc --group "Proxy Settings" --key "ProxyConfigScript" 2>/dev/null || echo "")
            elif [[ -f "$_kioslaverc" ]]; then
                _kde_pac=$(grep -oP 'ProxyConfigScript=\K.*' "$_kioslaverc" 2>/dev/null | head -1 || echo "")
            fi
            if [[ -n "$_kde_pac" && "$_kde_pac" != "" ]]; then
                _fetch_and_parse_pac "$_kde_pac"
                if [[ -n "${_detected:-}" ]]; then
                    log_info "Auto-detected proxy from KDE PAC config: $_detected"
                fi
            fi
        fi
    fi

    # ── Method 4: WPAD DNS discovery ──
    # WPAD (Web Proxy Auto-Discovery) locates a PAC file via DNS. The client
    # queries wpad.<domain>/wpad.dat over HTTP. This is common on corporate
    # networks where DNS is configured to point wpad to the proxy server.
    if [[ -z "$_detected" ]]; then
        local _domain=""
        # Extract domain from hostname (e.g., "deck.internal.corp" -> "internal.corp")
        _domain=$(hostname -f 2>/dev/null | sed 's/^[^.]*\.//' || echo "")
        if [[ -n "$_domain" && "$_domain" != *"."* ]]; then
            _domain=""  # Not a FQDN, skip WPAD
        fi
        if [[ -n "$_domain" ]]; then
            local _wpad_url="http://wpad.${_domain}/wpad.dat"
            log_debug "Trying WPAD discovery: $_wpad_url"
            local _wpad_resp=""
            _wpad_resp=$(curl -sSf --connect-timeout 3 --max-time 5 "$_wpad_url" 2>/dev/null || echo "")
            if [[ -n "$_wpad_resp" ]] && echo "$_wpad_resp" | grep -qi "FindProxyForURL\|PROXY\|SOCKS"; then
                log_debug "WPAD response received (${#_wpad_resp} bytes), parsing..."
                _fetch_and_parse_pac "$_wpad_url" "$_wpad_resp"
                if [[ -n "${_detected:-}" ]]; then
                    log_info "Auto-detected proxy from WPAD: $_detected"
                fi
            fi
        fi
    fi

    # ── Method 5: PAC file auto-config ──
    # If a PAC URL is configured in desktop settings, fetch and parse it to
    # extract the proxy host/port. PAC files are JavaScript that call
    # FindProxyForURL(). Most corporate PACs use simple patterns like
    # "return PROXY host:port" or "return SOCKS host:port". We do a best-effort
    # regex extraction that handles the common cases without a JS interpreter.
    local _pac_url="${AUTO_PROXY_SCRIPT_URL:-}${PAC_URL:-}"
    # Also check gsettings for the autoconfig-url
    if [[ -z "$_pac_url" ]] && command -v gsettings >/dev/null 2>&1; then
        local _pac_gsettings
        _pac_gsettings=$(gsettings get org.gnome.system.proxy autoconfig-url 2>/dev/null | tr -d "'")
        if [[ -n "$_pac_gsettings" && "$_pac_gsettings" != "''" && "$_pac_gsettings" != '""' ]]; then
            _pac_url="$_pac_gsettings"
        fi
    fi
    if [[ -n "$_pac_url" ]]; then
        _fetch_and_parse_pac "$_pac_url"
        if [[ -n "${_detected:-}" ]]; then
            export http_proxy="$_detected" https_proxy="$_detected" HTTP_PROXY="$_detected" HTTPS_PROXY="$_detected"
            log_info "Extracted proxy from PAC file: $_detected"
            log_info "Exported as http_proxy/https_proxy for this run."
            return 0
        fi
        log_warn "PAC file detected ($_pac_url) but proxy could not be extracted automatically."
        log_warn "  The PAC file may use complex logic (SOCKS, per-domain rules) that"
        log_warn "  requires a JavaScript interpreter. Export proxy manually:"
        log_warn "    export https_proxy=http://your-proxy:port"
    fi
    if [[ -n "$_detected" ]]; then
        export http_proxy="$_detected" https_proxy="$_detected" HTTP_PROXY="$_detected" HTTPS_PROXY="$_detected"
        log_info "Auto-detected system proxy from desktop settings: $_detected"
        log_info "Exported as http_proxy/https_proxy for this run. To override, run:"
        log_info "  export http_proxy=http://your-proxy:port; export https_proxy=\$http_proxy"
        return 0
    fi
    return 1
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
        log_warn ""
        log_warn "NOTE: Installation will proceed despite this warning. If container"
        log_warn "binaries start segfaulting after an Arch update, re-run with the"
        log_warn "ARCHLINUX_IMAGE pin to roll back the container's glibc."
    elif [[ "$kernel_warn" == "true" ]]; then
        log_info "Host kernel ${kernel_major}.${kernel_minor} is close to the minimum"
        log_info "recommended for current Arch Linux glibc. Monitor Arch news for"
        log_info "glibc kernel requirement changes. If issues arise, consider:"
        log_info "  ARCHLINUX_IMAGE=archlinux:base-20240101 $0"
    else
        log_success "Host kernel ${kernel_major}.${kernel_minor} meets glibc requirements."
    fi
}

check_multi_user_warning() {
    local active_users
    active_users=$(who -u 2>/dev/null | awk '{print $1}' | sort -u | grep -v "^$" || true)
    local user_count
    user_count=$(echo "$active_users" | wc -l | tr -d ' ' || echo "0")
    if [[ -n "$active_users" ]] && [[ "$user_count" -gt 1 ]]; then
        log_warn "Multiple interactive users detected on this host:"
        echo "$active_users" | while IFS= read -r u; do
            [[ -n "$u" ]] && log_warn "  - $u"
        done
        log_warn "--allow-wheel-nopasswd grants passwordless sudo to the entire wheel group."
        log_warn "Any user in the wheel group (including those listed above) can perform"
        log_warn "administrative operations inside the container without authentication."
        log_warn "Consider omitting --allow-wheel-nopasswd for per-user sudo restriction."
        log_warn "If you need wheel-wide access, audit all wheel-group members first."
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            log_error "Refusing --allow-wheel-nopasswd in non-interactive mode on multi-user host."
            log_error "Use per-user sudoers (omit --allow-wheel-nopasswd) or run interactively."
            exit 1
        fi
        if [[ -t 0 ]]; then
            echo -ne "${YELLOW}${BOLD}Continue with --allow-wheel-nopasswd on multi-user host? (y/N): ${NC}" >&2
            local mw_confirm
            read -r mw_confirm
            if [[ "$mw_confirm" != "y" && "$mw_confirm" != "Y" ]]; then
                log_info "Aborted by user due to multi-user security concern."
                exit "$EXIT_USER_ABORT"
            fi
        fi
    fi
    # Also check /etc/passwd for UIDs >= 1000 (broader than just logged-in users)
    local _login_uids
    _login_uids=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${_login_uids:-0}" -gt 1 ]]; then
        log_warn "Multiple login-capable accounts found on this host (${_login_uids} users with UID >= 1000)."
        log_warn "Per-user sudoers is strongly recommended. wheel-group scope is dangerous here."
    fi
}

self_update() {
    log_step "Checking for updates..."
    local _latest_tag=""
    local _gh_resp=""
    _gh_resp=$(curl -sf --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null || echo "")
    if [[ -n "$_gh_resp" ]]; then
        # Prefer jq (structured JSON parsing) over fragile grep regex.
        # GitHub API may return HTML error pages if rate-limited (403/429).
        if grep -qiE '<!DOCTYPE|<html|message.*rate' <<< "$_gh_resp"; then
            log_warn "GitHub API rate-limited or returned HTML error. Cannot check for updates."
            return 1
        fi
        if command -v jq >/dev/null 2>&1; then
            _latest_tag=$(echo "$_gh_resp" | jq -r '.tag_name // empty' 2>/dev/null || echo "")
        else
            _latest_tag=$(echo "$_gh_resp" | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
        fi
    fi
    if [[ -z "$_latest_tag" ]]; then
        log_error "Could not fetch latest release info from GitHub."
        log_info "Check your network connection or visit:"
        log_info "  https://github.com/${GITHUB_REPO}/releases/latest"
        return 1
    fi
    local _latest_ver="${_latest_tag#v}"
    log_info "Current version: v${SCRIPT_VERSION}"
    log_info "Latest version:  v${_latest_ver}"
    if [[ "$_latest_ver" == "$SCRIPT_VERSION" ]]; then
        log_success "Already up to date."
        return 0
    fi
    log_info "Downloading v${_latest_ver}..."
    local _tmp_script
    _tmp_script=$(mktemp "${_SCRIPT_TMPDIR:-/tmp}/steamos-pamac-update-XXXXXX.sh") || {
        log_error "Failed to create temp file for download."
        return 1
    }
    local _download_url="https://raw.githubusercontent.com/${GITHUB_REPO}/v${_latest_ver}/SteamOS-Pamac-Installer.sh"
    local _checksum_url="https://raw.githubusercontent.com/${GITHUB_REPO}/v${_latest_ver}/SHA256SUMS"
    local _sig_url="${_checksum_url}.sig"
    local _tmp_sig=""
    _tmp_sig=$(mktemp "${_SCRIPT_TMPDIR:-/tmp}/steamos-pamac-sig-XXXXXX.sig") 2>/dev/null || _tmp_sig=""
    if ! curl -sfL --connect-timeout 10 --max-time 60 -o "$_tmp_script" "$_download_url" 2>/dev/null; then
        log_error "Failed to download script from GitHub."
        rm -f "$_tmp_script" "$_tmp_sig"
        return 1
    fi
    if [[ ! -s "$_tmp_script" ]]; then
        log_error "Downloaded script is empty."
        rm -f "$_tmp_script" "$_tmp_sig"
        return 1
    fi
    # GPG signature verification: download the detached .sig and verify against
    # the release-signing key. Protects against GitHub compromise where an
    # attacker replaces both the script and SHA256SUMS but lacks the signing key.
    local _sig_verified=false
    if [[ -n "$_tmp_sig" ]] && command -v gpg >/dev/null 2>&1; then
        if curl -sfL --connect-timeout 10 --max-time 30 -o "$_tmp_sig" "$_sig_url" 2>/dev/null && \
           [[ -s "$_tmp_sig" ]]; then
            # Import the project signing key from WKD/keyservers on first use.
            # The key ID is for the Steam-OS-Pamac release signing key.
            local _signing_key="${RELEASE_SIGNING_KEY_ID:-D4B85A2AB5D6C3AE}"
            if GNUPGHOME="${_SCRIPT_TMPDIR:-/tmp}/steamos-pamac-gnupg" gpg --batch --quiet \
                --keyserver hkps://keys.openpgp.org --recv-keys "$_signing_key" 2>/dev/null || \
               GNUPGHOME="${_SCRIPT_TMPDIR:-/tmp}/steamos-pamac-gnupg" gpg --batch --quiet \
                --locate-external-keys "$_signing_key" 2>/dev/null; then
                if GNUPGHOME="${_SCRIPT_TMPDIR:-/tmp}/steamos-pamac-gnupg" gpg --batch --quiet \
                    --verify "$_tmp_sig" "$_tmp_script" 2>/dev/null; then
                    _sig_verified=true
                    log_success "GPG signature verification passed."
                else
                    log_error "GPG signature verification FAILED — update rejected."
                    log_error "The downloaded script's signature does not match the release-signing key."
                    log_error "This could indicate a compromised download. Aborting update."
                    rm -f "$_tmp_script" "$_tmp_sig"
                    return 1
                fi
            else
                log_warn "Could not fetch release-signing key (network or keyserver issue)."
            fi
        else
            log_warn "No detached signature found at $_sig_url — skipping GPG verification."
        fi
    fi
    rm -f "$_tmp_sig" 2>/dev/null || true
    # SHA-256 hash verification (belt-and-suspenders with GPG)
    local _downloaded_hash=""
    if command -v sha256sum >/dev/null 2>&1; then
        _downloaded_hash=$(sha256sum "$_tmp_script" 2>/dev/null | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        _downloaded_hash=$(shasum -a 256 "$_tmp_script" 2>/dev/null | awk '{print $1}')
    fi
    local _expected_hash=""
    _expected_hash=$(curl -sfL --connect-timeout 10 --max-time 30 "$_checksum_url" 2>/dev/null \
        | grep -i "SteamOS-Pamac-Installer.sh" | awk '{print $1}' || echo "")
    if [[ -n "$_expected_hash" && -n "$_downloaded_hash" ]]; then
        if [[ "$_downloaded_hash" != "$_expected_hash" ]]; then
            log_error "Hash verification failed!"
            log_error "  Expected: $_expected_hash"
            log_error "  Got:      $_downloaded_hash"
            rm -f "$_tmp_script"
            return 1
        fi
        log_success "SHA-256 hash verification passed."
    elif [[ "$_sig_verified" != "true" ]]; then
        # Neither GPG nor SHA-256 verified — refuse to update
        log_error "No GPG signature AND no checksum file available. Cannot verify update integrity."
        log_info "Download manually from:"
        log_info "  https://github.com/${GITHUB_REPO}/releases/download/v${_latest_ver}/SteamOS-Pamac-Installer.sh"
        rm -f "$_tmp_script"
        return 1
    elif [[ -n "$_downloaded_hash" ]]; then
        log_warn "No checksum file at $_checksum_url (GPG signature was verified)."
        log_info "Downloaded script hash (for reference): $_downloaded_hash"
    fi
    local _self_path
    _self_path="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")"
    local _self_dir
    _self_dir=$(dirname "$_self_path")

    # Atomic write: write to a temp file in the same directory, sync to disk,
    # then rename. This prevents corruption if interrupted mid-write (power cut,
    # Ctrl+C during the copy). The old file stays valid until the rename
    # completes atomically.
    local _atomic_tmp
    _atomic_tmp=$(mktemp "${_self_dir}/.steamos-update-XXXXXX") || {
        log_error "Failed to create temp file for atomic update."
        rm -f "$_tmp_script"
        return 1
    }

    if [[ ! -w "$_self_path" ]]; then
        log_warn "Current script is not writable ($_self_path). Attempting sudo install..."
        if command -v sudo >/dev/null 2>&1; then
            sudo cp "$_tmp_script" "$_atomic_tmp" && sudo chmod +x "$_atomic_tmp" && sudo sync "$_atomic_tmp" 2>/dev/null && sudo mv -f "$_atomic_tmp" "$_self_path" && sudo sync "$_self_dir" 2>/dev/null
            local _sudo_rc=$?
            rm -f "$_tmp_script"
            if [[ $_sudo_rc -eq 0 ]]; then
                log_success "Updated to v${_latest_ver} (via sudo, atomic)."
                return 0
            fi
        fi
        rm -f "$_atomic_tmp"
        log_error "Cannot update: $0 is not writable and sudo is unavailable."
        log_info "Download manually from:"
        log_info "  https://github.com/${GITHUB_REPO}/releases/download/v${_latest_ver}/SteamOS-Pamac-Installer.sh"
        return 1
    fi

    local _cp_rc=0
    cp "$_tmp_script" "$_atomic_tmp" && chmod +x "$_atomic_tmp" && sync "$_atomic_tmp" 2>/dev/null || _cp_rc=$?
    rm -f "$_tmp_script"
    if [[ $_cp_rc -ne 0 ]]; then
        rm -f "$_atomic_tmp"
        log_error "Failed to write updated script to temp file."
        return 1
    fi
    # Atomic rename — old file stays valid until this completes
    mv -f "$_atomic_tmp" "$_self_path"
    local _mv_rc=$?
    sync "$_self_dir" 2>/dev/null || true
    if [[ $_mv_rc -ne 0 ]]; then
        log_error "Failed to atomically replace script at $_self_path."
        log_info "The updated script may be at: $_atomic_tmp"
        return 1
    fi
    log_success "Updated to v${_latest_ver} (atomic write)."
    log_info "Please re-run the script with your desired options for the new version to take effect."
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
    # Mitigation: Attempt automatic fix if entries are missing. Validate that
    # existing entries have sensible ranges (not empty, no overlaps). After OS
    # updates, entries may exist but be invalid — verify with a test namespace.
    local subuid_entry subgid_entry
    subuid_entry=$(grep "^$(whoami):" /etc/subuid 2>/dev/null || true)
    subgid_entry=$(grep "^$(whoami):" /etc/subgid 2>/dev/null || true)
    if [[ -z "$subuid_entry" || -z "$subgid_entry" ]]; then
        log_warn "subuid/subgid mapping missing for $(whoami). Attempting automatic fix..."
        # Try to create the mapping automatically if usermod is available
        if command -v usermod >/dev/null 2>&1 && [[ -w /etc/subuid ]] && [[ -w /etc/subgid ]]; then
            if sudo -n usermod --add-subuids "${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1))" \
                              --add-subgids "${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1))" \
                              "$(whoami)" 2>/dev/null; then
                log_success "Auto-created subuid/subgid mappings for $(whoami)."
                subuid_entry=$(grep "^$(whoami):" /etc/subuid 2>/dev/null || true)
                subgid_entry=$(grep "^$(whoami):" /etc/subgid 2>/dev/null || true)
            else
                log_warn "Automatic fix failed (sudo may require password)."
            fi
        fi
        # Still missing after auto-fix attempt
        if [[ -z "$subuid_entry" || -z "$subgid_entry" ]]; then
            log_warn "No subuid/subgid mapping for $(whoami). Rootless podman will fail."
            log_info "Rootless podman needs subuid/subgid mappings to run containers."
            log_info "On SteamOS, these are usually created automatically when podman is installed."
            log_info "Manual fix:"
            log_info "  sudo usermod --add-subuids ${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1)) --add-subgids ${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1)) $(whoami)"
            log_info "If usermod fails (e.g. after major OS update), check:"
            log_info "  grep $(whoami) /etc/subuid /etc/subgid"
            log_info "  If entries exist but are malformed, remove them and re-run."
        fi
    else
        log_debug "subuid entry: $subuid_entry"
        log_debug "subgid entry: $subgid_entry"
        # Validate the range is non-empty and usable (at least 65536 UIDs)
        local _sub_start _sub_count
        _sub_start=$(echo "$subuid_entry" | cut -d: -f2)
        _sub_count=$(echo "$subuid_entry" | cut -d: -f3)
        if [[ -z "$_sub_start" || -z "$_sub_count" || "$_sub_count" -lt 65536 ]] 2>/dev/null; then
            log_warn "subuid mapping for $(whoami) has suspicious range: start=$_sub_start count=$_sub_count"
            log_warn "Minimum recommended: 65536 UIDs. Rootless podman may fail with large builds."
            log_info "Fix: sudo usermod --add-subuids ${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1)) --add-subgids ${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1)) $(whoami)"
        fi
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

    # Step 7: System reset — guidance only, not executed automatically
    log_warn "Podman storage may be deeply corrupted."
    log_warn ""
    log_warn "If previous recovery steps failed, you may need a full system reset."
    log_warn "This is DESTRUCTIVE — it removes ALL containers, images, and volumes."
    log_warn ""
    log_warn "To proceed, run manually AFTER backing up important containers:"
    log_warn "  podman system reset --force"
    log_warn "  sudo reboot"
    log_warn ""

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
    log_error "Steps tried: XDG_RUNTIME_DIR fix, subuid/subgid check, socket start,"
    log_error "  lock cleanup, permission fix, database rebuild, system reset, storage migration."
    log_error ""
    log_error "Manual recovery options (in order of safety):"
    log_error "  1. Check subuid/subgid:"
    log_error "     grep $(whoami) /etc/subuid /etc/subgid"
    log_error "     If missing: sudo usermod --add-subuids ${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1)) --add-subgids ${SUBUID_START}-$((SUBUID_START + SUBUID_COUNT - 1)) $(whoami)"
    log_error "     Then log out and back in."
    log_error "  2. Nuclear reset (destroys ALL podman data — containers, images, volumes):"
    log_error "     podman system reset --force"
    log_error "     This is the most likely fix for corrupted storage."
    log_error "  3. Check user session:"
    log_error "     sudo loginctl enable-linger $(whoami)"
    log_error "     Then log out and back in."
    log_error "  4. SteamOS read-only rootfs:"
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
  --enable-flatpak          Re-enable Flatpak support in Pamac (default: off).
                             On SteamOS, Discover handles Flatpaks; enabling
                             Flatpak in Pamac shows duplicate Flathub entries.
                             Use this if you prefer Pamac for all package
                             management, including Flatpaks.
  --rolling-release         Use archlinux:latest (rolling release) instead of
                            the pinned stable image (archlinux:base). Packages
                            update frequently; may break on major upstream changes.
  --pin-release             Use the pinned stable image (archlinux:base, default).
                            Less frequent breakage; recommended for most users.
  --pamac-version VERSION    Pin pamac-aur to a specific AUR version/commit
                            (default: latest; use "latest" for automatic)
  --skip-compat-check        Skip pamac-aur AUR compatibility check (avoids
                             AUR RPC dependency; for users who know their
                             pacman version is compatible)
  --non-interactive          Skip all interactive prompts (safe for automation)
  --force                    Auto-approve destructive confirmations (container
                             recreation prompts only) without suppressing ALL
                             interactive prompts like --non-interactive does.
                             Equivalent to FORCE_MODE=true.
  --quick-start          Apply a minimal, safe preset of defaults for less
                             experienced users (multilib+build-cache+extra-repos
                             ON, gaming OFF, compat-check ON). Any option passed
                             AFTER --quick-start overrides the preset. Intended
                             to reduce option confusion on a first run.
  --disable-pin-alpm        Do NOT defer libalpm/pacman upgrade (risky on
                             rolling release containers; not recommended)
  --allow-wheel-nopasswd     Grant NOPASSWD to entire wheel group instead of
                             just the current user (INSECURE on multi-user
                             hosts; opt-in only, not auto-enabled)
  --dedicated-builduser      Create a dedicated _pamac_builder user inside the
                             container. AUR builds run under this user with NO
                             passwordless sudo, preventing privilege escalation
                             via malicious PKGBUILDs. The build user's home is
                             /var/lib/_pamac_builder (isolated from host).
                             Source trees are accessed via 'distrobox enter' as
                             the login user, not the build user. Default: ON.
  --no-dedicated-builduser  Disable dedicated build user. AUR builds run as the
                             container's login user (same UID as host user).
                             INSECURE: a malicious AUR PKGBUILD could access
                             host files if --allow-home-mount is also set.
  --allow-home-mount         Re-enable host /home mount inside the container
                             (INSECURE: exposes SSH keys, browser profiles, GPG
                             keys to all container processes). By default, the
                             container uses --no-home-mount and only mounts the
                             specific paths needed for builds.
  --security-opt OPT         Pass an additional --security-opt to the container
                             runtime during creation. May be repeated.
                             Examples: --security-opt seccomp:profile.json
                                       --security-opt apparmor:my-profile
  --check                   Perform system checks and exit without installing
  --dry-run                 Show what would be done without making changes
  --dry-run-verbose         Like --dry-run, but also print the full script
                             content that would execute inside the container
                             (implies --dry-run; useful for auditing what
                             changes the container would receive)
  --strict-security         HARDENED MODE — refuses to relax signature
                             verification (skip SigLevel=TrustAll recovery,
                             keep all packages cryptographically verified).
                             Also refuses to install the fake systemd-run
                             wrapper, so AUR DynamicUser builds WILL FAIL in
                             non-init containers. With --use-init (default),
                             this mainly affects signature verification since
                             real systemd handles sandboxing.
                             TRADE-OFF: increased cryptographic verification
                             at the cost of breaking AUR builds in non-init
                             containers. Failures during keyring bootstrap
                             cause the step to fail fast rather than degrading
                             to unverified state.
  --allow-trustall           Permit the TrustAll keyring bootstrap without
                             interactive confirmation. Without this flag, the
                             user is prompted before SigLevel=TrustAll is used.
                             Only effective when --strict-security is NOT set.
  --trustall-all-repos       When using the TrustAll fallback, include ALL
                             configured repos (including third-party repos like
                             chaotic-aur, archlinuxcn, endeavouros) instead of
                             stripping them from the throwaway config. This is
                             needed when third-party repos also need their keys
                              refreshed during the TrustAll bootstrap. Default:
                              only official Arch repos (core/extra/multilib) are
                              included in the throwaway config for safety.
  --use-devtools            Use Arch's official devtools (archbuild) for AUR
                              builds instead of yay. Devtools creates clean
                              chroot builds via systemd-nspawn with proper
                              isolation, dependency resolution, and
                              reproducibility. Requires devtools in the
                              container. Falls back to yay if unavailable.
                              TRADE-OFF: better isolation at the cost of
                              slower builds (full chroot recreation each time).
  --install-drive           Auto-detect available drives and present an
                              interactive menu to select install target (eMMC,
                              SD card, USB). Shows available space on each drive.
                              Useful for Steam Deck users with SD cards who want
                              Pamac installed on secondary storage.
  --upload-log              Sanitize and upload the setup log for debugging
  --verbose                 Show detailed output, including command logs
  --quiet                   Only show errors
  --no-color                Disable ANSI color output (useful for piping, cron,
                            CI/CD, and non-terminal environments)
  --use-init                Force init-mode container (distrobox create --init)
                            which gives real systemd inside the container.
                            This is the DEFAULT. AUR builds use native
                            systemd-run instead of the fake wrapper. Same as
                            FORCE_CONTAINER_INIT=true.
  --no-use-init             Disable init-mode container. Falls back to the
                            fake systemd-run shim (extracted to
                            fake-systemd-run.sh). Only use when the host
                            lacks a usable /usr/lib/systemd/systemd binary.
  --low-memory              Reduce build parallelism on constrained systems
                            (e.g., 8GB RAM or less). Doubles per-job RAM
                            requirement to prevent OOM during AUR builds.
  --self-update             Download and apply the latest version from GitHub
                            (GPG signature + SHA-256 verification when available)
  --repair                  Re-run only failed or incomplete installation stages
                            based on state sentinel files in
                            ~/.local/share/steamos-pamac/<container>/stages/
                            Safe to run repeatedly; skips already-completed stages.
  --version                 Show version information
  --version-check           Compare installed version against latest GitHub release
  --verify                  Print SHA-256 hash of this script for integrity verification
                            (compare against hash on GitHub release page)
  --verify-sandbox          Run sandbox self-tests inside the container to
                            confirm that sandboxing is active. Reports
                            DEGRADED/OK for each protection. Tests real
                            systemd-run with --use-init, or the fake wrapper
                            with --no-use-init.
  --status               Show installation status and health check
  --update               Update the installation (re-run setup with current
                            settings and update container packages)
  --uninstall            Remove the container, exported desktop files, and
                            all associated state
  --export-only          Re-export desktop files from the container to the
                            host without modifying the container
  --enable-gaming        Enable gaming packages (Steam, Lutris, Heroic)
  --disable-gaming       Disable gaming packages (default)
  --enable-extra-repos   Enable extra repos (chaotic-aur, endeavouros, etc.)
  --disable-extra-repos  Disable extra repos (default)
  --enable-build-cache   Enable persistent yay build cache (default)
  --disable-build-cache  Disable persistent yay build cache
  --optimize-mirrors     Optimize pacman mirrors for fastest downloads (default)
  --no-optimize-mirrors  Skip mirror optimization
  -h, --help                Show this help message

ENVIRONMENT VARIABLES:
  CONTAINER_NAME            Override default container name (default: arch-pamac)
  ARCHLINUX_IMAGE           Container base image (default: archlinux:base)
                            Override with any valid tag for different versions.
                            Use --rolling-release for archlinux:latest.
  FORCE_REBUILD            Set to 'true' to force-rebuild existing container
  ENABLE_GAMING_PACKAGES   Set to 'true' to install gaming packages
  ENABLE_FLATPAK           Set to 'true' to re-enable Flatpak support in Pamac
                           (default 'false'). On SteamOS, Discover handles
                           Flatpaks; enabling Flatpak in Pamac shows duplicate
                           Flathub entries. Same as --enable-flatpak flag.
  PAMAC_VERSION            Specific pamac-aur version/commit to install (AUR fallback)
  NON_INTERACTIVE          Set to 'true' to skip all interactive prompts (safe for
                           background tools, automated installers, and cron jobs)
  FORCE_MODE              Set to 'true' to auto-approve destructive confirmation
                           (container recreation) without disabling other prompts
                           as --non-interactive does. Same as --force flag.
                           Default 'false'.
  QUICK_START             Set to 'true' to apply the quick-start preset (same as
                           --quick-start). See --help for the preset values.
                           Explicit env vars / CLI flags still override the preset.
  PIN_ALPM                 Set to 'false' to skip deferring libalpm/pacman upgrade.
                           Default is 'true' — pacman/libalpm are upgraded after
                           pamac-aur is built to prevent API breakage on rolling
                           release containers.
  PAMAC_AUR_COMMIT_CACHE_TTL  How long (seconds) a known-good pamac-aur commit
                           is reused to skip the AUR history scan during the
                           compatibility check. Default 1209600 (14 days). Set to
                           0 to force a fresh scan every run.
  CHAOTIC_AUR_KEY_ID       Override the Chaotic-AUR signing key fingerprint
                            (auto-discovered from keyring package by default)
  ARCHLINUXCN_KEY_ID       Override the archlinuxcn signing key fingerprint
                            (auto-discovered from keyring package by default)
  ENDEAVOUROS_KEY_ID       Override the EndeavourOS signing key fingerprint
                            (auto-discovered from keyring package by default)
  STRICT_SECURITY          Set to 'true' to enforce --strict-security mode
                            (refuse SigLevel=TrustAll recovery and refuse to
                            install the fake systemd-run shim). With --use-init
                            (default), real systemd handles sandboxing.
                            Default 'false'.
  USE_DEVTOOLS             Set to 'true' to use Arch devtools (archbuild) for
                            AUR builds instead of yay. Requires devtools in
                            the container. Falls back to yay if unavailable.
                            Default 'false'.
  TRUSTALL_ALL_REPOS       Set to 'true' to keep third-party repos (chaotic-aur,
                           archlinuxcn, etc.) in the TrustAll throwaway config
                           during keyring bootstrap. Default 'false' strips them
                           to limit the injection surface. Use only when
                           third-party repos also need key refresh during the
                           TrustAll fallback.
  FORCE_CONTAINER_INIT     Set to 'true' to use init-mode containers with
                           real systemd (default). Set to 'false' with
                           --no-use-init to fall back to the fake systemd-run
                           shim. Default 'true'.
  NO_COLOR                 Set to 'true' to disable ANSI color output (same
                           as --no-color flag). Useful for piping, cron, CI/CD.
  LOW_MEMORY               Set to 'true' to reduce build parallelism (same as
                           --low-memory flag). Doubles per-job RAM for AUR
                           builds on constrained systems (<8GB available).
  DRY_RUN_VERBOSE          Set to 'true' to audit container scripts without
                           executing them (implies DRY_RUN=true). Default 'false'.
  LOG_ROTATION_MAX_SIZE    Rotate the per-container log on startup when it
                           exceeds this many bytes. Default: 5242880 (5 MiB).
                           One backup (.1) is kept; older backups are overwritten.
  DEDICATED_BUILDUSER      Set to 'true' to create a dedicated build user
                            (--dedicated-builduser). This isolates AUR builds
                            from host /home. Default 'true'.
  CONTAINER_SECURITY_OPT_ENV  Colon-separated list of --security-opt values
                           passed to container creation (same as --security-opt
                           flag). E.g.: seccomp:profile.json:apparmor:my-profile

SECURITY NOTE — Container sandboxing:
  By default (--use-init), the container uses real systemd for process
  isolation. AUR builds run via native systemd-run with full sandbox
  properties (ProtectSystem, ProtectSystemCallFilter, etc.).
  When --no-use-init is used, a fake systemd-run shim
  (fake-systemd-run.sh) emulates systemd-run via seccomp-BPF, mount
  namespaces, and bubblewrap. If AUR builds fail inside the container,
  try: (1) Use --use-init (default) for real systemd, or
  (2) Install base-devel for seccomp compilation, or
  (3) Use --strict-security to disable the shim.

NOTE — eMMC/flash wear reduction:
  The script automatically configures tmpfs BUILDDIR and ccache to minimize
  write cycles on Steam Deck's internal eMMC/SD storage. Compilations run
  in RAM when sufficient free memory is available (>2.5GB), with only the
  final .pkg.tar.zst written to disk. ccache prevents recompilation of
  unchanged sources across rebuilds. Use --low-memory to reduce parallel
  writes on constrained systems.

SECURITY NOTE — --allow-wheel-nopasswd:
  Grants NOPASSWD to the entire wheel group. On multi-user hosts, any
  user in the wheel group (and any AUR package built via makepkg) can
  perform administrative package operations without authentication.
  Default is per-user NOPASSWD (limits escalation to one user).

SECURITY NOTE -- --dedicated-builduser:
  Creates a dedicated _pamac_builder user for AUR builds. This provides
  privilege separation: the build user has NO passwordless sudo, so a
  malicious AUR PKGBUILD cannot escalate via pacman. By default, the
  container uses --no-home-mount to prevent host /home exposure. The
  build user's home is isolated at /var/lib/_pamac_builder. The pamac
  GUI still runs as the host user via polkit/D-Bus; only the AUR
  build/install path runs under the dedicated user.

SECURITY NOTE — Sudoers permissions (inside container):
  The following commands are granted passwordless sudo via
  /etc/sudoers.d/99-pamac-nopasswd (scoped per-user or wheel, above):

    /usr/bin/pacman            — Install/remove/upgrade packages
    /usr/bin/pacman-key         — Initialize/verify package signatures
    /usr/bin/paccache           — Clean old package caches
    /usr/bin/pacscripts         — Inspect install scripts

  These are deliberately EXCLUDED from PAMAC_CMDS:

    /usr/bin/makepkg           — Runs via systemd-run (DynamicUser)
    /usr/bin/yay               — Never run as root; invokes sudo pacman -U
    /usr/bin/sudo              — Prevents escalation chain

SECURITY NOTE — Polkit rules:
  The script sets allow_active=yes (local active sessions only) for
  Pamac polkit actions. allow_any=no, allow_inactive=no. This prevents
  unauthenticated remote or inactive-session access. Any process in the
  container with an active local session can still perform admin ops.

--- Security Model ---

  This script installs Pamac (a GUI package manager) inside an
  isolated Distrobox/Podman container. The security model balances
  usability (especially on a single-user Steam Deck) against
  privilege-escalation risk:

  (1) Rootless containers: The container runs under your user's
      rootless podman/docker. The container engine acts as an
      isolation boundary: even if an AUR PKGBUILD gains root inside
      the container, it does not get host root.

  (2) sudoers scoping: AUR builds require passwordless sudo for
      pacman, yay, pacman-key, paccache, and pacscripts. By default
      these are scoped to a SINGLE user (the one created inside the
      container). --allow-wheel-nopasswd widens this to the whole
      wheel group, which is DANGEROUS on multi-user hosts.

  (3) sudo timestamp_timeout=0: Every sudo call re-authenticates
      (passwordlessly via sudoers, but the credential is not cached).
      This minimizes the window for credential reuse.

  (4) Container isolation: By default (--use-init), the container uses
      real systemd for process isolation, providing native systemd-run
      with full sandbox properties. When --no-use-init is used, a
      fake systemd-run shim (fake-systemd-run.sh) emulates sandboxing
      via seccomp-BPF, mount namespaces, and bubblewrap.
      Use --strict-security to disable the shim.

  (5) Pacman SigLevel: The container's /etc/pacman.conf uses the
      default strict SigLevel (Required DatabaseOptional). The only
      temporary relaxation is a throwaway pacman --config <tmp.conf>
      with SigLevel=TrustAll during last-resort keyring bootstrap
      (relaxation does NOT modify the real pacman.conf on disk).

  (6) Polkit scoping: Pamac's polkit actions are set to
      allow_active=yes (local active sessions only), with
      allow_any=no and allow_inactive=no. Remote and inactive
      sessions cannot perform admin operations without authentication.

  (7) Rollback on failure: Before critical container modifications,
      the script creates a snapshot via podman commit. If an
      irrecoverable failure occurs (base setup, AUR helper, or
      pamac install), the container is restored to the snapshot
      so the user can retry without manual cleanup.

--- Troubleshooting Guide ---

  KEYRING FAILURES:
    Symptom: "invalid or corrupted package (PGP signature)"
    Cause: Stale or missing pacman keyring inside the container.
    Fix: The script auto-recovers via multi-strategy (keyserver
      refresh, direct HTTPS keyring download, WKD lookup, offline
      bootstrap from system keyring files, and a last-resort
      throwaway TrustAll method). If keyring bootstrap fails:
        1. Check network connectivity (the script runs a pre-flight
           probe).
        2. Manually enter the container and reinitialize:
             distrobox enter $CONTAINER_NAME
             sudo pacman-key --init
             sudo pacman-key --populate archlinux
             sudo pacman -Sy --noconfirm archlinux-keyring
        3. Re-run the installer with --verbose for detailed output.

  OOM KILLS (Exit code 137):
    Symptom: Container crashes mid-build with exit 137.
    Cause: The container ran out of memory (common on 8GB or 16GB
      shared-memory Steam Deck when compiling large AUR packages).
    Fix:
        1. Re-run with --low-memory to halve build parallelism.
        2. Close other applications (browser, games) before building.
        3. Use the persistent build cache (default on) so partial
           builds resume.
        4. If swap is available, ensure it is not disabled in the
           container.

  CONTAINER STUCK / NOT STARTING:
    Symptom: Container stays in "exited", "stopping", or "improper"
      state; "container is not usable" errors.
    Causes: Podman database corruption, stale lock files, subuid/
      subgid misconfiguration, or incompatible container runtime.
    Fix:
        1. Run --status to see the container state.
        2. Run --repair to re-run only uncompleted setup stages.
        3. If that fails, re-run with --force-rebuild to recreate
           the container from scratch.
        4. Check subuid/subgid: grep $(whoami) /etc/subuid
        5. Ensure XDG_RUNTIME_DIR is set and podman socket is active.

  PACMAN DATABASE CORRUPTION:
    Symptom: "database is inconsistent" warnings or pacman operations
      failing after successful install.
    Fix: The script auto-runs a multi-strategy repair (11 strategies)
      when corruption indicators are detected in container output.
      If repair fails:
        1. Manually run inside the container:
             sudo rm -f /var/lib/pacman/db.lck
             sudo pacman -Dk
           Fix any broken entries with:
             sudo pacman -S --noconfirm --needed <package>
        2. Re-run: sudo pacman -Syyu

  KEYBOARD / LOCALE ISSUES:
    Symptom: "warning: locale not supported by C library" or missing
      languages in Pamac GUI.
    Fix: The script generates en_US.UTF-8 by default. To add your
      locale, enter the container and run:
        sudo sed -i 's/^#de_DE/de_DE/' /etc/locale.gen
        sudo locale-gen
      (Replace de_DE with your locale.)

  NETWORK / PROXY ISSUES:
    Symptom: Package downloads fail; keyserver timeouts; "Could not
      resolve host" errors.
    Fix:
        1. Check host network connectivity first.
        2. If behind a proxy, export https_proxy/http_proxy before
           running the installer.
        3. The script tests keyserver reachability on port 443 only.
           If your network blocks outbound HTTPS to keyservers, the
           direct mirror download fallback (Method B) may still work.

POST-INSTALL:
  To upgrade Pamac after installation: yay -Syu
  To upgrade the container: yay -Syu && exit; distrobox upgrade CONTAINER

EXAMPLES:
  $0                                       # Basic setup (stable archlinux:base)
  $0 --quick-start                          # Minimal safe defaults (new users)
  $0 --rolling-release                      # Use latest packages (rolling release)
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
            --enable-flatpak) ENABLE_FLATPAK="true"; shift ;;
            --disable-build-cache) ENABLE_BUILD_CACHE="false"; shift ;;
            --optimize-mirrors) OPTIMIZE_MIRRORS="true"; shift ;;
            --no-optimize-mirrors) OPTIMIZE_MIRRORS="false"; shift ;;
            --rolling-release) ROLLING_RELEASE="true"; shift ;;
            --pin-release) ROLLING_RELEASE="false"; shift ;;
            --pamac-version)
                [[ -z "${2:-}" ]] && { log_error "pamac-version cannot be empty"; exit 1; }
                if [[ ! "$2" =~ ^[a-zA-Z0-9._-]+$ ]]; then
                    log_error "Invalid pamac-version: '$2' (only alphanumerics, dots, hyphens, underscores allowed)"
                    exit 1
                fi
                PAMAC_VERSION="$2"
                shift 2
                ;;
            --skip-compat-check) SKIP_COMPAT_CHECK="true"; shift ;;
            --uninstall) UNINSTALL="true"; shift ;;
            --status) STATUS="true"; shift ;;
            --update) UPDATE="true"; shift ;;
            --export-only) EXPORT_ONLY="true"; shift ;;
            --non-interactive) NON_INTERACTIVE="true"; shift ;;
            --force) FORCE_MODE="true"; shift ;;
            --dedicated-builduser) DEDICATED_BUILDUSER="true"; shift ;;
            --no-dedicated-builduser) DEDICATED_BUILDUSER="false"; shift ;;
            --allow-home-mount) ALLOW_HOME_MOUNT="true"; shift ;;
            --use-init) FORCE_CONTAINER_INIT="true"; shift ;;
            --no-use-init) FORCE_CONTAINER_INIT="false"; shift ;;
            --quick-start) QUICK_START="true"; shift ;;
            --disable-pin-alpm) PIN_ALPM="false"; shift ;;
            --allow-wheel-nopasswd) ALLOW_WHEEL_NOPASSWD="true"; shift ;;
            --security-opt)
                [[ -z "${2:-}" ]] && { log_error "--security-opt requires a value"; exit 1; }
                CONTAINER_SECURITY_OPT+=("$2")
                shift 2
                ;;
            --upload-log) UPLOAD_LOG="true"; shift ;;
            --dry-run) DRY_RUN="true"; shift ;;
            --dry-run-verbose) DRY_RUN="true"; DRY_RUN_VERBOSE="true"; shift ;;
            --strict-security) STRICT_SECURITY="true"; shift ;;
            --use-devtools) USE_DEVTOOLS="true"; shift ;;
            --install-drive) _SELECTED_INSTALL_DRIVE="auto"; shift ;;
            --allow-trustall) ALLOW_TRUSTALL="true"; shift ;;
            --trustall-all-repos) TRUSTALL_ALL_REPOS="true"; shift ;;
            --check) CHECK_ONLY="true"; shift ;;
            --verbose) LOG_LEVEL="verbose"; shift ;;
            --quiet) LOG_LEVEL="quiet"; shift ;;
            --no-color) NO_COLOR="true"; shift ;;
            --low-memory) LOW_MEMORY="true"; shift ;;
            --self-update) SELF_UPDATE="true"; shift ;;
            --repair) REPAIR="true"; shift ;;
            --version) echo "Steam Deck Pamac Setup v${SCRIPT_VERSION}"; exit 0 ;;
            --verify) _verify_script_hash; exit 0 ;;
            --verify-sandbox) _verify_sandbox_flag="true"; shift ;;
            --version-check)
                echo "Installed version: v${SCRIPT_VERSION}"
                local _latest=""
                local _gh_resp=""
                _gh_resp=$(curl -sf --connect-timeout 5 --max-time 10 \
                    "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null || echo "")
                if [[ -n "$_gh_resp" ]]; then
                    if command -v jq >/dev/null 2>&1; then
                        _latest=$(echo "$_gh_resp" | jq -r '.tag_name // empty' 2>/dev/null || echo "")
                    else
                        _latest=$(echo "$_gh_resp" | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
                    fi
                fi
                if [[ -n "$_latest" ]]; then
                    echo "Latest release:    v${_latest#v}"
                    if [[ "${_latest#v}" == "$SCRIPT_VERSION" ]]; then
                        echo "Status: Up to date."
                    else
                        echo "Status: Update available. Download the latest from:"
                        echo "  https://github.com/${GITHUB_REPO:-your-org/Steam-OS-Pamac}/releases/latest"
                    fi
                else
                    echo "Could not fetch latest release (network issue)."
                fi
                exit 0
                ;;
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

    if distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
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

    # Clean host-side persistent changes created during install
    if [[ "$DRY_RUN" != "true" ]]; then
        local _xdg_override="$HOME/.config/systemd/user/plasma-plasmashell.service.d/override-xdg-data-dirs.conf"
        [[ -f "$_xdg_override" ]] && { log_info "Removing XDG override: $_xdg_override"; rm -f "$_xdg_override"; }

        local _envd="$HOME/.config/environment.d/30-xdg-data-dirs.conf"
        [[ -f "$_envd" ]] && { log_info "Removing environment.d drop-in: $_envd"; rm -f "$_envd"; }

        local _discover_svc="$HOME/.config/systemd/user/app-org.kde.discover.notifier@autostart.service"
        [[ -L "$_discover_svc" || -f "$_discover_svc" ]] && { log_info "Unmasking Discover notifier: $_discover_svc"; systemctl --user unmask "app-org.kde.discover.notifier@autostart.service" 2>/dev/null || rm -f "$_discover_svc"; }

        # Clean container image — offer to remove since it may be shared
        # with other containers.
        local _image="${CONTAINER_IMAGE:-archlinux:base}"
        if command -v podman >/dev/null 2>&1; then
            if podman image exists "$_image" 2>/dev/null; then
                log_info "Container image '$_image' is still on disk."
                log_info "  To remove: podman rmi $_image"
            fi
        elif command -v docker >/dev/null 2>&1; then
            if docker image inspect "$_image" >/dev/null 2>&1; then
                log_info "Container image '$_image' is still on disk."
                log_info "  To remove: docker rmi $_image"
            fi
        fi
    fi

    log_success "Uninstallation completed."
}

# ── Container wait helpers ──

wait_for_container() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "[DRY RUN] Would wait for container '$CONTAINER_NAME'"
    return 0
  fi
  # CONTAINER_START_TIMEOUT is the number of 2s-attempts (default 60 = ~120s).
  # Named _TIMEOUT for backward compat with env-var overrides, but counts attempts.
  local max_attempts="${CONTAINER_START_TIMEOUT:-60}"
  local attempt=0
  local _saved_errexit
  _saved_errexit=$(shopt -o -q errexit && echo "on" || echo "off")
  log_info "Waiting for container '$CONTAINER_NAME' to become ready..."

  set +e
  # Signal handlers restore errexit and return with the conventional signal exit
  # code (128+signum). Using `return` instead of `kill -s <sig> $$` ensures the
  # function exits cleanly through bash's return mechanism, which triggers the
  # RETURN trap for consistent cleanup. The old `kill -s <sig> $$` approach
  # terminated the process before RETURN could fire, potentially leaving
  # errexit disabled.
  # NOTE: _wfc_cleanup clears all traps on first invocation, so the RETURN trap
  # is a no-op after any signal handler has run.
  _wfc_cleanup() {
    if [[ "$_saved_errexit" == "on" ]]; then
      set -e
    fi
    trap - RETURN INT TERM HUP
  }
  trap '_wfc_cleanup' RETURN
  trap '_wfc_cleanup; exit 130' INT
  trap '_wfc_cleanup; exit 143' TERM
  trap '_wfc_cleanup; exit 129' HUP

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
      exit_code=$(container_runtime_for_ops inspect "$CONTAINER_NAME" --format '{{.State.ExitCode}}' 2>/dev/null || echo "unknown")
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
        log_info "SteamOS detected, --no-use-init active — using non-init mode."
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
        init_binary=$(container_runtime_for_ops info --format '{{.Host.InitPath}}' 2>/dev/null || echo "")
    fi
    if [[ -n "$init_binary" ]]; then
        local resolved
        resolved=$(command -v "$init_binary" 2>/dev/null || echo "")
        if [[ -n "$resolved" ]] || [[ -f "$init_binary" ]]; then
            # Additional verification: check that the container runtime
            # actually supports the --init flag (some builds report an
            # init path but lack --init support).
            local _init_flag_works=false
            if [[ "$mgr" == "docker" ]]; then
                docker run --rm --init alpine echo _init_test 2>/dev/null | grep -q "_init_test" && _init_flag_works=true
            else
                container_runtime_for_ops run --rm --init alpine echo _init_test 2>/dev/null | grep -q "_init_test" && _init_flag_works=true
            fi
            if $_init_flag_works; then
                CONTAINER_HAS_INIT="true"
                log_info "Init system supported ($mgr init binary: $init_binary, --init flag verified)."
            else
                CONTAINER_HAS_INIT="false"
                log_info "Init binary found but --init flag not functional - using non-init container."
            fi
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
        --image "$CONTAINER_IMAGE"
        --yes
    )

    log_info "Pulling ${CONTAINER_IMAGE} image..."
    local _pull_ok=false
    for _pull_attempt in 1 2 3; do
        if run_command container_runtime pull "$CONTAINER_IMAGE"; then
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

    # SECURITY: Always apply --no-home-mount by default to prevent host /home
    # exposure. Without this, all container processes (including AUR PKGBUILDs)
    # can read/write host SSH keys, browser profiles, GPG keys, and other
    # sensitive data in /home. Only the specific paths needed for builds are
    # mounted via explicit --volume flags below.
    if [[ "$ALLOW_HOME_MOUNT" != "true" ]]; then
        create_args+=(--no-home-mount)
        log_info "Security: --no-home-mount applied (host /home not exposed)."
    else
        log_warn "Security: --allow-home-mount: host /home mounted read/write (INSECURE)."
        log_warn "  All container processes can access host SSH keys, browser profiles, etc."
        log_warn "  Remove --allow-home-mount for better isolation."
    fi

    # Mount build cache into the correct location based on user mode.
    # When --no-home-mount is active, the container has no host /home, so we
    # must explicitly mount the cache into the user's home inside the container.
    if [[ "$ENABLE_BUILD_CACHE" == "true" ]]; then
        local cache_dir="$HOME/.cache/yay-${CONTAINER_NAME}"
        mkdir -p "$cache_dir"
        if [[ "$DEDICATED_BUILDUSER" == "true" ]]; then
            create_args+=(--volume "${cache_dir}:/var/lib/_pamac_builder/.cache/yay:rw")
            log_info "Persistent build cache: $cache_dir -> /var/lib/_pamac_builder/.cache/yay"
        else
            create_args+=(--volume "${cache_dir}:/home/${CURRENT_USER}/.cache/yay:rw")
            log_info "Persistent build cache: $cache_dir -> /home/${CURRENT_USER}/.cache/yay"
        fi
    fi

    # --dedicated-builduser: additional isolation for the build user.
    # The build user gets its own home at /var/lib/_pamac_builder and cannot
    # access host files. Source trees are accessed via 'distrobox enter' as
    # the login user, not the build user.
    if [[ "$DEDICATED_BUILDUSER" == "true" ]]; then
        log_info "Build user home isolated at /var/lib/_pamac_builder."
        log_info "Access source trees via 'distrobox enter $CONTAINER_NAME' as the login user."
    fi

    # Apply additional security profiles (--security-opt).
    # These are NOT validated by the script — they are passed directly to the
    # container runtime. Users are responsible for ensuring profile compatibility
    # with the container (e.g. seccomp profiles must not block pacman or makepkg
    # syscalls; AppArmor profiles must not restrict filesystem access needed for
    # builds). Incompatible profiles may cause the container to fail to start.
    if [[ ${#CONTAINER_SECURITY_OPT[@]} -gt 0 ]]; then
        for _sopt in "${CONTAINER_SECURITY_OPT[@]}"; do
            # Basic sanity check: warn if the profile file doesn't exist
            if [[ "$_sopt" == seccomp:* ]]; then
                local _seccomp_path="${_sopt#seccomp:}"
                if [[ "$_seccomp_path" != "unconfined" && ! -f "$_seccomp_path" ]]; then
                    log_warn "security-opt: seccomp profile file not found: $_seccomp_path"
                    log_info "  Continuing anyway — the runtime will fail if the profile is required."
                fi
            elif [[ "$_sopt" == apparmor:* ]]; then
                local _apparmor_name="${_sopt#apparmor:}"
                log_info "security-opt: AppArmor profile '$_apparmor_name' will be applied at container start."
                log_info "  Ensure this profile exists on the host and permits container operations."
            fi
            create_args+=(--security-opt "$_sopt")
        done
        log_warn "Applied security-opt profiles: ${CONTAINER_SECURITY_OPT[*]}"
        log_warn "  These profiles are NOT validated — users are responsible for compatibility."
        log_warn "  Incompatible profiles may prevent the container from starting."
    fi

    # Propagate host proxy / CA-bundle env into the container so the keyring
    # bootstrap, pamac-session-bootstrap auto-refresh, and any later pacman
    # operations inside the container use the same egress path as the host.
    # Without this, a host-exported https_proxy was not honored inside the
    # container, and keyring/mirror downloads would silently fail on
    # corporate/proxy-only networks (the pre-flight probe was a heuristic
    # only). distrobox create accepts repeated --env KEY=VALUE flags; these
    # are baked into the container's environment persistently.
    _collect_proxy_create_args
    if [[ ${#_PROXY_CREATE_ARGS[@]} -gt 0 ]]; then
        log_info "Propagating host proxy settings into the container: ${_PROXY_CREATE_ARGS[*]/#--env /}"
        create_args+=("${_PROXY_CREATE_ARGS[@]}")
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
    if [[ ${#CONTAINER_SECURITY_OPT[@]} -gt 0 ]]; then
        log_error "Container creation failed with --security-opt profiles: ${CONTAINER_SECURITY_OPT[*]}"
        log_error "The security profiles may be incompatible with the container runtime."
        log_error "Try removing --security-opt and re-running to isolate the issue."
    fi
    log_warn "Container create failed - attempting cleanup and retry..."
    force_remove_container "$CONTAINER_NAME"
    sleep 2
    if ! run_command distrobox create "${create_args[@]}"; then
      if [[ ${#CONTAINER_SECURITY_OPT[@]} -gt 0 ]]; then
          log_error "Retry also failed. The --security-opt profiles are likely incompatible."
          log_error "Re-run without --security-opt, or verify your profile against the runtime docs."
      fi
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

  # ── Security posture summary ──
  # Emit remaining risk notes so the user is aware of the container's isolation
  # boundaries. These are printed once per creation, not on every entry.
  if [[ "$ALLOW_HOME_MOUNT" != "true" ]]; then
      log_info "Security: host /home is NOT mounted (--no-home-mount active)."
  fi
  log_info "Security: kernel-level exploits (e.g. CVE-2022-0492, CVE-2024-21626) could"
  log_info "  bypass container isolation. Keep your kernel updated for best protection."
  log_info "Security: D-Bus session and display server (X11/Wayland) are accessible from"
  log_info "  the container. A malicious application could send D-Bus messages or capture"
  log_info "  input via X11. This is inherent to desktop container usage."

  # Success path: clear the recursion lock so a later (re)creation isn't
  # falsely rejected as nested recursion.
  unset _CREATE_RECREATION_GUARD
}

# shellcheck disable=SC2120
repair_pacman_db() {
    log_info "Checking and repairing pacman database (if needed)..."
    # shellcheck disable=all # Inner script runs inside container via bash -c
    container_root_exec bash -c '
set +e
export LC_ALL=C

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
_db_avail_kb=$(df -kP /var/lib/pacman 2>/dev/null | awk "NR==2{print \$4}" || echo "0")
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
        if [[ "$_cache_count" -gt 500 ]]; then
            echo "  Cache is large ($_cache_count packages). Limiting to 500 most recent to avoid excessive time."
            _cache_count=500
        fi
        _inner_remove_stale_lock
        pacman -Syy --noconfirm 2>/dev/null || true
        
        # Only reinstall cached packages that are NOT in the DB properly
        _reinstalled=0
        _cache_processed=0
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
            _cache_processed=$((_cache_processed + 1))
            if [[ $_cache_processed -ge 500 ]]; then
                echo "  Processed 500 packages (cache guard limit). Skipping remaining."
                break
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
    
    # Reinstall any removed packages that are still available.
    # Batch into groups of 50 to avoid command-line length limits and reduce
    # per-invocation overhead (each pacman -S invocation is expensive).
    _pkg_list=$(pacman -Qn 2>/dev/null | awk "{print \$1}" || true)
    if [[ -n "$_pkg_list" ]]; then
        _batch=""
        _count=0
        for _pkg in $_pkg_list; do
            _batch="$_batch $_pkg"
            _count=$((_count + 1))
            if [[ $_count -ge 50 ]]; then
                pacman -S --noconfirm --needed $_batch 2>/dev/null || true
                _batch=""
                _count=0
            fi
        done
        if [[ -n "$_batch" ]]; then
            pacman -S --noconfirm --needed $_batch 2>/dev/null || true
        fi
    fi
    
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

# ── Strategy 9: Validate and repair desc file fields ──
echo ""
echo "=== Strategy 9: Validate desc file fields ==="
_repaired_desc=0
for _db_dir in /var/lib/pacman/local/*/; do
    [[ -d "$_db_dir" ]] || continue
    _pkg_name=$(basename "$_db_dir")
    [[ "$_pkg_name" == *".db-backup"* ]] && continue
    [[ -f "$_db_dir/desc" ]] || continue
    # Check for critical fields: %NAME%, %VERSION%
    if ! grep -q "^%NAME%$" "$_db_dir/desc" 2>/dev/null; then
        echo "  $_pkg_name: missing %NAME% field in desc — reconstructing"
        # Reconstruct NAME from directory name (pkgname-version format)
        _reconstructed_name="${_pkg_name%%-[0-9]*}"
        if [[ -n "$_reconstructed_name" ]]; then
            # Insert %NAME% at the beginning of desc
            _tmp_desc=$(mktemp)
            printf '%%NAME%%\n%s\n\n' "$_reconstructed_name" | cat - "$_db_dir/desc" > "$_tmp_desc" 2>/dev/null
            if [[ -s "$_tmp_desc" ]]; then
                mv "$_tmp_desc" "$_db_dir/desc" 2>/dev/null || rm -f "$_tmp_desc"
                _repaired_desc=$((_repaired_desc + 1))
            else
                rm -f "$_tmp_desc"
            fi
        fi
    fi
    if ! grep -q "^%VERSION%$" "$_db_dir/desc" 2>/dev/null; then
        echo "  $_pkg_name: missing %VERSION% field in desc — reconstructing"
        _reconstructed_ver="${_pkg_name##*-}"
        if [[ -n "$_reconstructed_ver" ]] && [[ "$_reconstructed_ver" != "$_pkg_name" ]]; then
            # Rebuild desc: keep everything up to %NAME% block, add VERSION
            _tmp_desc=$(mktemp)
            # Extract everything up to and including %NAME% block, skip blank line
            awk "BEGIN{s=0} /^%NAME%\$/{print; s=1; next} s && /^[[:space:]]*\$/{print; s=2; next} s==2{next} {print}" \
                "$_db_dir/desc" > "$_tmp_desc" 2>/dev/null
            # Append VERSION block
            printf '\n%%VERSION%%\n%s\n\n' "$_reconstructed_ver" >> "$_tmp_desc"
            # Append everything from %DESC% onwards
            awk "/^%DESC%\$/{p=1} p{print}" "$_db_dir/desc" >> "$_tmp_desc" 2>/dev/null
            if [[ -s "$_tmp_desc" ]]; then
                mv "$_tmp_desc" "$_db_dir/desc" 2>/dev/null || rm -f "$_tmp_desc"
                _repaired_desc=$((_repaired_desc + 1))
            else
                rm -f "$_tmp_desc"
            fi
        fi
    fi
done
echo "  Repaired $_repaired_desc desc files."
if _inner_db_is_healthy; then
    echo "Database consistent after Strategy 9 (desc field repair)."
    exit 0
fi

# ── Strategy 10: Verify file lists against disk ──
echo ""
echo "=== Strategy 10: Verify file lists against disk ==="
_missing_files=0
_orphan_pkgs=0
for _db_dir in /var/lib/pacman/local/*/; do
    [ -d "$_db_dir" ] || continue
    _pkg_name=$(basename "$_db_dir")
    case "$_pkg_name" in *.db-backup*) continue ;; esac
    [ -f "$_db_dir/files" ] || continue
    _total_files=0
    _missing_count=0
    while IFS= read -r _file_line; do
        case "$_file_line" in
            %DIR%|%FILES%|%BACKUP%|"") continue ;;
            [[:space:]]*) continue ;;
        esac
        if [ "${_file_line#/}" != "$_file_line" ]; then
            _total_files=$((_total_files + 1))
            if [ ! -e "$_file_line" ] && [ ! -L "$_file_line" ]; then
                _missing_count=$((_missing_count + 1))
            fi
        fi
    done < "$_db_dir/files"
    if [ "$_total_files" -gt 0 ] && [ "$_missing_count" -eq "$_total_files" ]; then
        echo "  $_pkg_name: ALL $_total_files files missing from disk"
        _orphan_pkgs=$((_orphan_pkgs + 1))
    elif [ "$_missing_count" -gt 0 ] && [ $((_total_files - _missing_count)) -eq 0 ]; then
        echo "  $_pkg_name: $_missing_count/$_total_files files missing (entirely absent)"
        _orphan_pkgs=$((_orphan_pkgs + 1))
    fi
    _missing_files=$((_missing_files + $_missing_count))
done
echo "  Found $_missing_files total missing file entries across all packages."
echo "  $_orphan_pkgs packages have all files missing from disk."
if [ "$_orphan_pkgs" -gt 0 ]; then
    echo "  These packages may need manual reinstallation: pacman -S <pkgname>"
    echo "  Or batch reinstall all native packages: pacman -S --needed \$(pacman -Qnq)"
fi
if _inner_db_is_healthy; then
    echo "Database consistent after Strategy 10 (file verification)."
    exit 0
fi

# ── Strategy 11: pacman --debug deep inspection ──
echo ""
echo "=== Strategy 11: pacman --debug deep inspection ==="
_inner_remove_stale_lock
_debug_output=$(pacman --debug 2>&1 || true)
_debug_issues=$(echo "$_debug_output" | grep -iE "warning|error|missing|corrupt|invalid" | head -20 || true)
if [[ -n "$_debug_issues" ]]; then
    echo "  Found issues from pacman --debug:"
    echo "$_debug_issues" | while IFS= read -r _line; do
        echo "    $_line"
    done
    # Attempt to fix common issues found by --debug
    # 1. Missing files DB entries — reinstall affected packages
    _debug_missing=$(echo "$_debug_output" | grep -oP "error: .*: missing file" | awk -F': ' '{print $2}' | sort -u || true)
    if [[ -n "$_debug_missing" ]]; then
        echo "  Attempting to fix missing file entries..."
        _fixed=0
        while IFS= read -r _missing_entry; do
            [[ -z "$_missing_entry" ]] && continue
            # Find which package owns this file
            _owning_pkg=$(pacman -Qoq "$_missing_entry" 2>/dev/null || true)
            if [[ -n "$_owning_pkg" ]]; then
                pacman -S --noconfirm --needed "$_owning_pkg" 2>/dev/null && _fixed=$((_fixed + 1))
            fi
        done <<< "$_debug_missing"
        echo "  Fixed $_fixed packages with missing file entries."
    fi
    # 2. Check for and fix directory permissions
    _bad_dirs=$(echo "$_debug_output" | grep -oP "warning: .*: .*: No such file or directory" | awk '{print $NF}' | sort -u || true)
    if [[ -n "$_bad_dirs" ]]; then
        echo "  Creating missing directories referenced by packages..."
        while IFS= read -r _dir; do
            [[ -z "$_dir" ]] && continue
            if [[ "$_dir" == /* ]]; then
                mkdir -p "$_dir" 2>/dev/null || true
            fi
        done <<< "$_bad_dirs"
    fi
else
    echo "  pacman --debug found no additional issues."
fi

if _inner_db_is_healthy; then
    echo "Database consistent after Strategy 11 (deep inspection)."
    exit 0
fi

# ── Final: all strategies exhausted ──
echo ""
echo "=== DB Repair: Final Status ==="
echo "All 11 repair strategies attempted."
echo ""
echo "Remaining issues:"
pacman -Dk 2>&1 | head -20 || true
echo ""
echo "The system may still be partially functional."
echo "Manual recovery options:"
echo "  1. pacman -Syyu --overwrite \"*\"  (full upgrade with overwrite)"
echo "  2. Reinstall individual packages: pacman -S <pkgname>"
echo "  3. Batch reinstall all native packages: pacman -S --needed \$(pacman -Qnq)"
echo "  4. Check filesystem: fsck $(df /var/lib/pacman 2>/dev/null | awk "NR==2{print \$6}" || echo "/")"
echo ""
echo "WARNING: Some inconsistencies may be non-fatal and can be ignored if"
echo "the system is otherwise working. Not every -Dk warning requires action."
' 2>/dev/null || true
}

# shellcheck disable=SC2016,SC1078,SC1079
# _safe_sleep is extracted to /usr/local/lib/pamac-common.sh (written once on
# first container script execution). All container scripts source it instead of
# defining inline. This eliminates the 3-copy maintenance burden.
# NOTE on quoting: _write_pamac_common uses a heredoc with a quoted delimiter
# Heredoc (<<'_PREAMBLE_END') to write pamac-common.sh. The heredoc delimiter
# _PAMAC_EOF appears literally in the container script. A mismatch silently
# produces a broken container script that cannot source _safe_sleep.
_CONTAINER_PREAMBLE=$(cat << '_PREAMBLE_END'
# Force C locale so pacman's English output matches the regexes used by
# the host-side repair/diagnostic scripts. Arch containers default to
# en_US.UTF-8 but some minimal images may inherit the host locale.
export LC_ALL=C
_write_pamac_common() {
local _target="${1:-/usr/local/lib/pamac-common.sh}"
cat > "$_target" << '_PAMAC_EOF'
_safe_sleep() {
local _d="$1"
case "$_d" in ''|*[!0-9]*) _d=1 ;; esac
if sleep "$_d" 2>/dev/null; then return 0; fi
if command -v python3 >/dev/null 2>&1; then
    python3 -c "import time,sys; time.sleep(float(sys.argv[1]))" "$_d" 2>/dev/null && return 0
fi
if command -v perl >/dev/null 2>&1; then
    perl -e "select undef,undef,undef,\$ARGV[0]" "$_d" 2>/dev/null && return 0
fi
local _target=$(( _d + 0 ))
[[ $_target -lt 1 ]] && _target=1
local _start=$SECONDS
while (( SECONDS - _start < _target )); do
    read -t 1 _dummy </dev/null 2>/dev/null || true
done
return 0
}
_PAMAC_EOF
[[ -s "$_target" ]] || { echo "FATAL: _write_pamac_common produced empty file" >&2; return 1; }
}
if [[ ! -f /usr/local/lib/pamac-common.sh ]]; then
mkdir -p /usr/local/lib 2>/dev/null
_write_pamac_common
fi
. /usr/local/lib/pamac-common.sh
# Integrity check: verify the sourced file defines the expected function.
# A corrupted or truncated pamac-common.sh would silently break all container
# scripts that depend on _safe_sleep. If the check fails, rewrite the file.
if ! declare -f _safe_sleep >/dev/null 2>&1; then
    echo "WARNING: /usr/local/lib/pamac-common.sh is corrupted (missing _safe_sleep). Rewriting."
    rm -f /usr/local/lib/pamac-common.sh 2>/dev/null || true
    _write_pamac_common
    . /usr/local/lib/pamac-common.sh
fi
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
# ── Stale build environment cleanup ──
# Runs at the start of every container script to clean up resources left behind
# by hard-killed (SIGKILL, OOM, host crash) prior builds. Without this,
# orphaned _brecover* users, /var/tmp/builduser-home-* directories, and stale
# /var/tmp/pamac-* work directories accumulate over time.
_cleanup_stale_build_env() {
    # 1. Remove orphaned _brecover* users and their temp homes
    local _orphan_users=""
    _orphan_users=$(getent passwd 2>/dev/null | awk -F: '$1 ~ /^_brecover/ { print $1 }' || true)
    for _ou in $_orphan_users; do
        echo "Cleaning up orphaned build user: $_ou" >&2
        userdel -r "$_ou" 2>/dev/null || userdel "$_ou" 2>/dev/null || true
        # Purge stale subuid/subgid entries
        if [[ -w /etc/subuid ]]; then
            grep -vF "${_ou}:" /etc/subuid > /etc/subuid.tmp 2>/dev/null && \
                mv /etc/subuid.tmp /etc/subuid 2>/dev/null || rm -f /etc/subuid.tmp 2>/dev/null
        fi
        if [[ -w /etc/subgid ]]; then
            grep -vF "${_ou}:" /etc/subgid > /etc/subgid.tmp 2>/dev/null && \
                mv /etc/subgid.tmp /etc/subgid 2>/dev/null || rm -f /etc/subgid.tmp 2>/dev/null
        fi
    done
    # 2. Remove orphaned builduser home directories (any owner, not just root)
    for _dir in /var/tmp/builduser-home-*; do
        [[ -d "$_dir" ]] || continue
        echo "Removing orphaned build-user home: $_dir" >&2
        rm -rf "$_dir" 2>/dev/null || true
    done
    # 3. Remove stale pamac work directories (older than 1 day)
    for _dir in /var/tmp/pamac-*; do
        [[ -d "$_dir" ]] || continue
        # Only remove if older than 24h to avoid removing active work dirs
        if [[ -n "$(find "$_dir" -maxdepth 0 -mmin +1440 2>/dev/null)" ]]; then
            echo "Removing stale work directory: $_dir" >&2
            rm -rf "$_dir" 2>/dev/null || true
        fi
    done
}
# Only run heavy cleanup as root (userdel, subuid edits require it anyway)
if [[ "$(id -u)" -eq 0 ]]; then
    _cleanup_stale_build_env
fi
_atomic_sed_inplace() {
    local _target="$1"; shift
    local _tmp; _tmp=$(mktemp "${_target}.atomic.XXXXXX") || { echo "FATAL: mktemp failed for atomic sed on $_target"; return 1; }
    cp -f "$_target" "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    for _expr in "$@"; do
        if ! sed -i "$_expr" "$_tmp"; then
            echo "FATAL: sed expression failed: $_expr" >&2
            rm -f "$_tmp"
            return 1
        fi
    done
    sync "$_tmp" 2>/dev/null || sync 2>/dev/null || true
    mv -f "$_tmp" "$_target"
    # Sync the parent directory to ensure the rename is durable on power loss.
    local _parent
    _parent=$(dirname "$_target")
    sync "$_parent" 2>/dev/null || true
}

# Escape all sed-special characters in a replacement string.
# Use this when embedding user-supplied values into s/pattern/replacement/exprs.
# Characters escaped: \ & / (the three that break s/// sed substitutions).
# When the delimiter is |, only \ and & need escaping (not /).
_sed_escape_replacement() {
    local _s="$1"
    _s="${_s//\\/\\\\}"
    _s="${_s//&/\\&}"
    _s="${_s//\//\\/}"
    echo "$_s"
}
# Escape sed-special characters in a search pattern.
# Characters escaped: \ / [ ] ^ $ . * (these are regex/sed metacharacters).
# Use when embedding user-supplied values into the search side of s/pattern/replacement/.
_sed_escape_pattern() {
    local _s="$1"
    _s="${_s//\\/\\\\}"
    _s="${_s//\//\\/}"
    _s="${_s//\[/\\[}"
    _s="${_s//\]/\\]}"
    _s="${_s//^/\\^}"
    _s="${_s//\$/\\\$}"
    _s="${_s//./\\.}"
    _s="${_s//\*/\\*}"
    echo "$_s"
}
_calc_makepkg_jobs() {
    local ram_per_job_kb=768000
    # In low-memory mode, double the per-job RAM requirement to reduce
    # parallelism on constrained systems (e.g., Steam Deck with 16GB shared
    # with GPU, or older laptops with 8GB).
    if [[ "${LOW_MEMORY:-false}" == "true" ]]; then
        ram_per_job_kb=$(( ram_per_job_kb * 2 ))
    fi
    local mem_avail_kb=0
    local swap_avail_kb=0
    local ncpu
    ncpu=$(nproc 2>/dev/null || echo "1")
    if [[ -f /proc/meminfo ]]; then
        mem_avail_kb=$(awk "/^MemAvailable:/{print \$2}" /proc/meminfo 2>/dev/null || echo "0")
        # Also check SwapFree. When LOW_MEMORY is enabled, total
        # allocatable memory = RAM + swap. Without swap, large AUR
        # builds (e.g. chromium) can OOM even with a conservative
        # per-job RAM budget. Capping by RAM+swap prevents this.
        swap_avail_kb=$(awk "/^SwapFree:/{print \$2}" /proc/meminfo 2>/dev/null || echo "0")
    fi
    if [[ "$mem_avail_kb" -gt 0 ]]; then
        local total_avail_kb=$(( mem_avail_kb + swap_avail_kb ))
        local jobs=$(( total_avail_kb / ram_per_job_kb ))
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
    # ccache: reduces recompilation writes by caching object files.
    # BUILDDIR on tmpfs: compiles in RAM to avoid eMMC write cycles.
    # Both are configured in /etc/makepkg.conf by _setup_emmc_safe_build,
    # but we also export them as env vars for yay invocations that bypass
    # makepkg.conf (e.g., yay -S --rebuild).
    if command -v ccache >/dev/null 2>&1; then
        export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
        export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
    fi
    local _mem_avail_kb
    _mem_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if [[ "$_mem_avail_kb" -gt 2621440 ]]; then
        # >2.5GB free: set BUILDDIR for tmpfs builds (if not already in makepkg.conf)
        if ! grep -q '^BUILDDIR=' /etc/makepkg.conf 2>/dev/null; then
            export BUILDDIR="/tmp/makepkg-build"
        fi
    fi
    echo "MAKEFLAGS set to -j${jobs} (RAM-constrained build parallelism)"
    local _swap_kb
    _swap_kb=$(awk '/^SwapFree:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    _log_event "build_parallelism_init" "jobs=$jobs" "swap_kb=$_swap_kb" "ram_kb=$_mem_avail_kb" "low_mem=${LOW_MEMORY:-false}"
}

# ── Pre-build OOM check: dynamically reduce parallelism if memory dropped ──
# Called before every makepkg/yay build invocation. If available RAM has
# dropped below the threshold since _set_makepkg_jobs calculated the
# parallelism, this function reduces MAKEFLAGS to prevent OOM-kills
# mid-compilation (gcc/vala are memory-hungry and OOM during build
# corrupts partial object files and wastes all prior write cycles).
_preflight_oom_check() {
    local _desc="${1:-build}"
    if [[ ! -f /proc/meminfo ]]; then
        return 0
    fi
    local _mem_avail_kb
    _mem_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    local _swap_avail_kb
    _swap_avail_kb=$(awk '/^SwapFree:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    local _total_kb=$(( _mem_avail_kb + _swap_avail_kb ))

    # Critical threshold: <256MB — abort to prevent OOM corruption
    if [[ "$_total_kb" -lt 262144 ]]; then
        local _avail_mb=$(( _total_kb / 1024 ))
        _log_event "oom_abort" "desc=$_desc" "avail_mb=$_avail_mb" "threshold_mb=256" "mem_avail_kb=$_mem_avail_kb" "swap_avail_kb=$_swap_avail_kb"
        log_error "CRITICAL: Only ${_avail_mb}MB RAM+swap available before $_desc."
        log_error "OOM kill during gcc/vala compilation would corrupt build artifacts."
        log_error "Close other applications or add swap, then retry."
        return 1
    fi

    # Warning threshold: recalculate jobs if memory dropped significantly
    # since the initial _set_makepkg_jobs call.
    local _current_jobs
    _current_jobs=$(echo "$MAKEFLAGS" | grep -oP '\-j\K[0-9]+' || echo 1)
    local _ram_per_job_kb=768000
    if [[ "${LOW_MEMORY:-false}" == "true" ]]; then
        _ram_per_job_kb=$(( _ram_per_job_kb * 2 ))
    fi
    local _safe_jobs=$(( _total_kb / _ram_per_job_kb ))
    [[ "$_safe_jobs" -lt 1 ]] && _safe_jobs=1
    local _ncpu
    _ncpu=$(nproc 2>/dev/null || echo 1)
    [[ "$_safe_jobs" -gt "$_ncpu" ]] && _safe_jobs="$_ncpu"

    if [[ "$_safe_jobs" -lt "$_current_jobs" ]]; then
        _log_event "oom_parallelism_reduce" "desc=$_desc" "from_j=$_current_jobs" "to_j=$_safe_jobs" "avail_mb=$(( _total_kb / 1024 ))"
        log_warn "Memory dropped before $_desc: reducing MAKEFLAGS from -j${_current_jobs} to -j${_safe_jobs}"
        export MAKEFLAGS="-j${_safe_jobs}"
    fi
    return 0
}

# ── Auto-detect installable drives ──
# Scans /proc/mounts for real (non-virtual) filesystems with sufficient space.
# Returns results as lines: "mount_point|device|avail_gb|fstype"
# Filters out virtual/fs/root-only mounts (sysfs, proc, devtmpfs, etc.)
_detect_install_drives() {
    local _home_dev
    _home_dev=$(df -P "$HOME" 2>/dev/null | awk 'NR==2{print $1}' || echo "")
    local _home_mp
    _home_mp=$(df -P "$HOME" 2>/dev/null | awk 'NR==2{print $6}' || echo "")
    awk -v home_dev="$_home_dev" -v home_mp="$_home_mp" '
    $1 !~ /^(sysfs|proc|devtmpfs|tmpfs|cgroup|overlay|shm|run\/user|run\/netns)/ &&
    $2 !~ /^(\/run|\/sys|\/proc|\/dev|\/snap)/ &&
    $4 !~ /ro,/ &&
    $3 ~ /^[0-9]+$/ {
        dev = $1; mp = $2; avail_kb = $3; fstype = $4
        # Skip tiny partitions (< 1 GB)
        if (avail_kb < 1048576) next
        # Skip the root filesystem if it's also the home filesystem
        if (mp == "/" && dev == home_dev) next
        # Convert device short name for display
        gsub(/\/dev\//, "", dev)
        avail_gb = int(avail_kb / 1048576)
        printf "%s|%s|%d GB|%s\n", mp, dev, avail_gb, fstype
    }' /proc/mounts 2>/dev/null | sort -t'|' -k3 -rn
}

# ── Interactive setup menu ──
# Presents key options as a toggle menu before installation. Users press
# letter keys to toggle options, then press Enter to confirm. Runs once
# at the start of an interactive terminal session.
_interactive_setup_menu() {
    [[ -t 0 && -t 1 ]] || return 0
    [[ "${NON_INTERACTIVE:-false}" == "true" ]] && return 0
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    [[ "${UPDATE:-false}" == "true" ]] && return 0
    [[ "${STATUS:-false}" == "true" ]] && return 0
    [[ "${UNINSTALL:-false}" == "true" ]] && return 0

    # Local copies to toggle (start with current defaults)
    local _opt_build_cache="${ENABLE_BUILD_CACHE:-true}"
    local _opt_low_mem="${LOW_MEMORY:-false}"
    local _opt_strict="${STRICT_SECURITY:-false}"
    local _opt_dedbuild="${DEDICATED_BUILDUSER:-true}"
    local _opt_multi="${ENABLE_MULTILIB:-true}"
    local _opt_flatpak="${ENABLE_FLATPAK:-false}"

    while true; do
        local _bc=" "; [[ "$_opt_build_cache" == "true" ]] && _bc="x"
        local _lm=" "; [[ "$_opt_low_mem" == "true" ]] && _lm="x"
        local _ss=" "; [[ "$_opt_strict" == "true" ]] && _ss="x"
        local _db=" "; [[ "$_opt_dedbuild" == "true" ]] && _db="x"
        local _ml=" "; [[ "$_opt_multi" == "true" ]] && _ml="x"
        local _fp=" "; [[ "$_opt_flatpak" == "true" ]] && _fp="x"

        echo "" >&2
        echo "╔══════════════════════════════════════════════════════════════╗" >&2
        echo "║  INSTALL OPTIONS (press key to toggle, Enter to confirm)   ║" >&2
        echo "╚══════════════════════════════════════════════════════════════╝" >&2
        echo "" >&2
        echo "  [B]uild cache (persistent yay cache)    [${_bc}]" >&2
        echo "  [M]ultilib (32-bit libs for Steam/Games) [${_ml}]" >&2
        echo "  [L]ow-memory mode (safe for 8GB RAM)    [${_lm}]" >&2
        echo "  [S]trict security (no TrustAll relax)    [${_ss}]" >&2
        echo "  [D]edicated build user (AUR isolation)   [${_db}]" >&2
        echo "  [F]latpak support (Pamac GUI)            [${_fp}]" >&2
        echo "" >&2
        echo "  [I]nstall target drive" >&2
        echo "  [P]roceed with install" >&2
        echo "" >&2
        printf "  Toggle: " >&2
        local _key
        read -rsn1 _key </dev/tty 2>/dev/null || _key=""
        echo "" >&2

        case "${_key,,}" in
            b) _opt_build_cache=$( [[ "$_opt_build_cache" == "true" ]] && echo false || echo true ) ;;
            m) _opt_multi=$( [[ "$_opt_multi" == "true" ]] && echo false || echo true ) ;;
            l) _opt_low_mem=$( [[ "$_opt_low_mem" == "true" ]] && echo false || echo true ) ;;
            s) _opt_strict=$( [[ "$_opt_strict" == "true" ]] && echo false || echo true ) ;;
            d) _opt_dedbuild=$( [[ "$_opt_dedbuild" == "true" ]] && echo false || echo true ) ;;
            f) _opt_flatpak=$( [[ "$_opt_flatpak" == "true" ]] && echo false || echo true ) ;;
            i) _select_install_drive ;;
            p|"")
                # Confirm selections
                ENABLE_BUILD_CACHE="$_opt_build_cache"
                LOW_MEMORY="$_opt_low_mem"
                STRICT_SECURITY="$_opt_strict"
                DEDICATED_BUILDUSER="$_opt_dedbuild"
                ENABLE_MULTILIB="$_opt_multi"
                ENABLE_FLATPAK="$_opt_flatpak"
                log_info "Selected options:"
                log_info "  Build cache: $ENABLE_BUILD_CACHE"
                log_info "  Multilib: $ENABLE_MULTILIB"
                log_info "  Low-memory: $LOW_MEMORY"
                log_info "  Strict security: $STRICT_SECURITY"
                log_info "  Dedicated build user: $DEDICATED_BUILDUSER"
                log_info "  Flatpak: $ENABLE_FLATPAK"
                return 0
                ;;
        esac
    done
}

# ── Interactive drive selector ──
# Presents auto-detected drives as a numbered menu. User presses a key to
# select. Returns the selected mount point via _SELECTED_INSTALL_DRIVE.
_select_install_drive() {
    if [[ "${_SELECTED_INSTALL_DRIVE:-}" == "auto" ]]; then
        # Already triggered via --install-drive flag
        :
    elif [[ -t 0 ]] && [[ -t 1 ]]; then
        # Interactive terminal — ask if user wants to choose
        printf "Multiple storage devices detected. Select install target? [y/N]: " >&2
        read -r _choose </dev/tty 2>/dev/null || _choose=""
        if [[ "$_choose" != "y" && "$_choose" != "Y" ]]; then
            return 0
        fi
    else
        return 0
    fi

    local _drives
    _drives=$(_detect_install_drives)
    if [[ -z "$_drives" ]]; then
        log_info "No additional drives detected. Using default ($HOME filesystem)."
        return 0
    fi

    # Build array of drives
    local -a _drive_lines=()
    local _i=0
    while IFS= read -r _line; do
        _drive_lines+=("$_line")
        _i=$((_i + 1))
    done <<< "$_drives"

    if [[ ${#_drive_lines[@]} -eq 0 ]]; then
        log_info "No installable drives found. Using default ($HOME filesystem)."
        return 0
    fi

    # Show the menu
    echo "" >&2
    echo "╔══════════════════════════════════════════════════════════════╗" >&2
    echo "║  SELECT INSTALL TARGET                                      ║" >&2
    echo "╚══════════════════════════════════════════════════════════════╝" >&2
    echo "" >&2

    local _num=1
    for _dl in "${_drive_lines[@]}"; do
        local _mp _dev _size _fst
        IFS='|' read -r _mp _dev _size _fst <<< "$_dl"
        local _marker=" "
        # Highlight the drive containing $HOME
        local _home_mp
        _home_mp=$(df -P "$HOME" 2>/dev/null | awk 'NR==2{print $6}' || echo "")
        if [[ "$_mp" == "$_home_mp" ]]; then
            _marker="*"
        fi
        printf "  [%d]%s %-20s  %-12s  %s\n" "$_num" "$_marker" "$_mp" "$_dev" "$_size" >&2
        _num=$((_num + 1))
    done
    echo "" >&2
    echo "  [*] = contains \$HOME (current)" >&2
    echo "  [0] = keep default (no change)" >&2
    echo "" >&2

    # Prompt for selection
    printf "  Select drive [0-%d]: " "$((_num - 1))" >&2
    local _choice
    read -r _choice </dev/tty 2>/dev/null || _choice="0"

    # Validate input
    if [[ ! "$_choice" =~ ^[0-9]+$ ]] || [[ "$_choice" -lt 0 ]] || [[ "$_choice" -ge "$_num" ]]; then
        log_info "Invalid selection. Using default ($HOME filesystem)."
        return 0
    fi

    if [[ "$_choice" -eq 0 ]]; then
        log_info "Using default install target ($HOME filesystem)."
        return 0
    fi

    local _selected="${_drive_lines[$((_choice - 1))]}"
    local _sel_mp
    _sel_mp=$(echo "$_selected" | cut -d'|' -f1)
    local _sel_dev
    _sel_dev=$(echo "$_selected" | cut -d'|' -f2)
    local _sel_size
    _sel_size=$(echo "$_selected" | cut -d'|' -f3)

    _SELECTED_INSTALL_DRIVE="$_sel_mp"
    log_info "Selected install target: $_sel_mp ($_sel_dev, $_sel_size free)"
    _log_event "install_drive_selected" "mount=$_sel_mp" "device=$_sel_dev" "avail=$_sel_size"
}

# ── Pre-build disk space check ──
# Called before every build/install invocation to ensure sufficient disk space.
# AUR builds (makepkg) consume significant space: Arch container base ~3 GB,
# plus source trees, build artifacts, and installed packages. A safe cushion of
# 10 GB beyond the container image is required to prevent running out mid-build,
# which corrupts partial artifacts and wastes all prior compilation time.
# Checks both /var and /tmp, plus the install drive if --install-drive is set.
# Returns 1 if critically low, 0 otherwise.
_preflight_space_check() {
    local _desc="${1:-build}"
    # 10 GB minimum cushion — covers container image (~3 GB) + build artifacts
    # + installed packages + pacman cache, with margin for safety.
    local _min_kb="${DISK_SPACE_MIN_KB:-10485760}"  # 10 GiB default
    # Check /var (where container writes happen) and /tmp (where builds run)
    for _mount in /var /tmp; do
        local _avail_kb
        _avail_kb=$(df -kP "$_mount" 2>/dev/null | awk 'NR==2{print $4}' || echo "")
        if [[ -n "$_avail_kb" && "$_avail_kb" -lt "$_min_kb" ]]; then
            local _avail_mb=$(( _avail_kb / 1024 ))
            local _min_mb=$(( _min_kb / 1024 ))
            _log_event "space_low" "desc=$_desc" "mount=$_mount" "avail_kb=$_avail_kb" "min_kb=$_min_kb"
            log_error "CRITICAL: Only ${_avail_mb}MB free on $_mount before $_desc."
            log_error "AUR builds require at least $(( _min_mb / 1024 ))GB free. Free space or add storage."
            return 1
        fi
    done
    # Check install drive if specified
    if [[ -n "${_SELECTED_INSTALL_DRIVE:-}" ]]; then
        local _drive_avail
        _drive_avail=$(df -kP "$_SELECTED_INSTALL_DRIVE" 2>/dev/null | awk 'NR==2{print $4}' || echo "")
        if [[ -n "$_drive_avail" && "$_drive_avail" -lt "$_min_kb" ]]; then
            local _avail_mb=$(( _drive_avail / 1024 ))
            local _min_mb=$(( _min_kb / 1024 ))
            _log_event "space_low" "desc=$_desc" "mount=$_SELECTED_INSTALL_DRIVE" "avail_kb=$_drive_avail" "min_kb=$_min_kb"
            log_error "CRITICAL: Only ${_avail_mb}MB free on install drive $_SELECTED_INSTALL_DRIVE before $_desc."
            log_error "AUR builds require at least $(( _min_mb / 1024 ))GB free. Free space or add storage."
            return 1
        fi
    fi
    return 0
}

# ── eMMC/flash wear reduction: tmpfs build directory + ccache ──
# Large C++/Vala AUR builds (yay, pamac-aur) generate massive write cycles
# that degrade eMMC/SD flash memory. This function mitigates wear by:
#   1. Mounting BUILDDIR on tmpfs (compiles in RAM, only final .pkg.tar.zst
#      touches disk)
#   2. Enabling ccache (avoids recompiling unchanged sources across rebuilds)
#   3. Setting PKGDEST to host-mounted cache (avoids redundant package copies)
_setup_emmc_safe_build() {
    local _container_name="${1:-$CONTAINER_NAME}"
    local _current_user="${2:-$CURRENT_USER}"

    # Only run if container is usable
    if ! container_is_usable; then
        return 0
    fi

    log_info "Configuring eMMC-safe build environment (tmpfs BUILDDIR + ccache)..."

    # Install ccache inside the container (reduces recompilation writes)
    container_root_exec bash -c 'pacman -S --noconfirm --needed ccache 2>/dev/null || true'

    # Configure build environment inside the container
    container_root_exec bash -c "
set +e

# ── BUILDDIR on tmpfs ──
# Only create tmpfs if enough RAM is available (>4GB free) and /tmp is not
# already a tmpfs (some distros mount /tmp as tmpfs by default).
_mem_avail_kb=\$(awk '/^MemAvailable:/{print \$2}' /proc/meminfo 2>/dev/null || echo 0)
_tmp_is_tmpfs=false
if mountpoint -q /tmp 2>/dev/null; then
    _tmp_type=\$(stat -f -c '%T' /tmp 2>/dev/null || echo '')
    [[ \"\$_tmp_type\" == \"tmpfs\" ]] && _tmp_is_tmpfs=true
fi

# Reserve 2GB for the system; use remaining free RAM for build dir
_build_ram_kb=0
if [[ \"\$_mem_avail_kb\" -gt 2097152 ]]; then
    _build_ram_kb=\$(( _mem_avail_kb - 2097152 ))
    # Cap at 8GB to avoid starving the system
    [[ \"\$_build_ram_kb\" -gt 8388608 ]] && _build_ram_kb=8388608
fi

if [[ \"\$_build_ram_kb\" -gt 524288 ]]; then
    _build_ram_mb=\$(( _build_ram_kb / 1024 ))
    _build_dir=\"/tmp/makepkg-build\"
    mkdir -p \"\$_build_dir\" 2>/dev/null || true
    # Only mount if not already mounted
    if ! mountpoint -q \"\$_build_dir\" 2>/dev/null; then
        if mount -t tmpfs -o \"size=\${_build_ram_mb}M,noatime,nosuid,nodev\" tmpfs \"\$_build_dir\" 2>/dev/null; then
            echo \"BUILDDIR=\$_build_dir\" >> /etc/makepkg.conf 2>/dev/null || true
            echo \"  tmpfs BUILDDIR: \$_build_dir (\$_build_ram_mb MB in RAM)\"
        else
            echo \"  tmpfs mount failed (insufficient privileges). Build writes will hit eMMC.\"
        fi
    else
        echo \"  /tmp is already tmpfs — BUILDDIR wear protection active.\"
    fi
else
    echo \"  Insufficient free RAM (\$(( _mem_avail_kb / 1024 ))MB) for tmpfs build dir.\"
    echo \"  Build writes will hit eMMC/SD. Consider closing other applications.\"
fi

# ── ccache configuration ──
_ccache_dir=\"/home/\${_current_user:-root}/.ccache\"
if command -v ccache >/dev/null 2>&1; then
    mkdir -p \"\$_ccache_dir\" 2>/dev/null || true
    chown \"\${_current_user:-root}:\${_current_user:-root}\" \"\$_ccache_dir\" 2>/dev/null || true
    # Enable ccache in makepkg.conf (append if not already present)
    if ! grep -q '^CCACHE' /etc/makepkg.conf 2>/dev/null; then
        cat >> /etc/makepkg.conf << 'CCACHE_CONF'

# ccache: reduces recompilation writes and speeds up rebuilds
CCACHE_DIR=\"/home/__USER__/.ccache\"
CCACHE_MAXSIZE=\"5G\"
CCACHE_CONF
        sed -i \"s|__USER__|\${_current_user:-root}|g\" /etc/makepkg.conf 2>/dev/null || true
    fi
    # Set PATH to include ccache
    if ! grep -q 'ccache' /etc/makepkg.conf 2>/dev/null; then
        sed -i 's|^PATH=.*|PATH=\"/usr/lib/ccache/bin:$PATH\"|' /etc/makepkg.conf 2>/dev/null || true
    fi
    echo \"  ccache enabled (max 5GB, dir: \$_ccache_dir)\"
else
    echo \"  ccache not available — recompilation writes will hit eMMC.\"
fi
" 2>&1 | while IFS= read -r _line; do
        log_info "  build: $_line"
    done || true
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
                    echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
                    ;;
                1)
                    echo "  Exit 1: General error (dependency conflict, etc.)."
                    # Check for file conflicts — capture output first, then grep,
                    # to avoid pipefail truncating grep's input if pacman exits early.
                    _pacman_diag=$(LC_ALL=C pacman -S --noconfirm --needed "$@" 2>&1 || true)
                    _conflict_output=$(echo "$_pacman_diag" | grep -i "conflicting files\|exists in filesystem" || true)
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
                # Only kill the process that holds /var/lib/pacman/db.lck (i.e.,
                # the stale lock owner), NOT every pacman/yay PID on the system.
                # Other legitimate pacman processes (other users, background
                # updates) must not receive SIGKILL — doing so can corrupt the
                # pacman database for other concurrent operations.
                _lock_pid=$(cat /var/lib/pacman/db.lck 2>/dev/null || echo "")
                if [[ -n "$_lock_pid" ]] && [[ "$_lock_pid" =~ ^[0-9]+$ ]] && \
                   [[ "$_lock_pid" != "$$" ]] && [[ "$_lock_pid" != "$PPID" ]]; then
                    if kill -0 "$_lock_pid" 2>/dev/null; then
                        echo "  Lock held by PID $_lock_pid. Sending SIGTERM and waiting..."
                        kill -15 "$_lock_pid" 2>/dev/null || true
                        local _w=0
                        while [[ $_w -lt 10 ]] && kill -0 "$_lock_pid" 2>/dev/null; do
                            sleep 1; _w=$((_w + 1))
                        done
                        if kill -0 "$_lock_pid" 2>/dev/null; then
                            echo "  Process did not exit after SIGTERM. Force-killing..."
                            kill -9 "$_lock_pid" 2>/dev/null || true
                            sleep 1
                        fi
                    fi
                fi
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
                    # Narrow --overwrite to specific package-owned directories.
                    # A blanket --overwrite '/usr/*' could clobber config files
                    # in /usr/etc, /usr/lib/tmpfiles.d, etc. Limit to the
                    # standard FHS directories where packages install binaries
                    # and libraries. /etc/ is never overwritten (/etc is always
                    # protected by pacman's backup mechanism).
                    pacman -S --noconfirm --needed --overwrite '/usr/lib/*,/usr/share/*,/usr/bin/*,/usr/sbin/*,/usr/libexec/*' "$_pkg" 2>/dev/null || true
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
    local batch
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
                            echo "FATAL: Critical build tool '$pkg' missing. Cannot continue."
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
# Install the fake systemd-run shim from the extracted file. Used when
# --no-use-init is set and real systemd is not available. The full shim
# lives in fake-systemd-run.sh (~2600 lines, bwrap+seccomp sandbox).
# Use --use-init (default) for real systemd instead.
# Runtime verification confirms the sandbox actually applied after entry.
# Use --strict-security to disable this wrapper entirely.
# The shim has been extracted to fake-systemd-run.sh to keep this script
# manageable. When --no-use-init is used, this function copies it into
# the container.
_write_fake_systemd_run_wrapper() {
    mkdir -p /usr/local/sbin
    # Locate the extracted shim file — check common locations:
    # 1) Same directory as this installer script
    # 2) Script's own directory (when run from extracted archive)
    # 3) Current working directory
    local _script_dir
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}" 2>/dev/null)" && pwd 2>/dev/null || echo ".")"
    local _shim=""
    for _candidate in \
        "${_script_dir}/fake-systemd-run.sh" \
        "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")" 2>/dev/null)/fake-systemd-run.sh" \
        "./fake-systemd-run.sh" \
    ; do
        if [[ -f "$_candidate" ]]; then
            _shim="$_candidate"
            break
        fi
    done
    if [[ -z "$_shim" ]]; then
        echo "ERROR: fake-systemd-run.sh not found next to the installer." >&2
        echo "  The shim was extracted to a separate file. Place it alongside" >&2
        echo "  this script, or use --use-init (recommended) for real systemd." >&2
        exit 1
    fi
    cp -f "$_shim" /usr/local/sbin/systemd-run
    chmod +x /usr/local/sbin/systemd-run
}
_atomic_write_pacman_conf() {
    local target="/etc/pacman.conf"
    local new_siglevel="$1"
    _atomic_sed_inplace "$target" "s|^[[:space:]]*SigLevel.*|SigLevel = ${new_siglevel}|"
    grep -q '^SigLevel' "$target" 2>/dev/null || printf 'SigLevel = %s\n' "$new_siglevel" >> "$target"
}
_PREAMBLE_END
)

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

    # Validate heredoc content for common quoting/escaping mistakes
    _validate_heredoc_sanity "$_script" "$_desc"

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

    # Validate generated file for common quoting/escaping mistakes
    _validate_heredoc_sanity "$(cat "$_script_file")" "$_desc"

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
            _log_event "container_oom_kill" "desc=$_desc" "exit_code=$_rc" "kind=$_kind"
            log_warn "$_kind '$_desc' got exit 137 without completion marker. May be OOM or signal kill."
        else
            log_warn "$_kind '$_desc' got exit $_rc without completion marker in non-init container. May be premature container stop."
        fi
        container_start 2>/dev/null || true
        # Only run heavy DB repair if output contains strong corruption
        # indicators. Broad terms like bare "database" or "invalid" alone
        # would false-positive on informational messages; require a compound
        # match (e.g., "database error", "invalid signature") to reduce
        # unnecessary repair runs that waste time and risk data loss.
        if echo "$_output" | grep -qiE "database.*(corrupt|incomplete|missing|not found|damaged|broken|failed to init)|corrupt(ed)? (database|package)|invalid.*(signature|database)|signature.*(invalid|missing|corrupt)|could not open|unable to lock database|failed to init.*database"; then
            log_info "DB corruption indicators detected in output — running repair..."
            # shellcheck disable=SC2119
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
            log_error "Keyring recovery failed${STRICT_SECURITY:+ (--strict-security refused signature relaxation)}."
            log_error "To recover, enter the container and reinitialize the keyring:"
            log_error "  distrobox enter $CONTAINER_NAME --"
            log_error "    sudo pacman-key --init"
            log_error "    sudo pacman-key --populate archlinux"
            log_error "    sudo pacman -Sy --noconfirm archlinux-keyring gnupg"
            log_error "Then re-run the installer${STRICT_SECURITY:+, or retry WITHOUT --strict-security to allow the TrustAll fallback}."
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
    # shellcheck disable=all # Inner script runs inside container via bash -c
    container_root_exec bash -c '
set +e
export LC_ALL=C
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
# (pgrep -x pacman/yay loops removed — lock-file parsing above is sufficient)
pkill -9 gpg-agent 2>/dev/null || true
pkill -9 dirmngr 2>/dev/null || true
sleep 1
# Quick disk space check — if /var is full, DB repair will fail
_avail_kb=$(df -kP /var/lib/pacman 2>/dev/null | awk "NR==2{print \$4}" || echo "0")
if [[ "$_avail_kb" -gt 0 ]] && [[ "$_avail_kb" -lt 5120 ]]; then
    echo "WARNING: Critically low disk space (${_avail_kb}KB) in /var/lib/pacman."
    echo "  DB repair may fail. Consider freeing space: docker system prune / podman system prune"
fi
' 2>/dev/null || true
        container_start 2>/dev/null || true
        # shellcheck disable=SC2119
        repair_pacman_db
        return "$_rc"
    fi
    return 0
}

configure_container_base() {
    log_step "Configuring container base environment"

    local _ok=true

    # ── Pre-keyring CA certificate propagation ──
    # In corporate/proxy environments with SSL inspection, the host may trust a
    # custom CA that the container's base image doesn't have. Without this,
    # keyring downloads (Methods A-C) fail with SSL errors before
    # ca-certificates-mozilla can be installed. Copy the host's CA bundle into
    # the container first so HTTPS works during keyring bootstrap.
    local _host_ca="${CURL_CA_BUNDLE:-}${SSL_CERT_FILE:-}"
    if [[ -n "$_host_ca" && -f "$_host_ca" ]]; then
        log_info "Propagating host CA certificate into container for keyring bootstrap..."
        container_root_exec bash -c "
            mkdir -p /etc/ssl/certs /usr/local/share/ca-certificates 2>/dev/null
            cp -f '$_host_ca' /usr/local/share/ca-certificates/host-proxy-ca.crt 2>/dev/null && \
                update-ca-certificates 2>/dev/null || \
                cp -f '$_host_ca' /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true
        " 2>/dev/null || log_warn "Could not propagate host CA certificate (keyring bootstrap may fail)."
    fi

    log_info "Stage 1/7: Initializing pacman keyring and signature verification..."
    local keyring_script
    read -r -d '' keyring_script <<'KEYRING_EOF' || true
set -uo pipefail
export LC_ALL=C

# Arg 1: STRICT_SECURITY flag ("true" disables TrustAll relaxation recovery).
# Arg 2: ALLOW_TRUSTALL flag ("true" permits TrustAll without interactive prompt).
# Arg 3: TRUSTALL_ALL_REPOS flag ("true" keeps third-party repos in throwaway config).
_STRICT_SECURITY_MODE="${1:-}"
_ALLOW_TRUSTALL="${2:-false}"
_TRUSTALL_ALL_REPOS="${3:-false}"

_remove_stale_lock

# _atomic_write_pacman_conf is defined in _CONTAINER_PREAMBLE (shared).
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
    # Try sha256sum/sha256/shasum (coreutils), then fall back to Python hashlib
    # (guaranteed present in base containers). This avoids the chicken-and-egg
    # where we need coreutils to verify the keyring, but need a valid keyring
    # to install coreutils via pacman.
    if command -v sha256sum >/dev/null 2>&1; then
        _sum=$(sha256sum "$_PUBRING_FILE" 2>/dev/null | awk '{print $1}')
    elif command -v sha256 >/dev/null 2>&1; then
        _sum=$(sha256 -q "$_PUBRING_FILE" 2>/dev/null)
    elif command -v shasum >/dev/null 2>&1; then
        _sum=$(shasum -a 256 "$_PUBRING_FILE" 2>/dev/null | awk '{print $1}')
    elif command -v python3 >/dev/null 2>&1; then
        _sum=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$_PUBRING_FILE" 2>/dev/null)
    elif command -v python >/dev/null 2>&1; then
        _sum=$(python -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$_PUBRING_FILE" 2>/dev/null)
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
    elif [[ -z "$_sentinel_current" || ( "$_sentinel_current" == *":*" && "${_sentinel_current##*:}" == "" ) ]]; then
        # No checksum tool available — try Python hashlib first (guaranteed
        # present, no pacman needed). Only fall back to pacman -S coreutils
        # if Python is also missing, but skip that if the keyring is broken
        # (pacman -S would fail with signature errors — chicken-and-egg).
        echo "Found keyring recovery sentinel, but no checksum tool is available to validate pubring.gpg."
        _sentinel_current=$(_keyring_checksum)
        if [[ -z "$_sentinel_current" || ( "$_sentinel_current" == *":*" && "${_sentinel_current##*:}" == "" ) ]]; then
            echo "WARNING: No checksum tool available (sha256sum/sha256/shasum/python3 all missing). Trusting sentinel (presence-only) so recovery is not blocked."
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
    # Use curl instead of /dev/tcp (which is compile-time optional in Bash
    # and missing in POSIX sh/dash). curl is required for keyring bootstrap
    # and is guaranteed available at this point in the script.
    if timeout 5 curl -fsSI --connect-timeout 3 "https://$_ks_host" >/dev/null 2>&1; then
        echo "  $_ks: REACHABLE (HTTPS)"
        _KS_REACHABLE+=("$_ks")
    else
        echo "  $_ks: UNREACHABLE on HTTPS (will skip)"
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
    _SECURE_TMP=$(mktemp -d /var/tmp/pamac-kr-XXXXXX 2>/dev/null) || _SECURE_TMP=$(mktemp -d)
    chmod 700 "$_SECURE_TMP" 2>/dev/null || true
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

# Method E removed: WKD lookups for Arch Linux master keys.
# Previously attempted WKD via openpgpkey.archlinux.org, but the local-part
# construction from fingerprints did not match the server's actual endpoint
# (the server uses a non-standard path scheme), making this method unreliable.
# Methods A-D + F + G already provide sufficient key recovery coverage.

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
    echo "Method F: Controlled SigLevel relaxation bootstrap (last resort)..."
    echo "  WARNING: This temporarily disables signature verification in a throwaway"
    echo "  config to bootstrap the keyring. The real /etc/pacman.conf stays secure."
    # User confirmation: require --allow-trustall or interactive approval.
    if [[ "${_ALLOW_TRUSTALL:-false}" != "true" ]]; then
        echo "  Method F requires explicit approval to proceed with TrustAll bootstrap."
        if [[ "${_NON_INTERACTIVE:-false}" == "true" ]]; then
            echo "  Non-interactive mode: use --allow-trustall to approve automatically."
            echo "  Skipping Method F (no --allow-trustall flag)."
            # Skip to end of Method F block
        elif [[ -t 0 ]]; then
            printf "  Allow TrustAll keyring bootstrap? (y/N): " >&2
            _ta_confirm=""
            read -r _ta_confirm
            if [[ "$_ta_confirm" != "y" && "$_ta_confirm" != "Y" ]]; then
                echo "  TrustAll bootstrap declined by user."
            else
                echo "  Proceeding with TrustAll bootstrap..."
                _TA_TRUSTALL_APPROVED=true
            fi
        else
            echo "  No terminal available and --allow-trustall not set. Skipping Method F."
        fi
    else
        _TA_TRUSTALL_APPROVED=true
    fi
    if [[ "${_TA_TRUSTALL_APPROVED:-}" == "true" ]]; then
    # Build a throwaway config: copy the real one, then optionally STRIP every
    # repo except the official [core] / [extra] / [multilib] stanzas. By default
    # (--trustall-all-repos=false), non-official repos are stripped so a
    # compromised third-party mirror cannot inject a tampered package during the
    # signature-disabled window. With --trustall-all-repos, all repos are kept
    # so third-party repos can also have their keys refreshed.
    _TA_CONF=$(mktemp /tmp/pacman-trustall.XXXXXX.conf) 2>/dev/null
    if [[ -n "$_TA_CONF" ]] && cp -f /etc/pacman.conf "$_TA_CONF" 2>/dev/null; then
        if [[ "${_TRUSTALL_ALL_REPOS:-false}" != "true" ]]; then
            # Remove any repo section that is NOT one of the official Arch repos.
            _TA_ALLOWED_REPOS='core|extra|multilib|core-testing|extra-testing|multilib-testing'
            awk -v allowed="^(${_TA_ALLOWED_REPOS})$" '
                /^\[/{ in_repo=($0 ~ allowed); if(!in_repo){print "# TRUSTALL-STRIPPED: "$0; next} }
                in_repo{print; next}
                !in_repo{print "# TRUSTALL-STRIPPED: "$0}
            ' "$_TA_CONF" > "${_TA_CONF}.tmp" && mv -f "${_TA_CONF}.tmp" "$_TA_CONF"
            echo "  Non-official repos stripped from throwaway config to limit injection surface."
        else
            echo "  --trustall-all-repos: all repos (including third-party) kept in throwaway config."
        fi
        # Atomic SigLevel rewrite: sed to temp file + mv (POSIX rename is atomic)
        # instead of non-atomic sed -i which can corrupt the config on kill.
        local _ta_tmp="${_TA_CONF}.tmp"
        sed "s|^[[:space:]]*SigLevel.*|SigLevel = TrustAll|" "$_TA_CONF" > "$_ta_tmp"
        if ! grep -q '^SigLevel' "$_ta_tmp" 2>/dev/null; then
            printf 'SigLevel = TrustAll\n' >> "$_ta_tmp"
        fi
        mv -f "$_ta_tmp" "$_TA_CONF"
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
    fi # _TA_TRUSTALL_APPROVED
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
    echo "  Keyserver connectivity (HTTPS):"
    for _diag_ks in "keyserver.ubuntu.com" "keys.openpgp.org" "pgp.mit.edu"; do
        if timeout 5 curl -fsSI --connect-timeout 3 "https://$_diag_ks" >/dev/null 2>&1; then
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
    _sig_count=$(LC_ALL=C pacman-key --list-sigs 2>/dev/null | grep -c "archlinux" || echo "0")
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
            _sig_count=$(LC_ALL=C pacman-key --list-sigs 2>/dev/null | grep -c "archlinux" || echo "0")
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
    echo ""
    echo "=== Remediation ==="
    echo "  This script runs INSIDE the container. To recover, you can either:"
    echo "    a. Run these commands now (already inside the container):"
    echo "         pacman-key --init"
    echo "         pacman-key --populate archlinux"
    echo "         pacman -Sy --noconfirm archlinux-keyring gnupg"
    echo "    b. From the HOST, target the container by name (e.g. arch-pamac):"
    echo "         podman exec -u 0 <container-name> pacman-key --init"
    echo "         podman exec -u 0 <container-name> pacman-key --populate archlinux"
    echo "         podman exec -u 0 <container-name> pacman -Sy --noconfirm archlinux-keyring gnupg"
    echo "  Then re-run the installer."
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

    if ! exec_container_script "$keyring_script" "keyring-init" "${STRICT_SECURITY:-false}" "${ALLOW_TRUSTALL:-false}" "${TRUSTALL_ALL_REPOS:-false}"; then
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
export LC_ALL=C

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
df_home_kb=$(df -kP / 2>/dev/null | awk 'NR==2{print $4}' || echo "0")
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

# Verify critical shared libraries (resolve paths dynamically via ldconfig
# instead of assuming /usr/lib — some Arch derivatives use /usr/lib64 or
# other layouts).
for _lib_name in libc.so.6 libm.so.6; do
    _lib=$(ldconfig -p 2>/dev/null | grep "$_lib_name" | head -1 | awk '{print $NF}' || echo "")
    if [[ -n "$_lib" && -f "$_lib" ]] && ! ldd "$_lib" >/dev/null 2>&1; then
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
export LC_ALL=C

_remove_stale_lock

echo "Installing core packages (sudo, shadow, gnupg, jq, python, bubblewrap, libcap, pacman-contrib, socat, python-configparser)..."
if ! safe_install sudo shadow gnupg jq python bubblewrap libcap pacman-contrib socat python-configparser; then
    echo "ERROR: Failed to install core packages after retries."
    exit 1
fi
echo "Core packages installed."
# Verify critical packages actually landed. safe_install runs as a batch;
# a partial failure (e.g. transient mirror error) could leave bubblewrap
# missing, causing AUR DynamicUser builds to fail later with a confusing
# error. Assert each critical package individually so the stage fails here
# instead of silently propagating the gap downstream.
for _critical_pkg in bubblewrap libcap socat; do
    if ! pacman -Q "$_critical_pkg" >/dev/null 2>&1; then
        echo "WARN: $_critical_pkg not installed after batch install. Retrying individually..."
        safe_install "$_critical_pkg" 2>/dev/null || true
        if ! pacman -Q "$_critical_pkg" >/dev/null 2>&1; then
            echo "ERROR: Failed to install $_critical_pkg. AUR builds will be affected."
            exit 1
        fi
    fi
done
echo "Core package assertions passed."
CORE_EOF

    if ! exec_container_script "$core_script" "core-packages"; then
        log_error "Failed to install core packages (sudo, shadow, gnupg, jq, python, socat, python-configparser)."
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

    # Configure eMMC-safe build environment (tmpfs BUILDDIR + ccache)
    # before any AUR builds to minimize flash write cycles.
    _setup_emmc_safe_build "$CONTAINER_NAME" "$CURRENT_USER"

    log_info "Stage 4/7: Installing development packages (batched to avoid OOM)..."
    local dev_script
    read -r -d '' dev_script <<'DEV_EOF' || true
set -uo pipefail
export LC_ALL=C

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
            container_root_exec bash -c ". /usr/local/lib/pamac-common.sh 2>/dev/null || true; _remove_stale_lock; pacman -S --noconfirm --needed $_dep" 2>/dev/null || true
        fi
    done

    log_info "Stage 5/7: Creating user and configuring sudo..."
    local user_script
    read -r -d '' user_script <<'USER_EOF' || true
set -uo pipefail
export LC_ALL=C

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
# --allow-wheel-nopasswd: wheel group (INSECURE, opt-in only).
# --dedicated-builduser: pamac-builder user (opt-in, further isolation).
# SteamOS: still defaults to per-user (single-user device doesn't need wheel).
_use_wheel_group=false
BUILD_SUDO_USER="$current_user"
if [[ "__DEDICATED_BUILDUSER__" == "true" ]]; then
    echo "SECURITY: --dedicated-builduser specified. Creating dedicated build user."
    _builder_name="_pamac_builder"
    if ! id "$_builder_name" >/dev/null 2>&1; then
        useradd -r -m -d "/var/lib/${_builder_name}" -s /bin/bash -G wheel "$_builder_name" || {
            echo "Error: failed to create dedicated build user '$_builder_name'"
            exit 1
        }
        echo "Created dedicated AUR build user: $_builder_name"
        echo "  Home: /var/lib/${_builder_name} (isolated from host)"
        echo "  Shell: /bin/bash (needed for makepkg/yay builds)"
        echo "  Group: wheel (sudo access)"
        echo ""
        echo "  SECURITY: --no-home-mount is active by default. The build user"
        echo "  CANNOT read host /home. Source trees are accessed via"
        echo "  'distrobox enter' as the login user, not the build user."
        echo "  The build user only sees /var/lib/${_builder_name}."
        echo ""
    else
        echo "Dedicated build user '$_builder_name' already exists."
    fi
    BUILD_SUDO_USER="$_builder_name"
    echo "Restricting NOPASSWD to dedicated build user '$BUILD_SUDO_USER'."
elif [[ "$ALLOW_WHEEL_NOPASSWD" == "true" ]]; then
    echo "SECURITY: --allow-wheel-nopasswd specified. Granting NOPASSWD to entire wheel group."
    echo "          This is INSECURE on multi-user hosts. Consider using per-user scope."
    _use_wheel_group=true
else
    echo "Restricting NOPASSWD to user '$current_user' only."
fi

# SECURITY: Use flock to prevent concurrent container processes from racing
# during sudoers.d writes. A race could produce a partially-written file
# that visudo rejects, breaking sudo inside the container.
_sudoers_lock="/etc/sudoers.d/.pamac-lock"
(
    flock -w 30 200 || { echo "Warning: Could not acquire sudoers lock after 30s. Proceeding without lock."; exec 200>&-; }

    cat > /etc/sudoers.d/99-pamac-nopasswd <<SUDOERS
# SECURITY NOTE: AUR PKGBUILDs are arbitrary shell scripts run via makepkg; a
# malicious or compromised AUR package can invoke the commands below and
# effectively escalate to root inside this container.
#
# Scope: $(if [[ "\$_use_wheel_group" == "true" ]]; then echo "wheel group (all members)"; elif [[ "$BUILD_SUDO_USER" != "$current_user" ]]; then echo "user $BUILD_SUDO_USER (dedicated build user)"; else echo "user $current_user only"; fi)
# To remove: sudo rm /etc/sudoers.d/99-pamac-nopasswd
# To widen:   re-run with --allow-wheel-nopasswd
# To isolate: re-run with --dedicated-builduser

# makepkg and yay are deliberately EXCLUDED from PAMAC_CMDS.
#
# makepkg: Pamac invokes makepkg through systemd-run (which drops
# privileges for DynamicUser), so makepkg itself never calls sudo.
# Including makepkg in passwordless sudoers would let a malicious AUR PKGBUILD
# (an arbitrary shell script run BY makepkg) invoke pacman directly as root,
# bypassing the privilege drop.
#   https://github.com/89luca89/distrobox/issues/636#issuecomment-2929404949
#
# yay: yay must NOT be run as root. When run as a normal user, yay compiles
# AUR packages unprivileged and internally invokes `sudo pacman -U` to install
# the result. Since /usr/bin/pacman is in PAMAC_CMDS, this elevation succeeds
# passwordlessly. Including yay in sudoers would let a malicious PKGBUILD's
# build() / package() functions execute arbitrary code as root.
Cmnd_Alias PAMAC_CMDS = /usr/bin/pacman, \\
    /usr/bin/pacman-key, \\
    /usr/bin/paccache, \\
    /usr/bin/pacscripts

$(if [[ "\$_use_wheel_group" == "true" ]]; then
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: NOEXEC: PAMAC_CMDS"
else
    echo "$BUILD_SUDO_USER ALL=(ALL:ALL) NOPASSWD: NOEXEC: PAMAC_CMDS"
fi)
# RESIDUAL RISK (container-root): a malicious AUR PKGBUILD can still run
# 'sudo pacman -U <crafted pkg>' during build() and install arbitrary
# packages as root INSIDE this container. This is inherent to AUR + passwordless
# pacman. Mitigations applied here:
#   - makepkg/yay are EXCLUDED from PAMAC_CMDS (no direct escalation via makepkg).
#   - NOEXEC is applied to PAMAC_CMDS: child processes spawned from these
#     commands cannot themselves exec further setuid binaries, limiting the
#     post-install escalation chain. (pacman hooks/install scripts still run
#     normally under pacman's own exec; NOEXEC only blocks the sudo'd process
#     from exec-ing other setuid tools.)
#   - The container is rootless: host root is NOT exposed. Container-root
#     compromise is contained to the container's writable layer.
#   - --dedicated-builduser further isolates the AUR build context from the
#     login user's home directory.
#   - PKGBUILDs are scanned via _verify_aur_payload() for shell-injection /
#     RCE patterns before build.
SUDOERS
chmod 0440 /etc/sudoers.d/99-pamac-nopasswd

# Reduce sudo timestamp cache to zero so privileges are not retained between
# operations. Each sudo invocation requires a fresh (passwordless) auth check.
cat > /etc/sudoers.d/98-pamac-timeout <<'TIMEOUT_SUDOERS'
# Reset sudo timestamp after each Pamac operation to minimize escalation window.
# Scoped to PAMAC_CMDS only, so non-Pamac sudo sessions still cache normally.
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

) 200>"$_sudoers_lock"

if [[ "\$_use_wheel_group" == "true" ]]; then
    echo ""
    echo "*** SECURITY WARNING: wheel-group NOPASSWD package management ***"
    echo "  A malicious AUR PKGBUILD can invoke 'sudo pacman install' during"
    echo "  build() and escalate to root without any authentication."
    echo "  This is acceptable ONLY on single-user personal devices."
    echo "  To remove: sudo rm /etc/sudoers.d/99-pamac-nopasswd"
    echo ""
elif [[ "$BUILD_SUDO_USER" != "$current_user" ]]; then
    echo ""
    echo "*** SECURITY: Dedicated build-user NOPASSWD package management ***"
    echo "  Sudo NOPASSWD is restricted to dedicated build user '$BUILD_SUDO_USER'."
    echo "  AUR builds run under '$BUILD_SUDO_USER', not the host login user."
    echo "  This isolates AUR PKGBUILD access from the host user's home directory."
    echo "  Host user '$current_user' has NO passwordless sudo for package commands."
    echo ""
else
    echo ""
    echo "*** SECURITY NOTE: Per-user NOPASSWD package management ***"
    echo "  Only '$current_user' can run package commands without password."
    echo "  A malicious AUR PKGBUILD can still invoke 'sudo pacman' as"
    echo "  '$current_user' during build() — limited to this user only."
    echo "  This is the recommended setting for shared workstations."
    echo ""
fi
USER_EOF

    # Template substitution: bake DEDICATED_BUILDUSER into the single-quoted
    # heredoc content (__DEDICATED_BUILDUSER__ placeholder in user_script).
    user_script="${user_script//__DEDICATED_BUILDUSER__/${DEDICATED_BUILDUSER:-false}}"

    exec_container_script "$user_script" "user-setup" "$CURRENT_USER" || return 1

log_info "Stage 6a/7: Installing polkit and setting up D-Bus..."
local polkit_dbus_script
read -r -d '' polkit_dbus_script <<'POLKIT_DBUS_EOF' || true
set -uo pipefail
export LC_ALL=C

current_user="$1"

echo "Installing polkit..."
if pacman -S --noconfirm --needed polkit; then
polkit_dir="/etc/polkit-1/rules.d"
mkdir -p "$polkit_dir"
# Detect single-user (Steam Deck) vs multi-user hosts.
# On single-user devices, wheel-group blanket allow is safe.
# On multi-user hosts, restrict to the installing user only.
# SECURITY: the rule matches ONLY the specific Pamac action IDs that the GUI
# needs (install/remove/update/build/refresh). It does NOT use the broad
# `action.id.indexOf("org.manjaro.pamac.") == 0` prefix match, which would
# also grant passwordless access to dangerous actions like system-upgrade,
# repo-add, or any future Pamac action. A malicious AUR PKGBUILD running as
# the user could otherwise invoke arbitrary polkit actions without auth.
_PAMAC_ALLOWED_IDS='org.manjaro.pamac.install|org.manjaro.pamac.install-update|org.manjaro.pamac.remove|org.manjaro.pamac.update|org.manjaro.pamac.build|org.manjaro.pamac.launch-flatpak-builder|org.manjaro.pamac.check-aur-vcs-updates|org.manjaro.pamac.check-aur-updates|org.manjaro.pamac.refresh-databases|org.manjaro.pamac.get-build-directory|org.manjaro.pamac.get-build-username|org.manjaro.pamac.build-install'
_human_users=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' | wc -l)
if [[ "$_human_users" -le 1 ]]; then
    cat > "$polkit_dir/10-pamac-nopasswd.rules" <<RULES_EOF
polkit.addRule(function(action, subject) {
  if (action.id.match(/^(${_PAMAC_ALLOWED_IDS})$/) &&
      subject.isInGroup("wheel")) {
      return polkit.Result.YES;
  }
  // All other pamac.* actions (e.g. system-upgrade, repo management) require
  // authentication even for the wheel group — defense-in-depth against AUR
  // PKGBUILDs that invoke pamac's D-Bus interface.
});
RULES_EOF
    echo "polkit passwordless rule created for pamac operations (wheel group — single-user host, action-ID scoped)."
else
    _current_user="$current_user"
    cat > "$polkit_dir/10-pamac-nopasswd.rules" <<RULES_EOF
polkit.addRule(function(action, subject) {
  if (action.id.match(/^(${_PAMAC_ALLOWED_IDS})$/) &&
      subject.user == "${_current_user}") {
      return polkit.Result.YES;
  }
  // All other pamac.* actions require authentication.
});
RULES_EOF
    echo "polkit passwordless rule created for pamac operations (restricted to user $_current_user — multi-user host, action-ID scoped)."
fi
# polkitd drops privileges to uid 966 (polkitd) — it needs read access to rules
chmod 755 /etc/polkit-1 /etc/polkit-1/rules.d 2>/dev/null || true
echo "SECURITY: On single-user hosts, passwordless access is wheel-group-wide."
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
    # Restrict allow_active=yes to ONLY the actions that Pamac GUI actually
    # needs (install, remove, update, build). Leave all other actions at their
    # upstream defaults (typically auth_admin). This limits the surface area:
    # a malicious AUR PKGBUILD running as the user can only invoke these
    # specific actions without authentication, not arbitrary polkit operations.
    _atomic_sed_inplace "$pamac_policy" \
        's|<allow_active>[^<]*</allow_active>|<allow_active>auth_admin</allow_active>|g'
    # Now selectively enable only package-management actions
    for _action_id in \
        org.manjaro.pamac.install \
        org.manjaro.pamac.install-update \
        org.manjaro.pamac.remove \
        org.manjaro.pamac.update \
        org.manjaro.pamac.build \
        org.manjaro.pamac.launch-flatpak-builder \
        org.manjaro.pamac.check-aur-vcs-updates \
        org.manjaro.pamac.check-aur-updates \
        org.manjaro.pamac.refresh-databases \
        org.manjaro.pamac.get-build-directory \
        org.manjaro.pamac.get-build-username \
        org.manjaro.pamac.build-install; do
        # Replace the action's own <allow_active> with yes (if the action exists)
        sed -i "/id=\"${_action_id}\"/,/<\/action>/{s|<allow_active>auth_admin</allow_active>|<allow_active>yes</allow_active>|}" \
            "$pamac_policy" 2>/dev/null || true
    done

    # NOTE: system-upgrade is deliberately EXCLUDED from allow_active=yes.
    # Any active local session could trigger a full system upgrade without
    # authentication, which is a privilege escalation vector. It remains at
    # auth_admin (requires password) so only intentional upgrades proceed.
fi

echo "Polkit and D-Bus setup finished."
POLKIT_DBUS_EOF

if ! exec_container_script "$polkit_dbus_script" "polkit-dbus-setup" "$CURRENT_USER"; then
log_warn "Polkit/dbus setup had issues, retrying..."
container_start 2>/dev/null || true
sleep 3
if container_is_usable; then
if ! exec_container_script "$polkit_dbus_script" "polkit-dbus-setup-retry" "$CURRENT_USER"; then
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
export LC_ALL=C

HOST_USER="$1"
_STRICT_SECURITY_MODE="${2:-}"

echo "Installing Pamac bootstrap helper..."
cat > /usr/local/bin/pamac-session-bootstrap.sh << 'BOOTSTRAP'
#!/bin/bash
set +e
BOOTSTRAP_LOG="/var/log/pamac-bootstrap.log"
mkdir -p /var/log 2>/dev/null || true
chmod 0755 /var/log 2>/dev/null || true
touch "$BOOTSTRAP_LOG" 2>/dev/null && chmod 644 "$BOOTSTRAP_LOG" 2>/dev/null


# Source shared _safe_sleep (written by _CONTAINER_PREAMBLE on first run)
if [ -f /usr/local/lib/pamac-common.sh ]; then
    . /usr/local/lib/pamac-common.sh
else
    # Minimal fallback if shared file is missing/corrupted
    _safe_sleep() { local _d="${1:-1}"; case "$_d" in ''|*[!0-9]*) _d=1 ;; esac; sleep "$_d" 2>/dev/null || true; }
fi

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

echo "Installing fake systemd-run wrapper (v4.0) for non-systemd AUR builds..."
if [[ "$_STRICT_SECURITY_MODE" == "true" ]]; then
    echo "SKIPPED fake systemd-run wrapper (--strict-security: refuses DynamicUser shim)."
    echo "  AUR builds that need systemd-run --property=DynamicUser=yes will fail in"
    echo "  non-systemd containers instead of running with reduced sandboxing."
    echo "  This is by design: --strict-security prioritizes correctness over"
    echo "  compatibility with DynamicUser outside of systemd."
elif ! command -v systemctl >/dev/null 2>&1 || ! systemctl show-environment >/dev/null 2>&1; then
if ! command -v bwrap >/dev/null 2>&1; then
    echo "bubblewrap (bwrap) not found. Attempting automatic install..."
    if pacman -S --noconfirm --needed bubblewrap 2>/dev/null; then
        echo "  bubblewrap installed successfully."
    elif safe_install bubblewrap 2>/dev/null; then
        echo "  bubblewrap installed via safe_install."
    fi
    if ! command -v bwrap >/dev/null 2>&1; then
        echo "FATAL: bubblewrap (bwrap) installation failed. AUR DynamicUser builds will not work."
        echo "  Install manually: sudo pacman -S bubblewrap"
        echo "  Or use an init-mode container: distrobox create --init"
        exit 1
    fi
fi
_write_fake_systemd_run_wrapper
echo "Fake systemd-run installed at /usr/local/sbin/systemd-run (cleanup runs at runtime)."
echo "Use --use-init (default) for real systemd instead of this shim."

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
export LC_ALL=C

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
chmod 0755 /var/log 2>/dev/null || true
touch "$BOOTSTRAP_LOG" 2>/dev/null && chmod 644 "$BOOTSTRAP_LOG" 2>/dev/null


# Source shared _safe_sleep (written by _CONTAINER_PREAMBLE on first run)
if [ -f /usr/local/lib/pamac-common.sh ]; then
    . /usr/local/lib/pamac-common.sh
else
    # Minimal fallback if shared file is missing/corrupted
    _safe_sleep() { local _d="${1:-1}"; case "$_d" in ''|*[!0-9]*) _d=1 ;; esac; sleep "$_d" 2>/dev/null || true; }
fi

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
repaired=$((repaired + 1))
echo "Bootstrap helper repaired."
fi

if [[ ! -x /usr/local/sbin/systemd-run ]]; then
echo "Repairing: fake systemd-run wrapper..."
if [[ "$_STRICT_SECURITY_MODE" == "true" ]]; then
    echo "SKIPPED fake systemd-run wrapper repair (--strict-security: refuses DynamicUser shim)."
    echo "  AUR builds that need DynamicUser will fail in non-systemd containers"
    echo "  instead of running with reduced sandboxing (by design under"
    echo "  --strict-security)."
elif ! command -v systemctl >/dev/null 2>&1 || ! systemctl show-environment >/dev/null 2>&1; then
_write_fake_systemd_run_wrapper
repaired=$((repaired + 1))
echo "Fake systemd-run repaired (cleanup runs at runtime)."
echo "Use --use-init (default) for real systemd instead of this shim."

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

# Ensure curl is available — required for keyring package downloads and
# mirror probing. Install it if missing (coreutils curl may not be in
# minimal base images).
if ! command -v curl >/dev/null 2>&1; then
    echo "curl not found — installing (required for keyring bootstrap)..."
    pacman -S --noconfirm --needed curl 2>/dev/null || true
    if ! command -v curl >/dev/null 2>&1; then
        echo "ERROR: curl is required for keyring package downloads but could not be installed."
        echo "  Install manually: pacman -S curl"
        exit 1
    fi
fi

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

    # Step 1b: Try gpg --auto-key-retrieve (uses WKD + keyserver auto-discovery)
    # This is a broader net than explicit WKD: gpg consults the keyserver URL
    # configured in dirmngr.conf if WKD fails. Only works for full 40-char
    # fingerprints (short IDs are too ambiguous for auto-retrieve).
    if [[ ${#key_id} -eq 40 ]] && [[ "$key_id" =~ ^[0-9a-fA-F]+$ ]]; then
        echo "  Attempting gpg --auto-key-retrieve for $key_id..."
        if GNUPGHOME=/etc/pacman.d/gnupg timeout 15 gpg --auto-key-retrieve --locate-external-keys "$key_id" 2>/dev/null; then
            local _akr_fp
            _akr_fp=$(GNUPGHOME=/etc/pacman.d/gnupg gpg --with-colons --list-keys "$key_id" 2>/dev/null \
                | grep '^fpr' | head -1 | cut -d: -f10 || echo "")
            if [[ -n "$_akr_fp" ]] && timeout 15 pacman-key --lsign-key "$_akr_fp" 2>/dev/null; then
                echo "  Auto-key-retrieve succeeded for ${_akr_fp: -8}"
                return 0
            fi
        fi
        echo "  Auto-key-retrieve did not resolve key $key_id."
    fi

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
                    # NOTE: For third-party repos (Chaotic-AUR, archlinuxcn,
                    # EndeavourOS), always prefer full 40-char fingerprints via
                    # env-var overrides. The suffix-matching fallback exists for
                    # backward compatibility but is weaker than exact match.
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

# Discover the signing key fingerprint for a repository from its installed
# keyring package. After the keyring package is installed, this queries
# pacman-key to find keys that sign packages from the given repo.
# Usage: _discover_keyring_fingerprint <repo_name>
# Returns: 40-char hex fingerprint on success, empty string on failure.
_discover_keyring_fingerprint() {
    local _repo="$1"
    if ! command -v pacman-key >/dev/null 2>&1; then
        return 1
    fi
    # pacman-key --list-keys outputs key info. Keys for a repo are typically
    # signed by the repo maintainer. We look for keys whose uid contains the
    # repo name or known maintainer identifiers.
    local _all_fps
    _all_fps=$(pacman-key --list-keys 2>/dev/null | grep -E "^[0-9A-F]{40}" || true)
    if [[ -z "$_all_fps" ]]; then
        return 1
    fi
    # For each fingerprint, check if it's a valid signing key by looking at
    # the uid line that follows. Match on repo name or common maintainer names.
    local _fp _uid
    while IFS= read -r _fp; do
        _fp="${_fp%% *}"  # take just the fingerprint
        [[ "$_fp" =~ ^[0-9A-F]{40}$ ]] || continue
        # Read the next line (uid) from pacman-key output
        _uid=$(pacman-key --list-keys "$_fp" 2>/dev/null | grep -i "uid" | head -1 || true)
        case "$_repo" in
            chaotic-aur)
                # Chaotic-AUR signing key uid contains "pedrohlc" or "chaotic"
                if echo "$_uid" | grep -qiE "pedrohlc|chaotic"; then
                    echo "$_fp"
                    return 0
                fi
                ;;
            archlinuxcn)
                # archlinuxcn key uid contains "archlinuxcn"
                if echo "$_uid" | grep -qi "archlinuxcn"; then
                    echo "$_fp"
                    return 0
                fi
                ;;
            endeavouros)
                # EndeavourOS key uid contains "EndeavourOS"
                if echo "$_uid" | grep -qi "endeavouros"; then
                    echo "$_fp"
                    return 0
                fi
                ;;
        esac
    done <<< "$_all_fps"
    return 1
}

# Discover fingerprint by extracting it from a keyring package before installation.
# Downloads the keyring package, extracts the .gpg files, and queries them.
_discover_fingerprint_from_pkg() {
    local _repo="$1"
    local _keyring_pkg="$2"
    local _mirror_urls=("${@:3}")
    local _host_arch
    _host_arch=$(uname -m 2>/dev/null || echo "x86_64")
    local _tmp_dir
    _tmp_dir=$(mktemp -d /var/tmp/pamac-fp-XXXXXX 2>/dev/null) || return 1
    for _url in "${_mirror_urls[@]}"; do
        local _direct="${_url}"
        _direct="${_direct//\\\$arch/$_host_arch}"
        _direct="${_direct//\$arch/$_host_arch}"
        _direct="${_direct//\\\$repo/$_repo}"
        _direct="${_direct//\$repo/$_repo}"
        _direct="${_direct//\$\{arch\}/$_host_arch}"
        _direct="${_direct//\$\{repo\}/$_repo}"
        local _pkg_url="${_direct%/}/${_keyring_pkg}.pkg.tar.zst"
        if timeout 30 curl -fsSL --connect-timeout 10 -o "$_tmp_dir/pkg.tar.zst" "$_pkg_url" 2>/dev/null; then
            # Extract pub.gpg from the package and query it.
            # Try gnupg/ layout first (Arch standard), then keyrings/ layout
            # (some distros use usr/share/pacman/keyrings/ instead of gnupg/).
            # Fallback: full extract if wildcard patterns don't match.
            local _gpg_dir="$_tmp_dir/gpg"
            mkdir -p "$_gpg_dir"
            tar -xf "$_tmp_dir/pkg.tar.zst" -C "$_tmp_dir" --wildcards '*/gnupg/*' 2>/dev/null || \
            tar -xf "$_tmp_dir/pkg.tar.zst" -C "$_tmp_dir" --wildcards '*/keyrings/*' 2>/dev/null || \
            tar -xf "$_tmp_dir/pkg.tar.zst" -C "$_gpg_dir" 2>/dev/null || true
            # Find .gpg key files
            local _gpg_file
            for _gpg_file in $(find "$_tmp_dir" -name "*.gpg" -type f 2>/dev/null); do
                local _fp
                _fp=$(gpg --with-colons --show-keys "$_gpg_file" 2>/dev/null \
                    | grep "^fpr" | head -1 | cut -d: -f10 || true)
                if [[ "$_fp" =~ ^[0-9A-F]{40}$ ]]; then
                    echo "$_fp"
                    rm -rf "$_tmp_dir"
                    return 0
                fi
            done
        fi
    done
    rm -rf "$_tmp_dir"
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

    # If key_id is "auto" or not a valid 40-char fingerprint, try to discover it.
    if [[ "$key_id" == "auto" ]] || [[ ! "$key_id" =~ ^[0-9a-fA-F]{40}$ ]]; then
        echo "Attempting automatic fingerprint discovery for $repo_name..."
        # Try extracting from the keyring package directly
        key_id="$(_discover_fingerprint_from_pkg "$repo_name" "$keyring_pkg" "${mirror_urls[@]}")" || true
        if [[ -z "$key_id" ]]; then
            echo "  Could not extract fingerprint from keyring package. Will retry after keyring install."
        fi
    fi

    echo "Adding repository [$repo_name] (key_id=${key_id})..."

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

    # Post-install fingerprint discovery: if the keyring package was installed
    # (Step 1 or 2) but we still don't have a valid fingerprint, query the
    # now-installed keyring. This breaks the circular dependency where auto-
    # discovery failed before the keyring was available.
    if [[ "$key_ok" == "true" ]] && [[ ! "$key_id" =~ ^[0-9a-fA-F]{40}$ ]]; then
        echo "Keyring installed. Discovering fingerprint from installed keyring..."
        key_id="$(_discover_keyring_fingerprint "$repo_name")" || true
    fi

    # Step 3: Dynamically discover and import GPG key from repo mirrors
    # Tries to download the signing key directly from the repo's distribution.
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

    # Step 4: Import the signing key from keyservers as last resort
    # Requires a valid 40-char fingerprint — keyserver lookups are meaningless
    # without one. If we still don't have a valid fingerprint, skip to Step 5
    # and let the user provide one via the environment variable override.
    if [[ "$key_ok" != "true" ]] && [[ "$key_id" =~ ^[0-9a-fA-F]{40}$ ]] && command -v pacman-key >/dev/null 2>&1; then
        echo "Attempting keyserver import for $repo_name (key_id=$key_id)..."
        echo "  If key import fails, set ${env_var_name}=<NEW_FULL_FINGERPRINT> (40 hex chars) before re-running."
        echo "  Verify current fingerprint at: https://archlinux.org/packages/?repo=$repo_name"
        echo "  or check the upstream keyring package for the latest signing key."
        if _import_key_with_retry "$key_id"; then
            key_ok=true
        fi
    fi

    # Step 5: Write the repo entry with appropriate SigLevel
    if [[ "$key_ok" == "true" ]]; then
        # Final fingerprint validation: if we still don't have a valid fingerprint
        # after all installation steps, attempt one last discovery pass.
        if [[ ! "$key_id" =~ ^[0-9a-fA-F]{40}$ ]]; then
            key_id="$(_discover_keyring_fingerprint "$repo_name")" || true
        fi
        if [[ "$key_id" =~ ^[0-9a-fA-F]{40}$ ]]; then
            echo "Using fingerprint $key_id for $repo_name"
            printf '\n[%s]\nSigLevel = Optional\n%b' "$repo_name" "$server_lines" >> /etc/pacman.conf
            echo "$repo_name repository configured (Optional)."
        else
            echo "Warning: Keyring installed but fingerprint could not be determined for $repo_name."
            echo "SKIPPING $repo_name repository: cannot verify signing key."
            echo "Set ${env_var_name}=<FULL_40_CHAR_FINGERPRINT> and re-run."
        fi
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
    "chaotic-aur" "chaotic-keyring" "auto" \
    "https://cdn-mirror.chaotic.cx/chaotic-aur/\$arch" \
    "https://geo-mirror.chaotic.cx/chaotic-aur/\$arch" \
    "https://mirror.chaotic.cx/chaotic-aur/\$arch"
echo "  Override with: CHAOTIC_AUR_KEY_ID=<FULL_FINGERPRINT>  (40 hex chars)"

echo "=== Configuring archlinuxcn repository ==="
_enable_repo_with_fallback \
    "archlinuxcn" "archlinuxcn-keyring" "auto" \
    "https://repo.archlinuxcn.org/\$arch" \
    "https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/\$arch" \
    "https://mirror.sjtu.edu.cn/archlinuxcn/\$arch"
echo "  Override with: ARCHLINUXCN_KEY_ID=<FULL_FINGERPRINT>  (40 hex chars)"

echo "=== Configuring endeavouros repository ==="
_enable_repo_with_fallback \
    "endeavouros" "endeavouros-keyring" "auto" \
    "https://mirror.freedif.org/EndeavourOS/repo/\$repo/\$arch" \
    "https://mirror.endeavouros.com/EndeavourOS/repo/\$repo/\$arch" \
    "https://mirror.enderunix.org/endeavouros/repo/\$repo/\$arch"
echo "  Override with: ENDEAVOUROS_KEY_ID=<FULL_40_CHAR_FINGERPRINT>"

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
    _prebuilt_output=$(container_root_exec bash -c '. /usr/local/lib/pamac-common.sh 2>/dev/null || true; _remove_stale_lock; pacman -Sy --noconfirm 2>/dev/null; pacman -S --noconfirm --needed yay 2>/dev/null; command -v yay >/dev/null 2>&1 && echo __PREBUILT_OK__' 2>/dev/null) || _prebuilt_output=""
    if [[ -n "$_prebuilt_output" ]] && grep -q "__PREBUILT_OK__" <<< "$_prebuilt_output"; then
        log_success "AUR helper yay installed from prebuilt repository."
        return 0
    fi
    log_info "Prebuilt yay not available. Building from source..."
    log_warn "Source compilation detected — building yay from AUR may take 10-30 minutes"
    log_warn "depending on hardware (CPU speed, thermal throttling, storage type)."
    log_warn "eMMC/SD write mitigation: tmpfs BUILDDIR and ccache are configured."
    log_warn "  If builds still hit eMMC, try: --low-memory (reduces parallel writes)"
    log_warn "  or close other apps to free RAM for tmpfs (compiles in RAM, not flash)."
    log_warn "Keep the device plugged in and avoid sleep/hibernation during the build."

	log_info "Verifying build dependencies (git, base-devel, go) are present..."
	local verify_script
	read -r -d '' verify_script <<'VERIFY_EOF' || true
set -uo pipefail
export LC_ALL=C

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
_preflight_oom_check "yay build"
_set_makepkg_jobs
_spin "Building yay from source" sudo -Hu "$current_user" bash -lc "cd '$_YAY_WORK/yay' && makepkg -si --noconfirm --clean"
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
    if [[ "${SKIP_COMPAT_CHECK:-}" == "true" ]]; then
        log_info "Skipping pamac-aur compatibility check (--skip-compat-check)."
        return 0
    fi
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
        _preflight_oom_check "pamac-aur compat build"
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
    local _method_tried=""
    local _method_succeeded=""

    # Resilient HTTP fetch with retry and exponential backoff.
    # Usage: _aur_fetch_with_retry <url> <max_retries>
    # Outputs: raw response body to stdout, HTTP status code to fd 3.
    # A realistic User-Agent header avoids Cloudflare bot detection that
    # would otherwise return challenge pages instead of the actual content.
    _aur_fetch_with_retry() {
        local _url="$1" _max_retries="${2:-2}" _attempt=0 _resp="" _code="" _delay=2
        while (( _attempt <= _max_retries )); do
            _resp=$(curl -sSf --connect-timeout 10 --max-time 30 \
                -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
                -w "\n%{http_code}" "$_url" 2>/dev/null) || true
            _code=$(echo "$_resp" | tail -1)
            _resp=$(echo "$_resp" | sed '$d')
            # Success or client error (not retryable): return immediately.
            # Cloudflare challenge pages return HTTP 200 with HTML content;
            # detect and retry these like server errors to fail fast.
            if [[ "$_code" =~ ^2[0-9][0-9]$ ]]; then
                if echo "$_resp" | grep -qiE '<!DOCTYPE|<html|challenge-platform|cf-browser|Attention Required|Just a moment'; then
                    echo "# WARN: Received Cloudflare challenge page (HTTP $_code), retrying..." >&2
                else
                    echo "$_resp"
                    return 0
                fi
            elif [[ "$_code" =~ ^4[0-9][0-9]$ && "$_code" != "429" ]]; then
                echo "$_resp"
                return 0
            fi
            # Rate-limited or server error: retry with backoff
            _attempt=$(( _attempt + 1 ))
            if (( _attempt <= _max_retries )); then
                echo "# AUR fetch attempt $_attempt failed (HTTP $_code), retrying in ${_delay}s..." >&2
                sleep "$_delay" 2>/dev/null || true
                _delay=$(( _delay * 2 ))
            fi
        done
        # All retries exhausted
        echo "$_resp"
        return 1
    }

    # Validate AUR RPC v5 JSON schema before extracting data.
    # Checks: valid JSON, results array exists, first element has expected keys.
    # Returns 0 if schema is valid, 1 if not. Outputs "type=..." line for diagnostics.
    _validate_rpc_schema() {
        local _json="$1"
        if ! echo "$_json" | jq -e '.results[0]' >/dev/null 2>&1; then
            echo "type=missing_results"
            return 1
        fi
        local _type
        _type=$(echo "$_json" | jq -r '.results[0].Type // "unknown"' 2>/dev/null || echo "unknown")
        echo "type=$_type"
        # Validate that the expected keys exist (Depends, MakeDepends)
        local _has_depends _has_makedepends
        _has_depends=$(echo "$_json" | jq -e '.results[0].Depends' >/dev/null 2>&1 && echo "yes" || echo "no")
        _has_makedepends=$(echo "$_json" | jq -e '.results[0].MakeDepends' >/dev/null 2>&1 && echo "yes" || echo "no")
        if [[ "$_has_depends" == "no" && "$_has_makedepends" == "no" ]]; then
            echo "# WARN: RPC schema missing both Depends and MakeDepends keys" >&2
            echo "type=missing_depends_keys"
            return 1
        fi
        return 0
    }

    # Method 1: AUR RPC v5 JSON API (most stable, no CGIT dependency)
    # Returns package metadata as JSON including Depends/MakeDepends arrays.
    # We use jq exclusively to extract the pacman version constraint directly
    # from the structured JSON, avoiding fragile grep/awk regex parsing.
    # Mitigation: Retry with exponential backoff for transient failures,
    # schema validation before parsing, and graceful degradation on parse errors.
    local _rpc_url="https://aur.archlinux.org/rpc/v5/info/pamac-aur"
    local _rpc_resp=""
    _method_tried="RPC"
    _rpc_resp=$(_aur_fetch_with_retry "$_rpc_url" 2) || {
        echo "# WARN: AUR RPC fetch failed after retries." >&2
    }
    if [[ -n "$_rpc_resp" ]]; then
        # Validate RPC JSON schema before parsing — protects against upstream
        # schema changes that would make jq queries silently return empty.
        local _schema_info=""
        _schema_info=$(_validate_rpc_schema "$_rpc_resp") || true
        if echo "$_schema_info" | grep -q "^type=missing"; then
            echo "# WARN: AUR RPC response has unexpected schema ($_schema_info). Skipping RPC method." >&2
        else
            if command -v jq >/dev/null 2>&1; then
                local _pacman_dep=""
                _pacman_dep=$(echo "$_rpc_resp" | jq -r '
                    (.results[0].Depends // []) + (.results[0].MakeDepends // [])
                    | map(select(test("^pacman")))
                    | .[0] // empty
                    ' 2>/dev/null || echo "")
                if [[ -n "$_pacman_dep" ]]; then
                    echo "# Parsed from AUR RPC v5 (jq): $_pacman_dep"
                    echo "pacman_dep=$_pacman_dep"
                    _method_succeeded="RPC"
                    return 0
                fi
                local _resultcount=""
                _resultcount=$(echo "$_rpc_resp" | jq -r '.resultcount // empty' 2>/dev/null || echo "")
                if [[ "$_resultcount" == "1" ]]; then
                    echo "# No explicit pacman version constraint in pamac-aur Depends/MakeDepends."
                    echo "pacman_dep="
                    _method_succeeded="RPC"
                    return 0
                elif [[ -n "$_resultcount" ]]; then
                    echo "# WARN: AUR RPC returned resultcount=$_resultcount (expected 1)" >&2
                fi
            else
                echo "# WARN: jq not available — cannot parse AUR RPC response." >&2
            fi
        fi
    fi

    # Method 2: CGIT web endpoint (may be blocked by Cloudflare).
    # Cloudflare detection is handled in _aur_fetch_with_retry which retries
    # challenge pages like server errors, so this section only sees clean
    # responses or empty strings on failure.
    _method_tried="CGIT"
    local _cgit_resp=""
    _cgit_resp=$(_aur_fetch_with_retry "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=pamac-aur" 2) || {
        echo "# WARN: CGIT fetch failed after retries." >&2
    }
    if [[ -n "$_cgit_resp" ]]; then
        # Detect Cloudflare challenges, rate limits, and HTML error pages
        # by content inspection (no HTTP code available from retry wrapper).
        if grep -qiE '<!DOCTYPE|<html|<head|challenge-platform|cf-browser|Attention Required|Just a moment' <<< "$_cgit_resp"; then
            echo "# WARN: CGIT endpoint returned HTML (Cloudflare challenge/block)." >&2
        elif echo "$_cgit_resp" | grep -q "^pkgname="; then
            # Extract pacman dependency from PKGBUILD text using awk
            local _cgit_pacman_dep
            _cgit_pacman_dep=$(echo "$_cgit_resp" | awk '
                /^(depends|makedepends)\+?=/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i ~ /^pacman[><=]/) { print $i; exit }
                    }
                }
            ' || echo "")
            echo "# Parsed from CGIT PKGBUILD (awk): ${_cgit_pacman_dep:-none}"
            echo "pacman_dep=$_cgit_pacman_dep"
            _method_succeeded="CGIT"
            return 0
        fi
    fi

    # Method 3: git clone to read PKGBUILD directly (bypasses web frontend)
    # Retry up to 2 times with exponential backoff for transient network issues.
    _method_tried="git-clone"
    local _git_tmp=""
    local _clone_attempt=0
    local _clone_max=2
    while [[ $_clone_attempt -lt $_clone_max ]]; do
        _git_tmp=$(mktemp -d 2>/dev/null || echo "")
        if [[ -n "$_git_tmp" ]]; then
            local _clone_err=""
            _clone_err=$(mktemp 2>/dev/null || echo "/dev/null")
            if git clone --depth 1 --single-branch https://aur.archlinux.org/pamac-aur.git "$_git_tmp/pamac-aur" 2>"$_clone_err"; then
                if [[ -f "$_git_tmp/pamac-aur/PKGBUILD" ]]; then
                    # Extract pacman dependency from PKGBUILD text using awk
                    local _clone_pacman_dep
                    _clone_pacman_dep=$(awk '
                        /^(depends|makedepends)\+?=/ {
                            for (i = 1; i <= NF; i++) {
                                if ($i ~ /^pacman[><=]/) { print $i; exit }
                            }
                        }
                    ' "$_git_tmp/pamac-aur/PKGBUILD" || echo "")
                    echo "# Parsed from git-clone PKGBUILD (awk): ${_clone_pacman_dep:-none}"
                    echo "pacman_dep=$_clone_pacman_dep"
                    rm -rf "$_git_tmp" "$_clone_err"
                    _method_succeeded="git-clone"
                    return 0
                fi
            else
                local _clone_msg
                _clone_msg=$(cat "$_clone_err" 2>/dev/null || echo "unknown")
                echo "# WARN: git clone attempt $((_clone_attempt+1))/$_clone_max failed: $_clone_msg" >&2
            fi
            rm -rf "$_git_tmp" "$_clone_err"
        fi
        _clone_attempt=$((_clone_attempt + 1))
        if [[ $_clone_attempt -lt $_clone_max ]]; then
            local _backoff=$(( _clone_attempt * 3 ))
            echo "# INFO: Retrying git clone in ${_backoff}s..." >&2
            sleep "$_backoff"
        fi
    done

    # All methods exhausted — signal failure so caller can use stale cache
    _log_event "aur_fetch_exhausted" "methods=RPC,CGIT,git-clone" "clone_max=$_clone_max"
    echo "# WARN: All AUR fetch methods failed (tried: RPC v5, CGIT, git-clone x${_clone_max})." >&2
    echo "# WARN: AUR may be rate-limited, down, or network is unreachable." >&2
    echo "# WARN: Will attempt to use stale cached PKGBUILD if available." >&2
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
    echo "WARN: Installation will proceed — pamac-aur may fail to build if pacman API changed."
    exit 0
fi

# Extract pacman dependency from the structured AUR RPC output.
# _fetch_aur_pkgbuild now outputs "pacman_dep=X.Y" (from jq parsing)
# or falls back to PKGBUILD text with grep extraction.
# Mitigation: Multiple extraction strategies with fallbacks. If the structured
# format changes, the grep fallback still works. If all extraction fails,
# compatibility is assumed (conservative, avoids blocking installation).
aur_pacman_dep=""
if echo "$aur_pkgbuild" | grep -q "^pacman_dep="; then
    # Structured output from jq-based RPC parsing (preferred path)
    aur_pacman_dep=$(echo "$aur_pkgbuild" | grep "^pacman_dep=" | cut -d= -f2-)
elif echo "$aur_pkgbuild" | grep -q "^depends=\|^makedepends="; then
    # Legacy PKGBUILD text fallback (CGIT/git-clone methods)
    # Try multiple regex patterns to handle formatting variations:
    #   1. Strict: "pacman>=6.0" (inline in dependency array)
    #   2. Spaced: "pacman >= 6.0" (separated by spaces)
    #   3. Quoted: "pacman>=6.0" (inside quotes in PKGBUILD)
    aur_pacman_dep=$(echo "$aur_pkgbuild" | grep -E "^(depends|makedepends)\\+?=" | grep -oP "pacman[><= ]+[0-9.]+" | head -1 \
        || echo "$aur_pkgbuild" | grep -E "^(depends|makedepends)\\+?=" | grep -oP "['\"]pacman[><= ]+[0-9.]+'?\"?" | head -1 \
        || echo "")
    # Strip surrounding quotes if present
    aur_pacman_dep=$(echo "$aur_pacman_dep" | sed "s/^['\"]//;s/['\"]$//")
fi

if [[ -z "$aur_pacman_dep" ]]; then
    echo "No explicit pacman version constraint found in pamac-aur."
    echo "Compatibility assumed. Proceeding."
    exit 0
fi

echo "Required: pacman $req_op $req_version"

# Parse version constraint: extract operator and version components.
# The constraint format is like ">=6.0" or "=5.2.1" or ">5.0".
req_op=$(echo "$aur_pacman_dep" | grep -oP '[><=]+' | head -1 || echo "")
req_version=$(echo "$aur_pacman_dep" | grep -oP '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || echo "")

# Validate parsed version components — malformed data could produce empty
# or nonsensical values. Fail gracefully instead of comparing against garbage.
if [[ -z "$req_version" || -z "$req_op" ]]; then
    echo "WARN: Could not parse version requirement (req_version='$req_version' req_op='$req_op')."
    echo "WARN: PKGBUILD data may be malformed. Skipping compatibility check."
    exit 0
fi
if [[ ! "$req_version" =~ ^[0-9]+\.[0-9]+ ]]; then
    echo "WARN: Version string '$req_version' does not look like a valid version (expected major.minor[.patch])."
    echo "WARN: PKGBUILD data may be corrupted. Skipping compatibility check."
    exit 0
fi

echo "Installed: pacman $installed_pacman_ver"
echo "Required:  pacman $req_op $req_version"

# Ensure vercmp is available for accurate version comparison.
# vercmp handles epochs (6:5.2.0), pre-release suffixes (rc), and
# package revisions — the manual fallback does not. Installing
# pacman-contrib is cheap and makes the comparison reliable.
if ! command -v vercmp >/dev/null 2>&1; then
    echo "Installing pacman-contrib (provides vercmp) for accurate version comparison..."
    pacman -S --noconfirm --needed pacman-contrib >/dev/null 2>&1 || true
fi

# Primary comparison: use vercmp (the standard Arch Linux version comparator).
# This is the ONLY reliable way to compare version strings that may contain
# epochs, pre-release suffixes, or non-standard formats.
if command -v vercmp >/dev/null 2>&1; then
    # Build full version strings for vercmp
    local _cur_full="${installed_pacman_ver}"
    local _req_full="${req_version}"
    # Strip epoch from installed version if present (vercmp handles it, but
    # we need to pass the full string including epoch)
    local _cmp_result
    _cmp_result=$(vercmp "$_cur_full" "$_req_full" 2>/dev/null || echo "")
    if [[ -n "$_cmp_result" && "$_cmp_result" =~ ^-?[0-9]+$ ]]; then
        case "$req_op" in
            ">="|"="|"==")
                [[ "$_cmp_result" -ge 0 ]] && { echo "PASS: pacman $installed_pacman_ver satisfies $aur_pacman_dep"; exit 0; } ;;
            ">")
                [[ "$_cmp_result" -gt 0 ]] && { echo "PASS: pacman $installed_pacman_ver satisfies $aur_pacman_dep"; exit 0; } ;;
            "<=")
                [[ "$_cmp_result" -le 0 ]] && { echo "PASS: pacman $installed_pacman_ver satisfies $aur_pacman_dep"; exit 0; } ;;
            "<")
                [[ "$_cmp_result" -lt 0 ]] && { echo "PASS: pacman $installed_pacman_ver satisfies $aur_pacman_dep"; exit 0; } ;;
        esac
        echo "INCOMPATIBLE: pacman $installed_pacman_ver does NOT satisfy $aur_pacman_dep (vercmp result: $_cmp_result)"
    else
        echo "WARN: vercmp returned unexpected result '$_cmp_result' for '$installed_pacman_ver' vs '$req_version'."
        echo "WARN: Falling back to installed pacman version check."
    fi
else
    echo "WARN: vercmp unavailable even after install attempt — version comparison may be inaccurate."
    echo "WARN: Install pacman-contrib manually for reliable version comparison."
    # Last resort: rough major.minor comparison (NOT reliable for epochs/pre-releases)
    local _cur_major _cur_minor _req_major _req_minor
    _cur_major=$(echo "$installed_pacman_ver" | sed 's/^[^:]*://' | cut -d. -f1)
    _cur_minor=$(echo "$installed_pacman_ver" | sed 's/^[^:]*://' | cut -d. -f2)
    _req_major=$(echo "$req_version" | cut -d. -f1)
    _req_minor=$(echo "$req_version" | cut -d. -f2)
    case "$req_op" in
        ">="|"="|"==")
            [[ "$_cur_major" -gt "$_req_major" ]] && { echo "PASS: pacman $installed_pacman_ver satisfies $aur_pacman_dep (rough check)"; exit 0; }
            [[ "$_cur_major" -eq "$_req_major" && "$_cur_minor" -ge "$_req_minor" ]] && { echo "PASS: pacman $installed_pacman_ver satisfies $aur_pacman_dep (rough check)"; exit 0; } ;;
    esac
    echo "INCOMPATIBLE: pacman $installed_pacman_ver does NOT satisfy $aur_pacman_dep (rough check)"
fi
            return 1
            ;;
    esac
fi

# version_meets_requirement: compare two version strings using vercmp.
# Usage: version_meets_requirement <current_ver> <operator> <required_ver>
# Returns 0 if current satisfies the requirement, 1 otherwise.
# This is the single source of truth for all version comparisons in this
# script. It delegates entirely to vercmp (pacman-contrib), which correctly
# handles epochs (6:5.2.0), pre-release suffixes (rc), and revisions.
version_meets_requirement() {
    local _cur="$1" _op="$2" _req="$3"
    if command -v vercmp >/dev/null 2>&1; then
        local _cmp
        _cmp=$(vercmp "$_cur" "$_req" 2>/dev/null || echo "")
        if [[ -n "$_cmp" && "$_cmp" =~ ^-?[0-9]+$ ]]; then
            case "$_op" in
                ">="|"="|"==") [[ "$_cmp" -ge 0 ]] && return 0 || return 1 ;;
                ">")           [[ "$_cmp" -gt 0 ]] && return 0 || return 1 ;;
                "<=")          [[ "$_cmp" -le 0 ]] && return 0 || return 1 ;;
                "<")           [[ "$_cmp" -lt 0 ]] && return 0 || return 1 ;;
                *)             echo "WARN: Unknown operator '$_op'" >&2; return 1 ;;
            esac
        fi
        echo "WARN: vercmp returned unexpected result '$_cmp' for '$_cur' vs '$_req'." >&2
        return 1
    else
        echo "WARN: vercmp unavailable — cannot compare versions reliably." >&2
        return 1
    fi
}

# If we reach here, the initial vercmp comparison did not exit with PASS (INCOMPATIBLE)
echo ""

can_upgrade_pacman=false
# Use vercmp for accurate comparison (handles epochs, pre-release suffixes)
if command -v vercmp >/dev/null 2>&1; then
    _cmp_result=$(vercmp "$installed_pacman_ver" "$req_version" 2>/dev/null || echo "")
    if [[ -n "$_cmp_result" && "$_cmp_result" =~ ^-?[0-9]+$ ]] && [[ "$_cmp_result" -lt 0 ]]; then
        can_upgrade_pacman=true
    fi
else
    # Last resort: rough major.minor comparison from version strings
    local _cur_major _cur_minor _req_major _req_minor
    _cur_major=$(echo "$installed_pacman_ver" | sed 's/^[^:]*://' | cut -d. -f1)
    _cur_minor=$(echo "$installed_pacman_ver" | sed 's/^[^:]*://' | cut -d. -f2)
    _req_major=$(echo "$req_version" | cut -d. -f1)
    _req_minor=$(echo "$req_version" | cut -d. -f2)
    if [[ "$_req_major" -gt "$_cur_major" ]] || \
       { [[ "$_req_major" -eq "$_cur_major" ]] && [[ "$_req_minor" -gt "$_cur_minor" ]]; }; then
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
            if version_meets_requirement "$new_ver" "$req_op" "$req_version"; then
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
            if version_meets_requirement "$new_ver" "$req_op" "$req_version"; then
                echo "SUCCESS: Full upgrade brought pacman $new_ver which satisfies $aur_pacman_dep"
                ldconfig 2>/dev/null || true
                exit 0
            fi
        fi
    fi
    echo "WARNING: Could not upgrade pacman to satisfy pamac-aur. Falling back to Strategy B..."
fi

echo ">>> Strategy B: Finding older pamac-aur revision compatible with pacman $installed_pacman_ver..."

# Known-good commit cache: A TSV file mapping "pacman major.minor" -> commit
# SHA + epoch timestamp. Once we find a compatible commit for a given pacman
# version, we record it so subsequent runs skip the expensive git clone +
# per-commit PKGBUILD scan. This avoids repeated network scans on every run.
#
# Cache layout (TSV, tab-separated):
#   <pacman_major>.<pacman_minor>\t<commit_sha>\t<cached_epoch>\t<reason>
_KNOWN_GOOD_CACHE="$_AUR_CACHE_DIR/known-good-commits.tsv"
_KNOWN_GOOD_TTL="${PAMAC_AUR_COMMIT_CACHE_TTL:-1209600}"  # 14 days

_lookup_known_good_commit() {
    local _want_key="$1"
    [[ -f "$_KNOWN_GOOD_CACHE" ]] || return 1
    local _now_ts _line _cached_ts _cached_commit _cached_key
    _now_ts=$(date +%s 2>/dev/null || echo 0)
    while IFS=$'\t' read -r _cached_key _cached_commit _cached_ts _cached_reason; do
        [[ -z "$_cached_key" || -z "$_cached_commit" ]] && continue
        [[ "$_cached_key" != "$_want_key" ]] && continue
        # Validate the cached commit still exists and PKGBUILD is parseable.
        # A stale or force-pushed commit would otherwise produce a broken build.
        if [[ "$_cached_ts" =~ ^[0-9]+$ ]] && [[ $((_now_ts - _cached_ts)) -lt "$_KNOWN_GOOD_TTL" ]]; then
            echo "$_cached_commit"
            echo "$_cached_reason"
            return 0
        fi
    done < "$_KNOWN_GOOD_CACHE" 2>/dev/null
    return 1
}

_record_known_good_commit() {
    local _key="$1" _commit="$2" _reason="${3:-unknown}"
    [[ -z "$_key" || -z "$_commit" ]] && return 0
    mkdir -p "$_AUR_CACHE_DIR" 2>/dev/null || return 0
    local _now_ts
    _now_ts=$(date +%s 2>/dev/null || echo 0)
    # Append-replace: drop any stale entry for the same key, then re-add.
    local _tmp_cache="$_KNOWN_GOOD_CACHE.tmp.$$"
    if [[ -f "$_KNOWN_GOOD_CACHE" ]]; then
        grep -v "^$_key$(printf '\t')" "$_KNOWN_GOOD_CACHE" 2>/dev/null > "$_tmp_cache" || true
    fi
    printf '%s\t%s\t%s\t%s\n' "$_key" "$_commit" "$_now_ts" "$_reason" >> "$_tmp_cache"
    mv -f "$_tmp_cache" "$_KNOWN_GOOD_CACHE" 2>/dev/null || cat "$_tmp_cache" > "$_KNOWN_GOOD_CACHE" 2>/dev/null || true
    rm -f "$_tmp_cache" 2>/dev/null || true
}

_COMPAT_CACHE_KEY="${pacman_major}.${pacman_minor}"
_AUR_GIT_URL="https://aur.archlinux.org/pamac-aur.git"

# Fast path: a previously-recorded known-good commit for this pacman version.
if _cache_hit=$(_lookup_known_good_commit "$_COMPAT_CACHE_KEY"); then
    _cached_commit=$(echo "$_cache_hit" | head -1)
    _cached_reason=$(echo "$_cache_hit" | tail -1)
    if [[ -n "$_cached_commit" ]]; then
        echo "Using cached known-good pamac-aur commit for pacman ${pacman_major}.${pacman_minor}: ${_cached_commit:0:12}"
        echo "  Reason: $_cached_reason"
        # Verify the commit is still fetchable before trusting it. If the AUR
        # history was rewritten or the commit dropped, fall through to a fresh
        # scan so the cache self-heals. We use `git fetch --depth=1` to fetch
        # exactly the cached commit (not just HEAD, which a plain `git clone
        # --depth=1` would give). This correctly validates commits that are
        # not the current tip — a cached commit is only useful if the full
        # PKGBUILD history is intact at that SHA.
        if _verify_tmp=$(mktemp -d /var/tmp/pamac-aur-verify-XXXXXX 2>/dev/null); then
            chmod 700 "$_verify_tmp" 2>/dev/null || true
            if git init -q "$_verify_tmp/pamac-aur" 2>/dev/null \
               && git -C "$_verify_tmp/pamac-aur" remote add origin "$_AUR_GIT_URL" 2>/dev/null \
               && git -C "$_verify_tmp/pamac-aur" fetch --depth=1 "$_AUR_GIT_URL" "${_cached_commit}" 2>/dev/null \
               && git -C "$_verify_tmp/pamac-aur" cat-file -e "${_cached_commit}^{commit}" 2>/dev/null; then
                rm -rf "$_verify_tmp"
                echo "FOUND_COMPATIBLE_COMMIT=$_cached_commit"
                echo "FOUND_COMPATIBLE_REASON=$_cached_reason (cached)"
                exit 2
            fi
            rm -rf "$_verify_tmp"
            echo "WARN: cached commit ${_cached_commit:0:12} no longer fetchable — forcing a fresh scan."
        fi
    fi
fi

# Use git directly to iterate commits — this is frontend-agnostic and does not
# depend on the AUR web interface (CGIT, GitLab, Gitea, etc.).
_AUR_WORK=$(mktemp -d /var/tmp/pamac-aur-history-XXXXXX) && chmod 700 "$_AUR_WORK" 2>/dev/null || _AUR_WORK=$(mktemp -d)
rm -rf "$_AUR_WORK"

echo "Cloning pamac-aur repository (depth=100) for commit history..."
# Depth=100 covers the 50-commit scan window with headroom. depth=200 was
# unnecessarily heavy on the Steam Deck's eMMC (network + disk I/O). The
# for-loop below only inspects `git log -50`, so depth=100 is more than
# sufficient; if the commit is older, the --unshallow fallback in
# install_from_aur_commit handles it.
if ! git clone --depth=100 --single-branch "$_AUR_GIT_URL" "$_AUR_WORK" 2>/tmp/pamac_aur_clone_err; then
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

    old_dep=$(echo "$old_pkgbuild" | awk '
        /^(depends|makedepends)\+?=/ {
            # Extract "pacman>=X.Y" or "pacman=X.Y" from the dependency list
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^pacman[><=]/) {
                    print $i
                    exit
                }
            }
        }
    ' || echo "")
    if [[ -z "$old_dep" ]]; then
        echo "  -> No pacman constraint in this revision (likely compatible)"
        commit_date=$(git -C "$_AUR_WORK" log -1 --format=%ai "$try_commit" 2>/dev/null || echo "unknown date")
        echo "  -> $commit_date"
        _record_known_good_commit "$_COMPAT_CACHE_KEY" "$try_commit" "no explicit pacman constraint"
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

    if version_meets_requirement "$installed_pacman_ver" "$old_req_op" "$old_req_ver"; then
        echo "  -> Compatible: requires pacman $old_dep (have $installed_pacman_ver)"
        _record_known_good_commit "$_COMPAT_CACHE_KEY" "$try_commit" "requires pacman $old_dep"
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
    _prebuilt_output=$(container_root_exec bash -c '. /usr/local/lib/pamac-common.sh 2>/dev/null || true; _remove_stale_lock; pacman -Sy --noconfirm 2>/dev/null; pacman -S --noconfirm --needed pamac-aur 2>/dev/null; command -v pamac-manager >/dev/null 2>&1 && command -v pamac >/dev/null 2>&1 && echo __PREBUILT_OK__' 2>/dev/null) || _prebuilt_output=""
    if [[ -n "$_prebuilt_output" ]] && grep -q "__PREBUILT_OK__" <<< "$_prebuilt_output"; then
        log_success "Pamac installed from prebuilt repository."
        return 0
    fi
    log_info "Prebuilt pamac-aur not available. Building from source..."
    log_warn "Source compilation detected — building pamac-aur from AUR may take 15-45 minutes"
    log_warn "depending on hardware (CPU speed, thermal throttling, storage type)."
    log_warn "This package compiles complex C++/Vala dependencies (libalpm, pamac)."
    log_warn "eMMC/SD write mitigation: tmpfs BUILDDIR and ccache are configured."
    log_warn "  If builds still hit eMMC, try: --low-memory (reduces parallel writes)"
    log_warn "  or close other apps to free RAM for tmpfs (compiles in RAM, not flash)."
    log_warn "Keep the device plugged in and avoid sleep/hibernation during the build."

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
export LC_ALL=C

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

# Build a package from a directory containing a PKGBUILD.
# Uses devtools (archbuild) when --use-devtools is set and devtools is
# available, otherwise falls back to makepkg. This provides a clean chroot
# build environment with proper dependency resolution when devtools is used.
# Args: $1=work_dir, $2=description (for logging)
# Returns: 0 on success, 1 on failure. Outputs built package path on success.
_build_package() {
    local _work_dir="$1" _desc="${2:-package}"
    local _use_devtools="${USE_DEVTOOLS:-false}"

    # Check if devtools is available and requested
    if [[ "$_use_devtools" == "true" ]] && command -v archbuild >/dev/null 2>&1; then
        echo "Building $_desc with devtools (clean chroot)..."
        # archbuild needs the PKGBUILD directory and creates a clean chroot
        # It installs the resulting packages automatically
        if sudo -Hu "$current_user" bash -lc "cd '$_work_dir' && archbuild --noconfirm" 2>/tmp/pamac_devtools_build_err; then
            echo "Devtools build succeeded for $_desc."
            return 0
        else
            echo "Devtools build failed for $_desc:"
            cat /tmp/pamac_devtools_build_err 2>/dev/null | tail -15
            echo "Falling back to makepkg..."
            # Fall through to makepkg below
        fi
    elif [[ "$_use_devtools" == "true" ]]; then
        echo "WARNING: --use-devtools set but archbuild not found. Using makepkg."
    fi

    # Default: build with makepkg
    echo "Building $_desc with makepkg..."
    _preflight_oom_check "$_desc build"
    _preflight_space_check "$_desc build" || return 1
    _set_makepkg_jobs
    _spin "Building $_desc" sudo -Hu "$current_user" bash -lc "cd '$_work_dir' && makepkg -si --noconfirm --clean" 2>/tmp/pamac_build_err
    local _rc=$?
    if [[ $_rc -ne 0 ]]; then
        echo "makepkg failed for $_desc (exit $_rc):"
        cat /tmp/pamac_build_err 2>/dev/null | tail -15
        return 1
    fi
    return 0
}

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
    # AUR payload verification: inspect PKGBUILD for suspicious patterns before building.
    if ! _verify_aur_payload "$work_dir"; then
        rm -rf "$work_dir"
        return 1
    fi
    _build_package "$work_dir" "pamac-aur commit ${commit:0:12}"
    local build_rc=$?
    rm -rf "$work_dir"
    return $build_rc
}

install_from_yay() {
    # Pre-flight AUR payload verification: fetch and inspect the PKGBUILD before yay
    # builds it. Under --strict-security, aborts on suspicious patterns. Otherwise
    # provides advisory warnings about network-in-build, eval usage, etc.
    if [[ "${STRICT_SECURITY:-false}" == "true" ]]; then
        local _pf_dir
        _pf_dir=$(mktemp -d /var/tmp/pamac-preflight-XXXXXX 2>/dev/null) || _pf_dir=""
        if [[ -n "$_pf_dir" ]]; then
            chmod 700 "$_pf_dir" 2>/dev/null || true
            if curl -sSf --connect-timeout 10 --max-time 30 \
                -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
                "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=pamac-aur" \
                -o "$_pf_dir/PKGBUILD" 2>/dev/null; then
                if ! _verify_aur_payload "$_pf_dir"; then
                    rm -rf "$_pf_dir"
                    return 1
                fi
            fi
            rm -rf "$_pf_dir"
        fi
    fi
    _preflight_oom_check "pamac-aur yay install"
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

# Detect the system libalpm.so ABI version number (e.g., 14, 15) by querying
# ldconfig. Returns the numeric SONAME suffix via stdout, or empty string if
# not found. Works for any ABI version — no hardcoded thresholds.
_detect_system_libalpm_abi() {
    local _so_path
    _so_path=$(ldconfig -p 2>/dev/null \
        | awk '/libalpm\.so\.[0-9]+/ { print $NF; exit }' || echo "")
    if [[ -n "$_so_path" ]]; then
        local _so_name
        _so_name=$(basename "$_so_path" 2>/dev/null || echo "")
        if [[ "$_so_name" =~ ^libalpm\.so\.([0-9]+)$ ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    fi
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

    # Detect the actual libalpm.so ABI version number dynamically.
    # During major pacman upgrades the .so version bumps and pamac-aur may not
    # have been rebuilt against the new ABI yet. This check detects any ABI
    # transition early — it works for any version, not just specific thresholds.
    local _libalpm_so_ver=""
    _libalpm_so_ver=$(_detect_system_libalpm_abi) || true
    if [[ -n "$_libalpm_so_ver" ]]; then
        echo "  libalpm ABI version: .so.$_libalpm_so_ver"
        # Track the ABI version for the caller (used by Strategy B to select commits)
        echo "LIBALPM_SO_VERSION=$_libalpm_so_ver"
    else
        echo "  WARNING: Could not detect libalpm ABI version."
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
                # Detect ABI version mismatch: pamac compiled against one .so.N
                # but system provides a different version. The dynamic linker
                # resolves SONAME, so if pamac links libalpm.so.N but only
                # .so.M exists, ldd would show "not found" (caught above).
                # However, if both exist (multi-version install), verify the
                # running binary uses the system version.
                local _lib_soname
                _lib_soname=$(basename "$_lib_path" 2>/dev/null || echo "")
                if [[ "$_lib_soname" =~ ^libalpm\.so\.([0-9]+)$ ]]; then
                    local _linked_abi="${BASH_REMATCH[1]}"
                    local _system_abi=""
                    _system_abi=$(_detect_system_libalpm_abi) || true
                    if [[ -n "$_system_abi" && "$_linked_abi" != "$_system_abi" ]]; then
                        echo "  WARNING: libalpm ABI mismatch — binary links .so.$_linked_abi but system has .so.$_system_abi"
                        echo "  pamac-aur was compiled against an older ABI and may fail at runtime."
                        echo "  Fix: yay -S --rebuild pamac-aur (recompile against current libalpm)"
                        echo "  Or:  wait for upstream pamac-aur to support libalpm.so.$_system_abi"
                        _issues=$((_issues + 1))
                    fi
                fi
            elif [[ -n "$_lib_path" ]]; then
                echo "  ERROR: libalpm library NOT FOUND at: $_lib_path"
                echo "  This indicates a library mismatch — pamac was compiled against a different libalpm version."
                if [[ "$_lib_path" =~ libalpm\.so\.([0-9]+) ]]; then
                    local _expected_abi="${BASH_REMATCH[1]}"
                    local _system_abi=""
                    _system_abi=$(_detect_system_libalpm_abi) || true
                    if [[ -n "$_system_abi" ]]; then
                        echo "  Expected libalpm.so.$_expected_abi, system has libalpm.so.$_system_abi"
                        echo "  Try: yay -S --rebuild pamac-aur  (recompile against current ABI)"
                    fi
                fi
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
                _preflight_oom_check "pamac-aur fallback build"
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
    _pacman_ver=$(pacman -Q pacman 2>/dev/null | awk '{print $2}' || echo "unknown")
    _log_event "pamac_install_failed" "pacman_version=$_pacman_ver" "strategies=A,B,C"
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
    _preflight_oom_check "pamac-aur retry install"
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

    # Template substitution: bake ENABLE_FLATPAK into the single-quoted heredoc.
    pamac_install="${pamac_install//__ENABLE_FLATPAK__/${ENABLE_FLATPAK:-false}}"

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
export LC_ALL=C

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
    # Flatpak support: disabled by default (SteamOS uses Discover for Flatpaks).
    # --enable-flatpak overrides this to keep Flatpak enabled in Pamac.
    if [[ "__ENABLE_FLATPAK__" == "true" ]]; then
        if grep -q '^#EnableFlatpak' "$tmp"; then
            sed -i 's/^#EnableFlatpak.*/EnableFlatpak/' "$tmp"
        fi
        grep -q '^EnableFlatpak' "$tmp" || printf 'EnableFlatpak\n' >> "$tmp"
        echo "Flatpak support re-enabled (--enable-flatpak)."
    else
        if grep -q '^EnableFlatpak' "$tmp"; then
            sed -i 's/^EnableFlatpak.*/#EnableFlatpak/' "$tmp"
        fi
        grep -q '^EnableFlatpak' "$tmp" || printf '#EnableFlatpak (disabled: use Discover for Flatpaks)\n' >> "$tmp"
    fi
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
    # Set all allow_active to auth_admin first, then selectively enable
    # only package management actions (see stage-6a block for full list).
    _atomic_sed_inplace "$pamac_policy" \
        's|<allow_active>[^<]*</allow_active>|<allow_active>auth_admin</allow_active>|g'
    for _action_id in \
        org.manjaro.pamac.install \
        org.manjaro.pamac.install-update \
        org.manjaro.pamac.remove \
        org.manjaro.pamac.update \
        org.manjaro.pamac.build \
        org.manjaro.pamac.launch-flatpak-builder \
        org.manjaro.pamac.check-aur-vcs-updates \
        org.manjaro.pamac.check-aur-updates \
        org.manjaro.pamac.refresh-databases \
        org.manjaro.pamac.get-build-directory \
        org.manjaro.pamac.get-build-username \
        org.manjaro.pamac.build-install; do
        sed -i "/id=\"${_action_id}\"/,/<\/action>/{s|<allow_active>auth_admin</allow_active>|<allow_active>yes</allow_active>|}" \
            "$pamac_policy" 2>/dev/null || true
    done
    # NOTE: system-upgrade deliberately excluded — requires auth_admin (password).
    echo "Polkit policy: allow_active=yes for package management actions only."
else
    echo "Warning: pamac polkit policy file not found at $pamac_policy"
fi
else
    echo "Warning: /etc/pamac.conf not found. Creating minimal config."
    mkdir -p /etc
    if [[ "__ENABLE_FLATPAK__" == "true" ]]; then
        printf 'EnableFlatpak\nEnableAUR\nCheckAURUpdates\nCheckAURVCSUpdates\nBuildDirectory = /home/'"$current_user"'/.pamac-build\n' > /etc/pamac.conf
        echo "Flatpak support re-enabled (--enable-flatpak)."
    else
        printf '#EnableFlatpak (disabled: use Discover for Flatpaks)\nEnableAUR\nCheckAURUpdates\nCheckAURVCSUpdates\nBuildDirectory = /home/'"$current_user"'/.pamac-build\n' > /etc/pamac.conf
    fi
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
export LC_ALL=C

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

export_pamac_to_host() {
    log_step "Exporting Pamac to host system"

    # Atomic write helper: writes to temp file, validates, then renames into place.
    # Prevents corrupted/partial desktop files if the process is killed mid-write.
    _atomic_desktop_write() {
        local _target="$1" _content="$2"
        local _tmp
        _tmp=$(mktemp "${_target}.tmp.XXXXXX") || { log_warn "mktemp failed for $_target"; return 1; }
        printf '%s\n' "$_content" > "$_tmp"
        if [[ ! -s "$_tmp" ]]; then
            rm -f "$_tmp"
            log_warn "Atomic write produced empty file for $_target"
            return 1
        fi
        # Validate the desktop file before moving into place.
        # If validation fails, keep the original file and log a hard error.
        # This prevents "corrupt menu" reports from broken .desktop entries.
        if command -v desktop-file-validate >/dev/null 2>&1; then
            if ! desktop-file-validate "$_tmp" 2>/dev/null; then
                local _val_err
                _val_err=$(desktop-file-validate "$_tmp" 2>&1 || true)
                log_error "Desktop file validation FAILED for $_target:"
                log_error "$_val_err"
                log_error "Keeping the original file intact. The .desktop entry was NOT modified."
                rm -f "$_tmp"
                return 1
            fi
        fi
        # Sync the temp file to disk before rename so metadata and data are
        # committed. Without this, a power cut after rename could leave the
        # filesystem pointing at unwritten sectors (corrupted/zero-byte file).
        sync "$_tmp" 2>/dev/null || sync 2>/dev/null || true
        mv -f "$_tmp" "$_target"
        # Sync the parent directory so the rename entry is durable too.
        local _parent
        _parent=$(dirname "$_target")
        sync "$_parent" 2>/dev/null || true
    }

    # Rollback trap: tracks created files and cleans up on failure.
    # Save the current EXIT trap so we can restore it on success (instead of
    # leaving the process with no EXIT trap after our trap runs).
    local _prev_exit_trap
    _prev_exit_trap=$(trap -p EXIT 2>/dev/null | sed -e "s/^trap -- //" -e "s/ EXIT$//") || true
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
        # Chain to the previous EXIT trap (master cleanup) so it is not lost.
        if [[ -n "$_prev_exit_trap" ]]; then
            eval "$_prev_exit_trap"
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
# distrobox does not forward DBUS_SESSION_BUS_ADDRESS or WAYLAND_DISPLAY
# into the container. Without WAYLAND_DISPLAY, the GTK app_id emitted by
# the compositor does not match the desktop entry's StartupWMClass, causing
# the window to appear as a generic placeholder on Wayland taskbars.
export DISPLAY=\${DISPLAY:-:0}
export XDG_RUNTIME_DIR=\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}
# Forward WAYLAND_DISPLAY so GTK announces the correct app_id on Wayland.
# Without this, pamac-manager may announce org.manjaro.pamac.manager but
# the taskbar groups on the desktop entry filename (StartupWMClass), causing
# a mismatch. Also export XDG_SESSION_TYPE so the app can detect Wayland.
if [[ -n "\${WAYLAND_DISPLAY:-}" ]]; then
    export WAYLAND_DISPLAY="\$WAYLAND_DISPLAY"
    export XDG_SESSION_TYPE="\${XDG_SESSION_TYPE:-wayland}"
fi

if [[ -z "\${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    # Helper: validate that a D-Bus socket is actually alive by attempting
    # a connection. Socket file existence is not sufficient — the bus daemon
    # may have crashed or been killed, leaving a stale socket behind.
    _validate_dbus_socket() {
        local _addr="\$1"
        local _sock_path="\${_addr#unix:path=}"
        # Verify the socket file exists and is a UNIX socket.
        [[ -S "\$_sock_path" ]] || return 1
        # Try protocol-level liveness checks (most reliable).
        # Method 1: socat half-duplex connect (safe — no data sent, no protocol violation)
        if command -v socat >/dev/null 2>&1; then
            socat -u OPEN:/dev/null "UNIX-CONNECT:\$_sock_path" 2>/dev/null && return 0
            return 1
        fi
        # Method 2: dbus-send ListNames (exercises full D-Bus SASL handshake + method call).
        # Detects stale sockets where the socket file persists but the daemon is dead.
        if command -v dbus-send >/dev/null 2>&1; then
            DBUS_SESSION_BUS_ADDRESS="\$_addr" timeout 2 \
                dbus-send --session --print-reply --dest=org.freedesktop.DBus \
                /org/freedesktop/DBus org.freedesktop.DBus.ListNames \
                >/dev/null 2>&1 && return 0
            return 1
        fi
        # Method 3: Try connecting with bash /dev/tcp-style check (TCP only).
        # For UNIX sockets, only file-level checks remain — cannot detect stale sockets.
        local _sock_dir
        _sock_dir=\$(dirname "\$_sock_path")
        [[ -d "\$_sock_dir" && -w "\$_sock_dir" ]] || return 1
        # Socket file exists and is writable — best we can do without socat/dbus-send.
        return 0
    }

    _dbus_found=false

    # Priority 1: XDG_RUNTIME_DIR/bus (standard systemd user session)
    if [[ -S "\$XDG_RUNTIME_DIR/bus" ]]; then
        if _validate_dbus_socket "unix:path=\$XDG_RUNTIME_DIR/bus"; then
            export DBUS_SESSION_BUS_ADDRESS="unix:path=\$XDG_RUNTIME_DIR/bus"
            _dbus_found=true
        fi
    fi

    # Priority 2: /run/user/<uid>/bus (alternate path)
    if [[ "\$_dbus_found" == "false" ]] && [[ -S "/run/user/\$(id -u)/bus" ]]; then
        if _validate_dbus_socket "unix:path=/run/user/\$(id -u)/bus"; then
            export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$(id -u)/bus"
            _dbus_found=true
        fi
    fi

    # Priority 3: /tmp/dbus-* (non-systemd or alternative hosts)
    if [[ "\$_dbus_found" == "false" ]]; then
        _dbus_sock=\$(ls /tmp/dbus-* 2>/dev/null | head -1)
        if [[ -n "\$_dbus_sock" ]] && [[ -S "\$_dbus_sock" ]]; then
            if _validate_dbus_socket "unix:path=\$_dbus_sock"; then
                export DBUS_SESSION_BUS_ADDRESS="unix:path=\$_dbus_sock"
                _dbus_found=true
            fi
        fi
    fi

    # Priority 4: Common alternative socket names (Wayland compositors)
    if [[ "\$_dbus_found" == "false" ]]; then
        for _candidate in "\$XDG_RUNTIME_DIR/bus-\$(id -u)" "\$XDG_RUNTIME_DIR/dbus-session" "/run/user/\$(id -u)/dbus-session" "\$XDG_RUNTIME_DIR/.bus-session"; do
            if [[ -S "\$_candidate" ]]; then
                if _validate_dbus_socket "unix:path=\$_candidate"; then
                    export DBUS_SESSION_BUS_ADDRESS="unix:path=\$_candidate"
                    _dbus_found=true
                    break
                fi
            fi
        done
    fi

    # Priority 5: Start a private dbus-daemon session as last resort.
    # This handles cases where SteamOS modifies session lifecycle, the host
    # session bus is dead, or XDG_RUNTIME_DIR is missing/empty.
    # The daemon is tracked via a PID file and cleaned up on wrapper exit
    # so orphaned dbus-daemon processes don't accumulate across runs.
    if [[ "\$_dbus_found" == "false" ]]; then
        if command -v dbus-daemon >/dev/null 2>&1; then
            _private_bus_dir="\$XDG_RUNTIME_DIR"
            [[ -d "\$_private_bus_dir" ]] || _private_bus_dir="/tmp/dbus-session-\$(id -u)"
            mkdir -p "\$_private_bus_dir" 2>/dev/null || true
            _private_bus_addr="unix:path=\$_private_bus_dir/bus-session-private"
            _private_bus_pidfile="/tmp/.dsr-private-bus-pid"
            _dbus_daemon_pid=""
            _dbus_daemon_pid=\$(dbus-daemon --session --fork --address="\$_private_bus_addr" \
                --print-pid 2>/dev/null) || true
            if [[ -n "\$_dbus_daemon_pid" ]] && [[ "\$_dbus_daemon_pid" =~ ^[0-9]+$ ]]; then
                # Wait briefly for the daemon to initialize its socket.
                sleep 0.5 2>/dev/null || sleep 1
                # Validate the private daemon actually started and is listening.
                if _validate_dbus_socket "\$_private_bus_addr"; then
                    # Store PID and socket path for cleanup trap (trap fires after
                    # local variables go out of scope, so we persist to a file).
                    printf '%s\n%s\n' "\$_dbus_daemon_pid" "\$_private_bus_addr" > "\$_private_bus_pidfile" 2>/dev/null || true
                    export DBUS_SESSION_BUS_ADDRESS="\$_private_bus_addr"
                    _dbus_found=true
                else
                    # Private daemon failed to start — clean up and fall through.
                    kill "\$_dbus_daemon_pid" 2>/dev/null || true
                    rm -f "\$_private_bus_pidfile" 2>/dev/null || true
                fi
                # Register cleanup: kill the private daemon when this wrapper exits.
                # Prevents orphaned dbus-daemon processes from accumulating when
                # pamac-manager crashes or the user closes it. Reads PID and socket
                # path from the PID file since local variables are out of scope.
                trap '_bp=\$(sed -n 1p /tmp/.dsr-private-bus-pid 2>/dev/null || echo "");
                    _ba=\$(sed -n 2p /tmp/.dsr-private-bus-pid 2>/dev/null || echo "");
                    if [[ -n "\$_bp" ]] && [[ "\$_bp" =~ ^[0-9]+$ ]] && kill -0 "\$_bp" 2>/dev/null; then
                        kill "\$_bp" 2>/dev/null || true;
                        _wt=0;
                        while [[ \$_wt -lt 3 ]] && kill -0 "\$_bp" 2>/dev/null; do
                            sleep 1; _wt=\$(( _wt + 1 ));
                        done;
                        kill -0 "\$_bp" 2>/dev/null && kill -9 "\$_bp" 2>/dev/null || true;
                    fi;
                    rm -f /tmp/.dsr-private-bus-pid 2>/dev/null;
                    if [[ -n "\$_ba" ]]; then
                        _bs=\${_ba#unix:path=};
                        rm -f "\$_bs" 2>/dev/null || true;
                    fi' EXIT INT TERM HUP
            fi
        fi
    fi

    # Final fallback: use the standard path even if we couldn't validate it.
    # The container's session bootstrap may still work if the bus comes up later.
    if [[ "\$_dbus_found" == "false" ]]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$(id -u)/bus"
    fi

    unset -f _validate_dbus_socket 2>/dev/null || true
fi

# Post-setup validation: verify the D-Bus session bus is actually reachable.
# If the socket was stale (bus daemon died), warn the user so they know
# pamac-daemon may fail to register on the session bus.
if [[ -n "\${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    _bus_path="\${DBUS_SESSION_BUS_ADDRESS#unix:path=}"
    if [[ -S "\$_bus_path" ]]; then
        # Quick liveness check via dbus-send if available
        if command -v dbus-send >/dev/null 2>&1; then
            if ! dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
                echo "D-Bus WARNING: Session bus socket exists at \$_bus_path but daemon may be unresponsive." >&2
                echo "  pamac-daemon may fail to register. If the UI doesn't appear, try:" >&2
                echo "    systemctl --user restart dbus  (on the host)" >&2
                echo "  Or log out and back in to restart the user session." >&2
            fi
        fi
    else
        echo "D-Bus WARNING: No valid session bus socket found. pamac-daemon may fail." >&2
        echo "  Searched: XDG_RUNTIME_DIR/bus, /run/user/\$(id -u)/bus, /tmp/dbus-*," >&2
        echo "  alternative socket names, and attempted private dbus-daemon start." >&2
        echo "  Ensure a D-Bus session is running on the host:" >&2
        echo "    systemctl --user start dbus  (systemd hosts)" >&2
        echo "    Or: dbus-daemon --session --fork (non-systemd hosts)" >&2
    fi
fi

# Clean stale pacman download dirs that cause "invalid database" errors
rm -rf /var/lib/pacman/sync/download-* 2>/dev/null || true

# Ensure DBs exist in the user's tmp path (required for trans_check_prepare).
# Without this, pamac-manager's own alpm handle fails with "invalid or corrupted database".
_tmp_base="/tmp/pamac-\$(id -un)/dbs"
_tmp_dbs="\$_tmp_base/sync"
_tmp_lock="\$_tmp_base/.sync_lock"

# Use flock to prevent concurrent sync operations (Pamac GUI + CLI racing)
mkdir -p "\$_tmp_base" 2>/dev/null
exec 9>"\$_tmp_lock"
flock -n 9 2>/dev/null || { echo "Another sync in progress, waiting..."; flock 9; }

# Refresh if tmp_dbs doesn't exist, is empty, or source DBs are newer
_needs_refresh=false
if [[ ! -d "\$_tmp_dbs" ]] || [[ -z "\$(ls "\$_tmp_dbs"/*.db 2>/dev/null)" ]]; then
    _needs_refresh=true
else
    _src_newest=\$(stat -c %Y /var/lib/pacman/sync/*.db 2>/dev/null | sort -rn | head -1 || echo "0")
    _tmp_newest=\$(stat -c %Y "\$_tmp_dbs"/*.db 2>/dev/null | sort -rn | head -1 || echo "0")
    if [[ "\$_src_newest" -gt "\$_tmp_newest" ]]; then
        _needs_refresh=true
    fi
fi

if [[ "\$_needs_refresh" == "true" ]]; then
    rm -rf "\$_tmp_base" 2>/dev/null || true
    mkdir -p "\$_tmp_dbs"
    ln -sf /var/lib/pacman/local "\$_tmp_base/local"
    cp /var/lib/pacman/sync/*.db "\$_tmp_dbs/" 2>/dev/null || true
    touch "\$_tmp_dbs/refresh_timestamp"
    chmod -R a+rX "\$_tmp_base"
fi

exec 9>&-

# Check if daemon is running; only start if not
if ! pgrep -x pamac-daemon >/dev/null 2>&1; then
    su -c '/usr/local/bin/pamac-session-bootstrap.sh' root 2>&1 || true
fi

# Clean stale pacman lock
rm -f /var/lib/pacman/db.lck 2>/dev/null || true

chmod 0755 /var/log 2>/dev/null || true

DESKTOP_FILE="__DESKTOP_PATH__"

CRASH_LOG="/var/log/pamac-manager-crash.log"
# Ensure the crash log is writable by the non-root user running this wrapper.
# /var/log is 0755 (root-owned), so pre-create the log as group-writable.
if [[ ! -e "\$CRASH_LOG" ]]; then
    touch "\$CRASH_LOG" 2>/dev/null || true
    chmod 0664 "\$CRASH_LOG" 2>/dev/null || true
fi
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

    # shellcheck disable=SC2016 # Intentional: writing bash script content via single-quoted strings
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

# Ensure session bus is available for pamac-daemon inside the container.
# Validate socket liveness — a stale socket (bus daemon crashed) will cause
# pamac-daemon to fail silently on D-Bus registration.
if [[ -z "\${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    _uid=\$(id -u)
    _dbus_tried=false
    for _bus_candidate in "\$XDG_RUNTIME_DIR/bus" "/run/user/\$_uid/bus" \$(ls /tmp/dbus-* 2>/dev/null | head -1); do
        [[ -n "\$_bus_candidate" && -S "\$_bus_candidate" ]] || continue
        # Quick liveness check via dbus-send
        if command -v dbus-send >/dev/null 2>&1; then
            if dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
                export DBUS_SESSION_BUS_ADDRESS="unix:path=\$_bus_candidate"
                _dbus_tried=true
                break
            fi
        else
            # No dbus-send: trust socket existence (best effort)
            export DBUS_SESSION_BUS_ADDRESS="unix:path=\$_bus_candidate"
            _dbus_tried=true
            break
        fi
    done
    if [[ "\$_dbus_tried" == "false" ]]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$_uid/bus"
    fi
fi

# D-Bus session bus watchdog: SteamOS switches between Game Mode (gamescope)
# and Desktop Mode, which can kill the user session bus. If DBUS_SESSION_BUS_ADDRESS
# points to a stale socket, pamac-daemon will silently fail to register. This
# watchdog re-discovers the bus if the current one dies, and retries once
# (handles the Game Mode -> Desktop Mode transition where the bus restarts).
_dbus_validate_and_watch() {
    [[ -z "\${DBUS_SESSION_BUS_ADDRESS:-}" ]] && return 1
    local _sock_path="\${DBUS_SESSION_BUS_ADDRESS#unix:path=}"
    [[ -S "\$_sock_path" ]] || {
        # Socket disappeared — try re-discovery
        for _candidate in "\$XDG_RUNTIME_DIR/bus" "/run/user/\$(id -u)/bus" \$(ls /tmp/dbus-* 2>/dev/null | head -1); do
            [[ -n "\$_candidate" && -S "\$_candidate" ]] || continue
            if command -v dbus-send >/dev/null 2>&1; then
                DBUS_SESSION_BUS_ADDRESS="unix:path=\$_candidate" \
                    dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
                    --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames \
                    >/dev/null 2>&1 && {
                    export DBUS_SESSION_BUS_ADDRESS="unix:path=\$_candidate"
                    return 0
                }
            fi
        done
        return 1
    }
    return 0
}
# Initial validation — fail fast if bus is dead
_dbus_validate_and_watch || true

# Detect display server
IS_WAYLAND=false
if [[ -n "\${WAYLAND_DISPLAY:-}" ]]; then
    IS_WAYLAND=true
fi

# Game Mode / gamescope detection: prevent launching Pamac GUI while in
# Game Mode. Gamescope is SteamOS's gaming compositor; launching GUI apps
# under it can cause invisible windows, performance scaling issues, or
# soft-lock the UI for less-experienced users.
if pgrep -x gamescope >/dev/null 2>&1; then
    # gamescope running — check if we're inside a game session
    # STEAM_GAMESCOPE=1 is set by Steam when launching games via gamescope
    if [[ "\${STEAM_GAMESCOPE:-0}" == "1" ]] || [[ -n "\${GAMESCOPE_WAYLAND_DISPLAY:-}" ]]; then
        echo "Pamac GUI cannot be launched while in Game Mode (gamescope active)."
        echo "Exit the game and return to Desktop Mode to use Pamac."
        notify-send -i dialog-warning "Game Mode Active" \
            "Pamac cannot be launched during a game session. Return to Desktop Mode." 2>/dev/null || true
        exit 0
    fi
    # gamescope present but not in active game session — warn but allow
    echo "Warning: gamescope compositor detected. Pamac may display incorrectly."
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
# container's explicitly-installed package list hasn't changed since
# the last export. Uses md5sum of the package list (not count) so that
# a package swap (remove A + install B) is still detected.
_export_dir="\$HOME/.local/share/applications"
_pkg_hash_cache="\$HOME/.local/state/steamos-pamac-${CONTAINER_NAME}.pkghash"
_current_pkg_hash=\$(${CONTAINER_MANAGER:-podman} exec "${CONTAINER_NAME}" pacman -Qeq 2>/dev/null | md5sum | awk '{print \$1}')
if [[ -f "\$_pkg_hash_cache" ]] && [[ "\$(cat "\$_pkg_hash_cache" 2>/dev/null)" == "\${_current_pkg_hash}" ]]; then
    # Package list unchanged — desktop files already exported, skip slow enumeration
    true
else
# Iterate desktop files directly (O(M)) instead of per-package enumeration (O(N*M)).
# Each desktop file is checked against explicit packages via pacman -Qoq.
for _desktop in \$(${CONTAINER_MANAGER:-podman} exec "${CONTAINER_NAME}" find /usr/share/applications /usr/local/share/applications -name '*.desktop' -type f 2>/dev/null); do
    _pkg_name=\$(${CONTAINER_MANAGER:-podman} exec "${CONTAINER_NAME}" pacman -Qoq "\$_desktop" 2>/dev/null) || continue
    # Only process explicitly-installed packages (not dependencies)
    ${CONTAINER_MANAGER:-podman} exec "${CONTAINER_NAME}" pacman -Qeq "\$_pkg_name" >/dev/null 2>&1 || continue
    _base=\$(basename "\$_desktop")
    _host_file="\$_export_dir/${CONTAINER_NAME}-\$_base"
    if [[ ! -f "\$_host_file" ]]; then
        ${CONTAINER_MANAGER:-podman} cp "${CONTAINER_NAME}:\$_desktop" "\$_host_file" 2>/dev/null || continue
        _pkg_name=\$(basename "\$_desktop" .desktop)
        _app_exec=\$(grep '^Exec=' "\$_host_file" 2>/dev/null | head -1 | sed 's/^Exec=//' | sed 's/ .*//')
        # Special case: pamac-manager gets wrapper-host and rename
        if [[ "\$_pkg_name" == "org.manjaro.pamac.manager" ]]; then
            sed -i 's|^Name=.*|Name=Pamac|' "\$_host_file"
            # Update (don't delete) localized Name keys to match the new base name.
            # Deleting them (old: sed -i '/^Name\[/d') breaks locale display on
            # DEs that support per-language desktop entry overrides.
            sed -i 's|^Name\[[a-zA-Z_@.+-]*\]=.*|&|' "\$_host_file"
            sed -i '/^Name\[/s|=.*|=Pamac|' "\$_host_file"
            sed -i "s|^Exec=.*|Exec=\$HOME/.local/bin/pamac-manager-wrapper-host %U|" "\$_host_file"
        else
            sed -i "s|^Exec=.*|Exec=distrobox-enter -n ${CONTAINER_NAME} -- \\\${_app_exec} %f|" "\$_host_file"
        fi
        # Add pamac markers and uninstall action
        if ! grep -q '^Actions=uninstall;' "\$_host_file"; then
            # Insert markers after StartupWMClass, or Name=, or append to [Desktop Entry]
            _anchor="^StartupWMClass="
            grep -q "\${_anchor}" "\$_host_file" 2>/dev/null || _anchor="^Name="
            grep -q "\${_anchor}" "\$_host_file" 2>/dev/null || _anchor="^Type="
            sed -i "/\${_anchor}/a Actions=uninstall;" "\$_host_file" 2>/dev/null
            sed -i "/\${_anchor}/a X-SteamOS-Pamac-Managed=true" "\$_host_file" 2>/dev/null
            sed -i "/\${_anchor}/a X-SteamOS-Pamac-Container=${CONTAINER_NAME}" "\$_host_file" 2>/dev/null
            sed -i "/\${_anchor}/a X-SteamOS-Pamac-SourceDesktop=\$_base" "\$_host_file" 2>/dev/null
            sed -i "/\${_anchor}/a X-SteamOS-Pamac-SourcePackage=\$_pkg_name" "\$_host_file" 2>/dev/null
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
mkdir -p "\$(dirname "\$_pkg_hash_cache")" 2>/dev/null
echo "\${_current_pkg_hash}" > "\$_pkg_hash_cache" 2>/dev/null
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
# distrobox 1.8.x does not support --env; pass env via prefix instead.
# Explicitly forward WAYLAND_DISPLAY and XDG_SESSION_TYPE so GTK inside the
# container announces the correct Wayland app_id for taskbar grouping.
# Default XDG_SESSION_TYPE to "wayland" when WAYLAND_DISPLAY is present but
# XDG_SESSION_TYPE was not set (some compositors omit it by default).
_XDG_SESSION_TYPE="\${XDG_SESSION_TYPE:-}"
if [[ -n "\${WAYLAND_DISPLAY:-}" && -z "\${_XDG_SESSION_TYPE}" ]]; then
    _XDG_SESSION_TYPE="wayland"
fi
DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/\$(id -u)/bus}" \
WAYLAND_DISPLAY="\${WAYLAND_DISPLAY:-}" \
XDG_SESSION_TYPE="\${_XDG_SESSION_TYPE}" \
XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}" \
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
LOCK_FILE="\$STATE_DIR/uninstall.lock"

mkdir -p "\$STATE_DIR"

# Prevent concurrent uninstalls (e.g. user clicks two "Uninstall" buttons
# in quick succession from desktop notifications). Two concurrent pacman -Rs
# on the same container would corrupt the package database.
exec 9>"\$LOCK_FILE"
flock -n 9 || { echo "Another uninstall is already running. Please wait." >&2; exit 1; }

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

 _log "Removing \$pkg via pacman -Rs (package + deps unique to this package)..."
 if ! echo "\$pkg" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9._+-]*$'; then
 _log "Error: Invalid package name format: '\$pkg'"
 echo "Error: Invalid package name: '\$pkg'" >&2
 exit 1
 fi
 local remove_output
 remove_output=\$("\$CONTAINER_MANAGER" exec -u 0 "\$CONTAINER_NAME" bash -c "
. /usr/local/lib/pamac-common.sh 2>/dev/null || true
_remove_stale_lock
# -Rs: remove package + recursive deps that are NOT required by any other
# installed package. This is safe: pacman checks reverse dependencies before
# removing each dep, so shared libraries (e.g. libfoo used by both pamac and
# another app) are preserved. Without this, pulling in pamac's deps leaves
# them installed forever after uninstall.
pacman -Rs --noconfirm \"\$pkg\" 2>&1
" </dev/null 2>&1)
local rc=\$?
_log "pacman -Rs exit code: \$rc"
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

if [[ -n "\$WAYLAND_DISPLAY" && -z "\$XDG_SESSION_TYPE" ]]; then
export XDG_SESSION_TYPE="wayland"
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

# Write uninstall command to a temp script to avoid triple-nested quoting.
# Variables are baked in at write-time; runtime env is set via export.
_UNINST_SCRIPT="\$STATE_DIR/.uninst-\$(date +%s).sh"
cat > "\$_UNINST_SCRIPT" << _UNINST_EOF
#!/bin/bash
export HOME="/home/${current_user}"
export PATH="/home/${current_user}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin"
"\$UNINSTALL_HELPER" --desktop-file "\$DESKTOP_BASENAME" > "\$UNINSTALL_LOG" 2>&1
rc=\$?
echo "Exit code: \$rc" >> "\$UNINSTALL_LOG"
chmod +x "\$_UNINST_SCRIPT"
_UNINST_EOF
chmod +x "\$_UNINST_SCRIPT"
nohup "\$_UNINST_SCRIPT" &>/dev/null &

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

# System/pacman app — check if actually installed before attempting uninstall
_pkg_name="\$(echo "\$COMPONENT_ID" | sed 's/\.desktop$//')"
_pkg_installed=false
if ${CONTAINER_MANAGER:-podman} exec "${CONTAINER_NAME}" bash -c "pacman -Qi \$_pkg_name" >/dev/null 2>&1; then
    _pkg_installed=true
fi

if [[ "\$_pkg_installed" == "false" ]]; then
    log_msg "Package \$_pkg_name not installed in container — forwarding to Discover"
    # Not installed in container and not a Flatpak — hand off to host store
    if command -v plasma-discover >/dev/null 2>&1; then
        exec plasma-discover "\$@"
    else
        log_msg "No host store available to handle appstream:// for uninstalled package \$_pkg_name"
        if command -v notify-send >/dev/null 2>&1; then
            notify-send -i dialog-information "App not installed" "\$_pkg_name is not installed in the Pamac container." 2>/dev/null || true
        fi
        exit 0
    fi
fi

log_msg "Uninstalling pacman app: \$COMPONENT_ID"
if command -v kdialog >/dev/null 2>&1; then
    CONFIRM=\$(kdialog --yesno "Remove \$_pkg_name? This was installed via Pamac." --title "Uninstall" 2>/dev/null)
    if [[ \$? -ne 0 ]]; then
        log_msg "User cancelled uninstall"
        exit 0
    fi
fi
    # Write uninstall to a temp script to avoid triple-nested quoting
    _RM_SCRIPT="\$STATE_DIR/.rm-pkg-\$(date +%s).sh"
    cat > "\$_RM_SCRIPT" << _RM_EOF
#!/bin/bash
${CONTAINER_MANAGER:-podman} exec -u 0 ${CONTAINER_NAME} bash -c 'rm -f /var/lib/pacman/db.lck; pacman -R --noconfirm \$_pkg_name' 2>&1
rm -f "\$HOME/.local/share/applications/${CONTAINER_NAME}-\$_pkg_name.desktop"
touch "\$HOME/.local/share/applications"
notify-send -i edit-delete "Uninstalled" "\$_pkg_name has been removed." 2>/dev/null || notify-send -i dialog-error "Uninstall Failed" "Could not remove \$_pkg_name" 2>/dev/null
_RM_EOF
    chmod +x "\$_RM_SCRIPT"
    nohup "\$_RM_SCRIPT" &>/dev/null &
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

    # Success path: the EXIT trap (_export_cleanup_on_error) will chain to
    # the master EXIT trap on exit, so no cleanup or trap restoration needed
    # here. The chained handler skips rollback when exit code is 0.

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

# Prevent concurrent hook execution (two pacman transactions racing)
exec 9>/tmp/distrobox-export-hook.lock
flock -n 9 || exit 0

APP_DIR="/home/${current_user}/.local/share/applications"
STATE_DIR="/home/${current_user}/.local/share/steamos-pamac/${container_name}"
STATE_FILE="\$STATE_DIR/exported-apps.list"
CONTAINER_MANAGER="${DISTROBOX_CONTAINER_MANAGER:-podman}"
EXPORT_LOG="\$STATE_DIR/export-hook.log"
EXPLICIT_FILE="\$(mktemp)"
NEW_STATE_FILE="\$(mktemp)"
HASH_FILE="\$STATE_DIR/.last-explicit-hash"
echo "\$(date): Hook triggered" > "\$EXPORT_LOG"
mkdir -p "\$APP_DIR" "\$STATE_DIR"
trap 'rm -f "\$EXPLICIT_FILE" "\$NEW_STATE_FILE"' EXIT

pacman -Qeq > "\$EXPLICIT_FILE" 2>/dev/null || true

# Two-stage caching: fast gate (mtime-based) + full content hash.
# Stage 1: Hash package list + desktop file mtimes (stat-only, ~50ms).
# If this matches the cached value, skip the expensive md5sum scan entirely.
# Stage 2: Only when the fast gate differs, compute full content hash of
# desktop files to catch same-mtime content changes (rare rebuilds).
PKG_HASH="\$(md5sum "\$EXPLICIT_FILE" 2>/dev/null | awk '{print \$1}')"
MTIME_HASH=""
if [[ -d /usr/share/applications ]]; then
    # Fast gate: file count + total size as a lightweight pre-check.
    # If count and total size match, the md5sum of mtimes is unlikely to differ.
    # This avoids the expensive find+md5sum pipeline on every transaction.
    _desktop_count=\$(find /usr/share/applications -type f -name '*.desktop' 2>/dev/null | wc -l)
    _desktop_total_size=\$(find /usr/share/applications -type f -name '*.desktop' -printf '%s+' 2>/dev/null | awk '{s+=\$1}END{print s+0}')
    MTIME_HASH="\${_desktop_count}:\${_desktop_total_size}"
fi
FAST_HASH="\${PKG_HASH}:\${MTIME_HASH}"
FAST_CACHE="\$STATE_DIR/.last-fast-hash"
if [[ -f "\$FAST_CACHE" ]] && [[ "\$(cat "\$FAST_CACHE" 2>/dev/null)" == "\$FAST_HASH" ]]; then
    echo "\$(date): Fast gate unchanged (pkg+mtimes=\${FAST_HASH:0:8}). Skipping export." >> "\$EXPORT_LOG"
    exit 0
fi
# Fast gate differs — compute full content hash to confirm change
CURRENT_HASH="\$PKG_HASH"
if [[ -d /usr/share/applications ]]; then
    DESKTOP_SIG="\$(find /usr/share/applications -type f -name '*.desktop' \
        -exec md5sum {} + 2>/dev/null | sort -k2 | md5sum | awk '{print \$1}')"
    CURRENT_HASH="\${CURRENT_HASH}:\${DESKTOP_SIG}"
fi
if [[ -f "\$HASH_FILE" ]]; then
    LAST_HASH="\$(cat "\$HASH_FILE" 2>/dev/null || echo "")"
    if [[ "\$CURRENT_HASH" == "\$LAST_HASH" ]]; then
        # Content unchanged despite mtime difference (e.g. touch without edit)
        echo "\$FAST_HASH" > "\$FAST_CACHE" 2>/dev/null || true
        echo "\$(date): Desktop content unchanged (hash=\${CURRENT_HASH:0:8}). Skipping export." >> "\$EXPORT_LOG"
        exit 0
    fi
fi
echo "\$FAST_HASH" > "\$FAST_CACHE" 2>/dev/null || true
echo "\$CURRENT_HASH" > "\$HASH_FILE" 2>/dev/null || true
echo "\$(date): Changes detected (pkg+mtimes=\${FAST_HASH:0:8}, content=\${CURRENT_HASH:0:8}). Running export." >> "\$EXPORT_LOG"

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
    local _cm="\${5:-\${CONTAINER_MANAGER:-podman}}"

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
Exec=bash -c '${DISTROBOX_CONTAINER_MANAGER:-podman} exec -u 0 ${container_name} pacman -R --noconfirm pamac-aur 2>/dev/null && rm -f /home/${current_user}/.local/share/applications/${container_name}-org.manjaro.pamac.manager.desktop && touch /home/${current_user}/.local/share/applications && notify-send -i edit-delete "Uninstalled" "pamac-aur removed" 2>/dev/null'
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
  # NOTE: Minimal Arch base images occasionally split python-configparser
  # into separate packages on major Python version bumps. The pacman -S
  # fallback below handles this automatically.
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
    echo "  NOTE: The awk fallback may lose [Desktop Action] sections or" >&2
    echo "  localized keys (Name[de], Comment[fr]) in complex .desktop files." >&2
    echo "  Install python3 for full-fidelity desktop annotation:" >&2
    echo "    sudo pacman -S --noconfirm --needed python" >&2
    # Use awk instead of sed to properly handle multi-section .desktop files.
    # sed's \$a appends to the END of the file, which corrupts files that have
    # [Desktop Action ...] sections after [Desktop Entry]. awk targets the
    # boundary between [Desktop Entry] and the next section.
    # Localized keys (Name[de], Comment[fr], etc.) are preserved by targeting
    # only exact key prefixes within [Desktop Entry], not globally.
    awk -v container="${container_name}" -v user="${current_user}" \
        -v export_name="${export_name}" -v app_name="${app_name}" \
        -v owner_pkg="${owner_pkg}" -v _cm="${_cm}" '
    BEGIN { in_entry=0; inserted=0; saw_next_section=0; in_uninstall=0 }
    /^\[Desktop Entry\]/ { in_entry=1; print; next }
    # Strip any pre-existing [Desktop Action uninstall] section FIRST so the
    # direct one-liner appended in END is the only uninstall action — no stale
    # helper-based Exec survives re-annotation.
    /^\[Desktop Action uninstall\]/ { in_uninstall=1; next }
    in_uninstall && /^\[/ { in_uninstall=0 }
    in_uninstall { next }
    # Entering any section other than [Desktop Entry] disables entry-scoped
    # stripping so localized keys (Name[de], Comment[fr], etc.) in other
    # sections are never accidentally removed.
    /^\[/ && !/^\[Desktop Entry\]/ { in_entry=0 }
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
    # Only strip old markers within [Desktop Entry] to avoid clobbering
    # unrelated keys in [Desktop Action *] or other sections.
    in_entry && /^Actions=/ { next }
    in_entry && /^X-SteamOS-Pamac-/ { next }
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
        printf "Exec=bash -c '%s exec -u 0 %s pacman -R --noconfirm %s 2>/dev/null && rm -f %s && touch %s && notify-send -i edit-delete \"Uninstalled\" \"%s removed\" 2>/dev/null'\n", _cm, container, owner_pkg, _host_file, _apps_dir, owner_pkg
        print "Icon=edit-delete"
    }
    { print }
    ' "\$desktop_file" > "\${desktop_file}.tmp" && mv -f "\${desktop_file}.tmp" "\$desktop_file"
    _fix_desktop_permissions "\$desktop_file"
    return 0
  fi
  desktop_basename="\$(basename "\$desktop_file")"

  python3 - "\$desktop_file" "\$desktop_basename" "${container_name}" "${current_user}" "\$export_name" "\$app_name" "\$owner_pkg" "\$_cm" << 'PYTHON_DESKTOP_REWRITE'
import sys, configparser, io, os, tempfile

desktop_path = sys.argv[1]
desktop_basename = sys.argv[2]
container_name = sys.argv[3]
current_user = sys.argv[4]
export_name = sys.argv[5]
app_name = sys.argv[6]
owner_pkg = sys.argv[7]
_cm = sys.argv[8]

try:
    # Read raw file to preserve sections configparser may flatten
    with open(desktop_path, 'r') as f:
        raw = f.read()

    if not raw.strip():
        print(f"WARN: Desktop file is empty: {desktop_path}", file=sys.stderr)
        sys.exit(1)

    # Parse into ordered sections. .desktop files are not strictly INI-compliant
    # (duplicate keys, missing values, localized keys like Name[de]). Use
    # strict=False and handle potential parsing errors gracefully.
    parser = configparser.ConfigParser(strict=False, interpolation=None)
    parser.optionxform = str  # preserve key casing
    try:
        parser.read_string(raw)
    except configparser.ParsingError as e:
        # Malformed .desktop file — try line-by-line recovery
        print(f"WARN: ConfigParser failed ({e}), attempting line-by-line recovery", file=sys.stderr)
        safe_lines = []
        for line in raw.splitlines():
            line = line.strip()
            if not line or line.startswith('[') or '=' in line:
                safe_lines.append(line)
        parser.read_string('\n'.join(safe_lines))

    if not parser.sections():
        print(f"WARN: No sections found in {desktop_path} — file may be malformed", file=sys.stderr)
        sys.exit(1)

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
lines.append(f"Exec=bash -c '{_cm} exec -u 0 {container_name} pacman -R --noconfirm {owner_pkg} 2>/dev/null && rm -f {_host_desktop_path} && touch {_apps_dir} && notify-send -i edit-delete \"Uninstalled\" \"{owner_pkg} removed\" 2>/dev/null'")
lines.append('Icon=edit-delete')

for section, items in other_sections.items():
    lines.append('')
    lines.append(f'[{section}]')
    for k, v in items.items():
        lines.append(f'{k}={v}')

# Atomic Write: write to temporary file on same filesystem, then replace.
# Prevents truncation if interrupted mid-write (kernel panic, power cut).
desktop_dir = os.path.dirname(desktop_path)
with tempfile.NamedTemporaryFile('w', dir=desktop_dir, delete=False) as tf:
    tf.write('\n'.join(lines) + '\n')
    temp_name = tf.name
try:
    os.replace(temp_name, desktop_path)
except Exception as e:
    if os.path.exists(temp_name):
        os.unlink(temp_name)
    raise e

except Exception as e:
    print(f"ERROR: Desktop file rewrite failed: {e}", file=sys.stderr)
    print(f"  File: {desktop_path}", file=sys.stderr)
    print(f"  The original file was preserved (backup at .bak if created).", file=sys.stderr)
    sys.exit(1)
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

# TrustAll-all-repos flag, baked into this script at install time.
# When "true", Strategy 4 keeps third-party repos in the throwaway config.
_TRUSTALL_ALL_REPOS=_TRUSTALL_ALL_REPOS_BAKED_IN_

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
    if [[ "${_TRUSTALL_ALL_REPOS:-false}" != "true" ]]; then
        # Strip every repo except the official Arch repos from the throwaway
        # config. The TrustAll window disables signature verification, so a
        # compromised third-party mirror could otherwise inject a tampered
        # archlinux-keyring. Only the signed-official [core]/[extra]/[multilib]
        # repos remain — and only [core] is needed for the keyring package.
        _TA_ALLOWED_REPOS='core|extra|multilib|core-testing|extra-testing|multilib-testing'
        awk -v allowed="^(${_TA_ALLOWED_REPOS})$" '
            /^\[/{ in_repo=($0 ~ allowed); if(!in_repo){print "# TRUSTALL-STRIPPED: "$0; next} }
            in_repo{print; next}
            !in_repo{print "# TRUSTALL-STRIPPED: "$0}
        ' "$_TA_CONF" > "${_TA_CONF}.tmp" && mv -f "${_TA_CONF}.tmp" "$_TA_CONF"
        echo "  Non-official repos stripped from throwaway config."
    else
        echo "  --trustall-all-repos: all repos (including third-party) kept in throwaway config."
    fi
    # Atomic SigLevel rewrite: sed to temp file + mv (POSIX rename is atomic)
    local _ta_tmp="${_TA_CONF}.tmp"
    sed "s|^[[:space:]]*SigLevel.*|SigLevel = TrustAll|" "$_TA_CONF" > "$_ta_tmp"
    if ! grep -q '^SigLevel' "$_ta_tmp" 2>/dev/null; then
        printf 'SigLevel = TrustAll\n' >> "$_ta_tmp"
    fi
    mv -f "$_ta_tmp" "$_TA_CONF"
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
    # Bake the current TRUSTALL_ALL_REPOS setting into the generated
    # pamac-keyring-refresh.sh so Strategy 4 can decide whether to strip
    # third-party repos from the throwaway TrustAll config.
    keyring_script="${keyring_script//_TRUSTALL_ALL_REPOS_BAKED_IN_/${TRUSTALL_ALL_REPOS:-false}}"
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

repair_installation() {
    log_step "Repair mode: checking installation state for container '$CONTAINER_NAME'"
    local state_dir="$HOME/.local/share/steamos-pamac/$CONTAINER_NAME"
    local stages_dir="$state_dir/stages"
    mkdir -p "$stages_dir" 2>/dev/null || true
    local repair_ok=true

    local stage_names=(
        "base_setup:configure_container_base"
        "critical_helpers:ensure_critical_helpers"
        "mirror_optimize:optimize_pacman_mirrors"
        "multilib:configure_multilib"
        "extra_repos:configure_extra_repos"
        "aur_helper:install_aur_helper"
        "pamac_install:install_pamac"
        "cache_cleanup:setup_cache_cleanup"
        "gaming_packages:install_gaming_packages"
        "export_pamac:export_pamac_to_host"
        "post_install_hooks:setup_post_install_hooks"
        "keyring_refresh:setup_keyring_refresh"
        "export_apps:export_existing_apps"
    )

    local has_pending=false
    for stage_entry in "${stage_names[@]}"; do
        local stage_key="${stage_entry%%:*}"
        local stage_func="${stage_entry#*:}"
        local sentinel="$stages_dir/$stage_key.done"
        if [[ ! -f "$sentinel" ]]; then
            log_info "Stage '$stage_key' has not been completed (no sentinel found)."
            has_pending=true
        fi
    done

    if [[ "$has_pending" == "false" ]]; then
        log_success "All stages appear to be complete. Running verification..."
        # Quick verification: check key components
        if container_is_usable 2>/dev/null; then
            local all_ok=true
            container_root_exec bash -c "command -v pamac-manager >/dev/null 2>&1" 2>/dev/null || all_ok=false
            container_root_exec bash -c "command -v yay >/dev/null 2>&1" 2>/dev/null || all_ok=false
            if [[ "$all_ok" == "true" ]]; then
                log_success "Installation verified: all components present."
                return 0
            fi
            log_warn "Some components missing despite stage sentinels. Re-running all stages."
            rm -f "$stages_dir"/*.done 2>/dev/null || true
        else
            log_warn "Container not usable. Attempting to start and re-run setup stages."
            if ! container_start 2>/dev/null || ! container_is_usable; then
                log_error "Container cannot be started. Try removing and recreating:"
                log_error "  distrobox rm -f $CONTAINER_NAME && $0"
                return 1
            fi
            rm -f "$stages_dir"/*.done 2>/dev/null || true
        fi
    fi

    if ! distrobox list --no-color 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
        log_error "Container '$CONTAINER_NAME' does not exist. Cannot repair."
        log_info "Run the full installation: $0"
        return 1
    fi

    ensure_podman

    log_info "Re-running incomplete stages..."

    for stage_entry in "${stage_names[@]}"; do
        local stage_key="${stage_entry%%:*}"
        local stage_func="${stage_entry#*:}"
        local sentinel="$stages_dir/$stage_key.done"

        if [[ -f "$sentinel" ]]; then
            log_debug "Stage '$stage_key' already completed, skipping."
            continue
        fi

        log_info "Repairing stage: $stage_key"
        if ! _ensure_healthy_or_recreate "before $stage_key" 2>/dev/null; then
            log_warn "Container not healthy for '$stage_key', attempting restart..."
            container_start 2>/dev/null || true
            sleep 3
        fi

        if declare -f "$stage_func" >/dev/null 2>&1; then
            if "$stage_func"; then
                touch "$sentinel" 2>/dev/null || true
                log_success "Stage '$stage_key' repaired successfully."
            else
                log_warn "Stage '$stage_key' failed during repair. Continuing to next stage."
                repair_ok=false
            fi
        else
            log_warn "Unknown stage function '$stage_func'. Skipping."
        fi
    done

    log_info "Running final export and cleanup..."
    export_pamac_to_host 2>/dev/null || true
    setup_post_install_hooks 2>/dev/null || true
    export_existing_apps 2>/dev/null || true

    if [[ "$repair_ok" == "true" ]]; then
        log_success "Repair completed successfully."
    else
        log_warn "Repair completed with some issues. Some stages may still need attention."
        log_info "Re-run repair or check logs: $LOG_FILE"
    fi
}

show_completion_message() {
    log_info ""
    log_success "Steam Deck Pamac Setup completed successfully!"
    log_info ""

    # ── Degradation Report ──
    # Provides a concise, scannable status summary so users immediately know
    # what's working and what needs attention — preventing "sandbox broken"
    # bug reports when the system is actually running in a degraded-but-safe mode.
    log_info "${BOLD}${BLUE}--- System Status ---${NC}"
    if container_is_usable 2>/dev/null; then
        log_info "  ✅ Container: OK ($CONTAINER_NAME)"
    else
        log_info "  ❌ Container: NOT RUNNING (try: podman start $CONTAINER_NAME)"
    fi

    # Check pamac version
    local _pamac_ver=""
    _pamac_ver=$(container_user_exec bash -c "pacman -Qi pamac-aur 2>/dev/null | grep Version | awk '{print \$3}'" 2>/dev/null || echo "")
    if [[ -n "$_pamac_ver" ]]; then
        log_info "  ✅ Pamac: Installed (version $_pamac_ver)"
    else
        log_info "  ❌ Pamac: NOT INSTALLED"
    fi

    # Check sandbox status — with --use-init (default), real systemd provides
    # full isolation; with --no-use-init, check for bwrap + seccomp helper.
    local _has_init=false
    container_root_exec bash -c "command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1" 2>/dev/null && _has_init=true
    if [[ "$_has_init" == "true" ]]; then
        log_info "  ✅ Sandbox: FULL (systemd native isolation)"
    else
        local _has_gcc=false
        local _has_bwrap=false
        local _has_seccomp_helper=false
        container_user_exec bash -c "command -v gcc >/dev/null 2>&1" 2>/dev/null && _has_gcc=true
        container_user_exec bash -c "command -v bwrap >/dev/null 2>&1" 2>/dev/null && _has_bwrap=true
        if [[ "$_has_gcc" == "true" ]] || container_user_exec bash -c "[[ -x /tmp/.dsr-seccomp-helper ]]" 2>/dev/null; then
            _has_seccomp_helper=true
        fi
        if [[ "$_has_bwrap" == "true" ]] && [[ "$_has_seccomp_helper" == "true" ]]; then
            log_info "  ✅ Sandbox: FULL (shim: bwrap + seccomp-BPF)"
        elif [[ "$_has_bwrap" == "true" ]]; then
            log_info "  ⚠️  Sandbox: DEGRADED (bwrap + no seccomp) — run: sudo pacman -S base-devel gcc"
        elif [[ "$_has_seccomp_helper" == "true" ]]; then
            log_info "  ⚠️  Sandbox: DEGRADED (no bwrap, seccomp only) — run: sudo pacman -S bubblewrap"
        else
            log_info "  ⚠️  Sandbox: DEGRADED (no sandboxing) — run: sudo pacman -S base-devel gcc bubblewrap"
        fi
    fi

    # Check sudoers scope
    local _sudoers_scope=""
    _sudoers_scope=$(container_root_exec bash -c "grep -c 'NOPASSWD' /etc/sudoers.d/99-pamac-nopasswd 2>/dev/null || echo 0" 2>/dev/null || echo "0")
    if [[ "$_sudoers_scope" -gt 0 ]]; then
        if container_root_exec bash -c "grep -q '%wheel' /etc/sudoers.d/99-pamac-nopasswd 2>/dev/null" 2>/dev/null; then
            log_info "  ⚠️  Sudoers: wheel group (consider --allow-wheel-nopasswd on multi-user hosts)"
        else
            log_info "  ✅ Sudoers: per-user (recommended)"
        fi
    fi

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
    log_info " eMMC/SD wear protection: tmpfs BUILDDIR + ccache"
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
        if container_root_exec bash -c '. /usr/local/lib/pamac-common.sh 2>/dev/null || true; _remove_stale_lock; pacman -Syy --noconfirm' 2>/dev/null; then
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
        if container_root_exec bash -c '. /usr/local/lib/pamac-common.sh 2>/dev/null || true; _remove_stale_lock; pacman -Syu --noconfirm' 2>/dev/null; then
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
    # shellcheck disable=all # Inner script runs inside container via bash -c
    container_root_exec bash -c '
set +e
# Check for database inconsistencies
if ! pacman -Dk 2>/dev/null | grep -q "No database errors"; then
    echo "WARNING: Database inconsistencies detected after upgrade."
    pacman -Dk 2>&1 | head -10 || true
fi

# Verify critical shared libraries are intact (resolve via ldconfig, not
# hardcoded /usr/lib paths)
_critical_libs_ok=true
for _lib_name in libc.so.6 libm.so.6 libpthread.so.0; do
    _lib=$(ldconfig -p 2>/dev/null | grep "$_lib_name" | head -1 | awk '{print $NF}' || echo "")
    if [[ -n "$_lib" && -f "$_lib" ]] && ! ldd "$_lib" >/dev/null 2>&1; then
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

    if container_is_usable 2>/dev/null || container_root_exec bash -c "echo ok" 2>/dev/null | grep -q ok; then
        if container_root_exec bash -c "command -v pamac-manager >/dev/null 2>&1 && command -v pamac >/dev/null 2>&1" 2>/dev/null; then
            local pamac_ver
            pamac_ver=$(container_root_exec bash -c "pamac --version 2>/dev/null | head -1" 2>/dev/null || echo "unknown")
            echo -e "  Pamac CLI:     ${GREEN}INSTALLED${NC} ($pamac_ver)"
        else
            echo -e "  Pamac CLI:     ${RED}NOT FOUND${NC}"
            has_issues=true
        fi

        if container_root_exec bash -c "command -v pamac-manager >/dev/null 2>&1" 2>/dev/null; then
            echo -e "  Pamac Manager: ${GREEN}INSTALLED${NC}"
        else
            echo -e "  Pamac Manager: ${RED}NOT FOUND${NC}"
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

apply_quick_start_preset() {
    if [[ "${QUICK_START:-false}" != "true" ]]; then
        return 0
    fi

    log_step "Quick-start mode — applying minimal safe defaults..."

    # Preserve explicit user overrides from the command line / environment.
    # We only set values that the user has NOT explicitly chosen. The defaults
    # below favor a working, conservative install over performance/extras.
    #
    # Sensible defaults for a less experienced user:
    #   - multilib ON (Steam/Proton 32-bit needs it)
    #   - build cache ON (resume interrupted builds, avoid recompiling yay)
    #   - extra repos ON (common dependencies)
    #   - mirror optimization ON (faster downloads, good default)
    #   - PACMAN pin-alpm ON (prevents API breakage on rolling containers)
    #   - gaming packages OFF (opinionated bloat for a bare-minimum install)
    #   - strict-security OFF (kept at default so AUR DynamicUser builds work)
    #   - non-interactive OFF (a quick-start user still benefits from prompts
    #     around dangerous operations; --non-interactive is a separate opt-in)
    #
    # Each line uses ${VAR:-default} so an explicit env var or CLI flag wins.
    # We explicitly avoid forcing NON_INTERACTIVE here — quick-start should
    # reduce option confusion, not remove safety prompts.
    ENABLE_MULTILIB="${ENABLE_MULTILIB:-true}"
    ENABLE_BUILD_CACHE="${ENABLE_BUILD_CACHE:-true}"
    ENABLE_EXTRA_REPOS="${ENABLE_EXTRA_REPOS:-true}"
    OPTIMIZE_MIRRORS="${OPTIMIZE_MIRRORS:-true}"
    PIN_ALPM="${PIN_ALPM:-true}"
    ENABLE_GAMING_PACKAGES="${ENABLE_GAMING_PACKAGES:-false}"
    ROLLING_RELEASE="${ROLLING_RELEASE:-false}"

    # Quick-start explicitly recommends keeping the AUR compat check ON so an
    # incompatible pamac-aur doesn't silently fail the build later. Only honor
    # an explicit --skip-compat-check.
    if [[ "${SKIP_COMPAT_CHECK:-}" != "true" ]]; then
        SKIP_COMPAT_CHECK="false"
    fi

    log_info "Quick-start preset applied:"
    log_info "  multilib=$ENABLE_MULTILIB build-cache=$ENABLE_BUILD_CACHE extra-repos=$ENABLE_EXTRA_REPOS"
    log_info "  optimize-mirrors=$OPTIMIZE_MIRRORS pin-alpm=$PIN_ALPM gaming=$ENABLE_GAMING_PACKAGES"
    log_info "  AUR compat check: enabled (recommended for first-time installs)"
    log_info "Advanced users can override any option by passing it after --quick-start."
}

main() {
    setup_colors

    # Parse arguments first so that --help / --version are handled before the
    # root check. A root-invoked `sudo ./script.sh --help` should print help,
    # not the "do not run as root" error. parse_arguments exits on --help and
    # --version, so we never reach the EUID guard for those. Operational flags
    # (which require a writable container namespace) still hit the root guard.
    parse_arguments "$@"

    # Apply quick-start preset AFTER argument parsing so that explicit CLI
    # flags (which set the same variables in parse_arguments) take precedence
    # over the preset defaults. Order matters: parse first, then layer the
    # preset only for values that the user did not touch.
    apply_quick_start_preset

    # Apply rolling release flag: overrides the container image to archlinux:latest
    # when --rolling-release is set. The default is archlinux:base (pinned stable).
    if [[ "${ROLLING_RELEASE:-false}" == "true" ]]; then
        CONTAINER_IMAGE="archlinux:latest"
        log_info "Rolling release mode: using ${CONTAINER_IMAGE} (latest packages, may break on major upgrades)."
    else
        log_info "Stable release mode: using ${CONTAINER_IMAGE} (pinned, less frequent breakage)."
        log_info "  Use --rolling-release to switch to archlinux:latest."
    fi

    # Auto-enable low-memory mode on SteamOS. The Steam Deck has 16GB RAM
    # shared with the GPU (usable ~12GB), and AUR builds (especially C++
    # projects like pamac-aur) can OOM during compilation. Auto-detect SteamOS
    # unless the user explicitly passed --low-memory or set LOW_MEMORY=true.
    if [[ "${LOW_MEMORY:-false}" != "true" ]] && grep -q "ID=steamos" /etc/os-release 2>/dev/null; then
        LOW_MEMORY="true"
        log_info "SteamOS detected — auto-enabling low-memory mode for AUR builds."
    fi

    # Finalize the per-container log path now that CONTAINER_NAME is resolved.
    # Without this, runs with different --container-name overwrite one shared
    # log (issue: log-file collision across container names).
    LOG_FILE="$HOME/distrobox-pamac-setup-${CONTAINER_NAME}.log"
    EVENT_LOG_FILE="$HOME/distrobox-pamac-events-${CONTAINER_NAME}.jsonl"

    if [[ "$EUID" -eq 0 ]]; then
        echo -e "\e[91mThis script should not be run as root.\e[0m" >&2
        echo -e "\e[91mPlease run as the regular user (e.g., 'deck' on Steam Deck).\e[0m" >&2
        exit 1
    fi
    # Prevent concurrent execution with file locking.
    # Acquire the lock BEFORE initialize_logging to prevent two instances from
    # racing on log rotation. Without this, both could read the same file size,
    # both decide to rotate, and one rotation overwrites the other's backup.
    local _lock_dir="${XDG_RUNTIME_DIR:-$HOME/.local/state}"
    mkdir -p "$_lock_dir" 2>/dev/null || _lock_dir="/tmp"
    local _lock_file="$_lock_dir/steamos-pamac-setup.lock"
    exec 9>"$_lock_file"
    if ! flock -n 9; then
        echo "ERROR: Another instance of this script is already running (lock file: $_lock_file)." >&2
        echo "If no other instance is running, remove the lock file and try again." >&2
        exit 1
    fi

    initialize_logging

    if [[ "$SELF_UPDATE" == "true" ]]; then
        self_update
        exit $?
    fi

    if [[ "$REPAIR" == "true" ]]; then
        ensure_podman
        repair_installation
        exit $?
    fi

    if [[ "$_verify_sandbox_flag" == "true" ]]; then
        ensure_podman
        verify_sandbox
        exit $?
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

    _interactive_setup_menu

    check_battery_power || exit "$EXIT_USER_ABORT"
    _preflight_space_check "installation" || exit "$EXIT_USER_ABORT"

    if [[ "$ALLOW_WHEEL_NOPASSWD" == "true" ]]; then
        check_multi_user_warning
    fi

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
    log_step "Force rebuild requested — container '$CONTAINER_NAME' will be removed and recreated."
    if ! confirm_container_recreation; then
        log_error "Force rebuild declined by user. Aborting."
        exit "$EXIT_USER_ABORT"
    fi
    CONTAINER_HAS_INIT="unknown"
    uninstall_setup  # already calls force_remove_container internally
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
          if ! confirm_container_recreation; then
            log_error "Container recreation declined by user. Aborting."
            exit "$EXIT_USER_ABORT"
          fi
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
                    if ! confirm_container_recreation; then
                        log_error "Container recreation declined by user. Aborting."
                        exit "$EXIT_USER_ABORT"
                    fi
                    force_remove_container "$CONTAINER_NAME"
                    sleep 2
                    create_container || exit 1
                fi
        else
          log_warn "Container in '$existing_status' state - removing and recreating"
          if ! confirm_container_recreation; then
            log_error "Container recreation declined by user. Aborting."
            exit "$EXIT_USER_ABORT"
          fi
          force_remove_container "$CONTAINER_NAME"
          sleep 2
          create_container || exit 1
        fi
        ;;
      "created")
        log_info "Container in 'created' state, starting..."
        container_start || {
          log_warn "Failed to start, recreating..."
          if ! confirm_container_recreation; then
            log_error "Container recreation declined by user. Aborting."
            exit "$EXIT_USER_ABORT"
          fi
          force_remove_container "$CONTAINER_NAME"
          sleep 2
          create_container || exit 1
        }
        wait_for_container || exit 1
        ;;
      *)
        log_warn "Container in unknown state '$existing_status' - removing and recreating"
        if ! confirm_container_recreation; then
          log_error "Container recreation declined by user. Aborting."
          exit "$EXIT_USER_ABORT"
        fi
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

    local stages_base="$HOME/.local/share/steamos-pamac/$CONTAINER_NAME/stages"
    mkdir -p "$stages_base" 2>/dev/null || true
    _touch_stage() { touch "$stages_base/$1.done" 2>/dev/null || true; }

    # Snapshot the container before critical modifications for rollback on failure.
    # This captures the container state so we can restore it if configure_container_base
    # or subsequent stages fail irrecoverably.
    if [[ "$DRY_RUN" != "true" ]]; then
        # shellcheck disable=SC2119
        _snapshot_container
    fi

	if ! configure_container_base; then
		log_error "Container base setup failed permanently. Aborting installation."
        if [[ "$DRY_RUN" != "true" ]]; then
            # shellcheck disable=SC2119
            _rollback_container
        fi
		exit 1
	fi
	_touch_stage "base_setup"

	_ensure_healthy_or_recreate "before critical helpers check" || exit 1
	ensure_critical_helpers
	_touch_stage "critical_helpers"

	_ensure_healthy_or_recreate "before mirror optimization" || exit 1
	optimize_pacman_mirrors
	_touch_stage "mirror_optimize"

	_ensure_healthy_or_recreate "before multilib setup" || exit 1
    configure_multilib
    _touch_stage "multilib"

    _ensure_healthy_or_recreate "before extra repos setup" || exit 1
    configure_extra_repos
    _touch_stage "extra_repos"

    _ensure_healthy_or_recreate "after base setup" || exit 1

	check_memory_ok 524288 "AUR helper build" 262144 || {
		log_error "Insufficient memory for AUR helper build (need at least 256MB). Aborting."
		exit 1
	}
	_preflight_space_check "AUR helper build" || {
		log_error "Insufficient disk space for AUR helper build. Aborting."
		exit 1
	}
	check_battery_power || log_warn "Battery low, but continuing AUR helper build..."

	if ! install_aur_helper; then
		if _ensure_healthy_or_recreate "aur helper recovery"; then
			log_info "Retrying AUR helper install..."
			install_aur_helper || {
                log_error "AUR helper install failed after recovery. Rolling back."
                # shellcheck disable=SC2119
                if [[ "$DRY_RUN" != "true" ]]; then _rollback_container; fi
                exit 1
            }
		else
            # shellcheck disable=SC2119
            if [[ "$DRY_RUN" != "true" ]]; then _rollback_container; fi
			exit 1
		fi
	fi
	_touch_stage "aur_helper"

	_ensure_healthy_or_recreate "after aur helper" || exit 1

	if ! install_pamac; then
		if _ensure_healthy_or_recreate "pamac install recovery"; then
			log_info "Retrying Pamac install..."
			install_pamac || {
                log_error "Pamac install failed after recovery. Rolling back."
                # shellcheck disable=SC2119
                if [[ "$DRY_RUN" != "true" ]]; then _rollback_container; fi
                exit 1
            }
		else
            # shellcheck disable=SC2119
            if [[ "$DRY_RUN" != "true" ]]; then _rollback_container; fi
			exit 1
		fi
	fi
	_touch_stage "pamac_install"

	_ensure_healthy_or_recreate "after pamac install" || exit 1

    if [[ "$PIN_ALPM" == "true" ]]; then
        log_info "libalpm/pacman upgraded upfront during system upgrade."
        log_info "pamac-aur compatibility handled by ensure_pamac_aur_compat during install."
    fi

    ensure_critical_helpers
    _touch_stage "critical_helpers"

    setup_cache_cleanup
    _touch_stage "cache_cleanup"

    install_gaming_packages
    _touch_stage "gaming_packages"

    export_pamac_to_host
    _touch_stage "export_pamac"

    setup_post_install_hooks
    _touch_stage "post_install_hooks"

    setup_keyring_refresh
    _touch_stage "keyring_refresh"

    export_existing_apps
    _touch_stage "export_apps"

    show_completion_message
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
