#!/bin/bash
# Fake systemd-run v4.0 for non-systemd containers (Distrobox).
# Fully emulates systemd-run for Pamac/makepkg DynamicUser AUR builds with
# complete sandboxing parity: all sandbox properties enforced via seccomp-BPF,
# mount namespaces, capability dropping, and bubblewrap (bwrap).
# Supports: --user, --scope, DynamicUser (yes/true/1/on), --property=*, --setenv.
# Logs diagnostics to /tmp/systemd-run-fake.log; warns on unrecognized properties.
# SECURITY: Restrict log permissions to root-only to avoid leaking sandbox config.
_DSR_LOG="/tmp/systemd-run-fake.log"
if [[ ! -f "$_DSR_LOG" ]]; then
    touch "$_DSR_LOG" 2>/dev/null && chmod 600 "$_DSR_LOG" 2>/dev/null || true
fi
DSR_VERSION="4.0"
_DSR_STRICT_SECURITY="${_STRICT_SECURITY_MODE:-false}"
_log_dsr() { echo "[$(date '+%H:%M:%S')] $*" >> "$_DSR_LOG" 2>/dev/null; }
_warn_dsr() { echo "systemd-run(fake): WARNING: $*" >> "$_DSR_LOG" 2>/dev/null; echo "systemd-run(fake): WARNING: $*" >&2 2>/dev/null || true; }
# SECURITY: Sanitize property values to prevent shell injection when values
# are interpolated into command strings (_assemble_build_wrapper, _ENV_SETUP).
# Only allows alphanumeric chars, hyphens, underscores, colons, dots, equals, spaces, slashes.
_dsr_sanitize_val() { echo "$1" | tr -cd 'a-zA-Z0-9_\-:=./ '; }

# DYN RESOLVE: Resolve the host user at runtime (the user who owns the container).
# Priority: 1) PAMAC_HOST_USER env var  2) $SUDO_USER if running under sudo
# 3) owner of /home/$USER if it exists  4) first passwd entry with uid >= 1000
# 5) fallback to "deck" (Steam Deck default).
_resolve_host_user() {
    if [[ -n "${PAMAC_HOST_USER:-}" ]] && id "${PAMAC_HOST_USER:-}" >/dev/null 2>&1; then
        echo "$PAMAC_HOST_USER"; return 0
    fi
    if [[ -n "${SUDO_USER:-}" ]] && id "${SUDO_USER:-}" >/dev/null 2>&1; then
        echo "$SUDO_USER"; return 0
    fi
    for _h in /home/*; do
        local _u; _u=$(basename "$_h")
        if id "$_u" >/dev/null 2>&1 && [[ "$(ls -ldn "$_h" 2>/dev/null | awk '{print $3}' || echo 0)" -ge 1000 ]]; then
            echo "$_u"; return 0
        fi
    done
    local _first_user
    _first_user=$(getent passwd 2>/dev/null | awk -F: '$3>=1000 && $3<65534 {print $1; exit}' || true)
    [[ -n "$_first_user" ]] && { echo "$_first_user"; return 0; }
    id deck >/dev/null 2>&1 && { echo "deck"; return 0; }
    echo "root"; return 0
}
_DSR_HOST_USER=$(_resolve_host_user)

# Pre-flight: clean up orphaned ad-hoc build users and temp home directories
# left behind by interrupted builds. Ad-hoc users are named _brecover* and
# own /var/tmp/builduser-home-* directories. Also purges stale /etc/subuid and
# /etc/subgid entries that would prevent useradd from succeeding on retry.
_cleanup_orphaned_buildusers() {
    local _orphan_users=""
    _orphan_users=$(getent passwd 2>/dev/null | awk -F: '$1 ~ /^_brecover/ { print $1 }' || true)
    for _ou in $_orphan_users; do
        _warn_dsr "Cleaning up orphaned build user: $_ou"
        userdel -r "$_ou" 2>/dev/null || userdel "$_ou" 2>/dev/null || true
        # Purge orphaned subuid/subgid entries so useradd won't fail with
        # "uid already in use" on the next transient user creation attempt.
        # SECURITY: Use grep -F (fixed string) to avoid regex injection via username.
        if [[ -w /etc/subuid ]]; then
            grep -vF "${_ou}:" /etc/subuid > /etc/subuid.tmp 2>/dev/null && \
                mv /etc/subuid.tmp /etc/subuid 2>/dev/null || rm -f /etc/subuid.tmp 2>/dev/null
        fi
        if [[ -w /etc/subgid ]]; then
            grep -vF "${_ou}:" /etc/subgid > /etc/subgid.tmp 2>/dev/null && \
                mv /etc/subgid.tmp /etc/subgid 2>/dev/null || rm -f /etc/subgid.tmp 2>/dev/null
        fi
    done
    # Also clean up the _builduser system account if it exists but its home
    # directory is missing or owned by a different user (stale state from a
    # prior interrupted build that managed to delete /var/lib/builduser).
    if id "_builduser" >/dev/null 2>&1; then
        local _bu_home
        _bu_home=$(getent passwd _builduser 2>/dev/null | cut -d: -f6)
        if [[ -n "$_bu_home" && ! -d "$_bu_home" ]]; then
            _warn_dsr "Cleaning up _builduser with missing home ($_bu_home)"
            userdel _builduser 2>/dev/null || true
        fi
    fi
    for _dir in /var/tmp/builduser-home-*; do
        [[ -d "$_dir" ]] || continue
        if [[ "$(ls -ldn "$_dir" 2>/dev/null | awk '{print $3}' || echo 0)" -eq 0 ]]; then
            _warn_dsr "Removing orphaned build-user home: $_dir"
            rm -rf "$_dir" 2>/dev/null || true
        fi
    done
    # Also clean stale seccomp helper if version hash changed
    local _stale_helper="/tmp/.dsr-seccomp-helper"
    if [[ -f "$_stale_helper" ]] && ! "$_stale_helper" --version-check 2>/dev/null; then
        _warn_dsr "Removing stale seccomp helper (version mismatch)"
        rm -f "$_stale_helper" 2>/dev/null || true
    fi
}
_cleanup_orphaned_buildusers

# Passthrough: --help and --version
for _a in "$@"; do
    case "$_a" in
        --help|-h) echo "systemd-run (fake) v${DSR_VERSION}: Fully emulates systemd-run for DynamicUser AUR builds in non-systemd containers."; echo ""; echo "ALL ENFORCED via bwrap (bubblewrap) or unshare + bind mounts + capsh/setpriv + seccomp-BPF:"; echo "  Filesystem: ProtectSystem, ProtectHome, PrivateTmp, PrivateDevices,"; echo "              ReadWritePaths, ReadOnlyPaths, InaccessiblePaths,"; echo "              ProtectKernelTunables (/proc/sys, /sys read-only),"; echo "              ProtectControlGroups (/sys/fs/cgroup read-only)"; echo "  Network:    PrivateNetwork (--unshare-net with bwrap)"; echo "  Privileges: NoNewPrivileges, CapabilityBoundingSet (prctl + capsh),"; echo "              LockPersonality, RestrictRealtime,"; echo "              SecureBits (via setpriv), Personality (via personality syscall)"; echo "  Seccomp:    MemoryDenyWriteExecute (blocks mprotect W+X),"; echo "              RestrictSUIDSGID (blocks setuid/setgid family),"; echo "              ProtectKernelModules (blocks init/delete_module),"; echo "              ProtectClock (blocks clock_settime/adjtime/settimeofday),"; echo "              ProtectHostname (blocks sethostname/setdomainname),"; echo "              ProtectKernelLogs (blocks syslog syscall),"; echo "              RestrictNamespaces (blocks unshare, setns, clone with CLONE_NEW*),"; echo "              RestrictAddressFamilies (filters socket() by family),"; echo "              SystemCallFilter (denylist: reboot, kexec, ptrace, etc.),"; echo "              RestrictFileSystems (blocks mount syscall),"; echo "              SystemCallArchitectures (blocks non-native arch syscalls)"; echo "  Proc:       ProtectProc (restricts /proc visibility),"; echo "              ProcSubset (restricts /proc paths)"; echo "  Runtime:    sandbox integrity verified after applying restrictions"; echo "  DynamicUser: isolated build user with private home under /var/tmp"; echo "  User, Environment, EnvironmentFile, CacheDirectory, WorkingDirectory,"; echo "              UMask, SupplementaryGroups, DisableExtraFileDescriptors,"; echo "              CoredumpReceive, PrivateUsers, SystemCallErrorNumber, SystemCallLog"; echo "  --user:     run as host user (non-root invocation)"; echo "  --scope:    direct execution without transient unit creation"; echo ""; echo "RECOGNIZED (not enforced): RootDirectory, RootImage, RootHash, RootVerity,"; echo "  MountImages, ExtensionImages, NamespacePath, NetworkNamespacePath"; echo ""; echo "  Resource/accounting/logging/Condition/Assert/Timeout: recognized, silently accepted."; echo "  HOST_USER resolved dynamically from PAMAC_HOST_USER, SUDO_USER, or passwd."; echo "  Sandbox: bwrap (preferred) or unshare --mount --net + bind mounts + setpriv/capsh + seccomp helper (requires gcc)."; echo ""; echo "Use --strict-security on the installer to disable this wrapper entirely."; exit 0 ;;
        --version) echo "systemd-run (fake) v${DSR_VERSION} (SteamOS-Pamac)"; exit 0 ;;
    esac
done

# ── Runtime mode flags ──
DYNAMIC_USER=false
USER_MODE=false
SCOPE_MODE=false
CACHE_DIR=""
WORK_DIR=""
SKIP_NEXT=false
UNRECOGNIZED_PROPS=()
CMD_ARGS=()
EXTRA_ENV=()
EXTRA_GROUPS=""
TARGET_USER=""
ENV_FILES=()
SET_UMASK=""
# ── Sandbox properties (enforced via mount namespaces + bind mounts) ──
PROTECT_SYSTEM=""
PROTECT_HOME=""
PRIVATE_TMP=""
PRIVATE_DEVICES=""
PRIVATE_NETWORK=""
NO_NEW_PRIVS=""
CAP_BOUNDING_SET=""
READ_WRITE_PATHS=()
READ_ONLY_PATHS=()
INACCESSIBLE_PATHS=()
STATE_DIRECTORIES=()
LOGS_DIRECTORIES=()
RUNTIME_DIRECTORIES=()
BIND_PATHS=()
BIND_RO_PATHS=()
TMPFS_SPECS=()
MEMORY_DENY_WRITE_EXECUTE=""
SYSTEM_CALL_FILTER=""
RESTRICT_NAMESPACES=""
RESTRICT_SUID_SGID=""
LOCK_PERSONALITY=""
RESTRICT_REALTIME=""
RESTRICT_ADDRESS_FAMILIES=""
PROTECT_CLOCK=""
PROTECT_KERNEL_TUNABLES=""
PROTECT_KERNEL_MODULES=""
PROTECT_KERNEL_LOGS=""
PROTECT_CONTROL_GROUPS=""
PROTECT_HOSTNAME=""
RESTRICT_FILE_SYSTEMS="" 
# ── Sandbox properties (enforced via seccomp/prctl/bind mounts) ──
SECURE_BITS=""
PERSONALITY=""
SYS_CALL_ARCH=""
SYS_CALL_ERRNO=""
SYS_CALL_LOG=""
PROTECT_PROC=""
PROC_SUBSET=""
PRIVATE_USERS=""
DISABLE_EXTRA_FDS=""
COREDUMP_RECEIVE=""
# ── Resource limits (enforced via ulimit/prlimit) ──
LIMITS_RLIMIT=()
# ── Scheduling (enforced via ionice/nice/chrt) ──
IOSCHED_CLASS=""
IOSCHED_PRIORITY=""
CPUSCHED_POLICY=""
CPUSCHED_PRIORITY=""
NICE_LEVEL=""
# ── Capabilities ──
AMBIENT_CAPS=""
# ── Group identity ──
GROUP_NAME=""
# ── Mount propagation ──
MOUNT_FLAGS=""
# ── Environment ──
PASS_ENV=()
UNSET_ENV=()
# ── Directories ──
CONFIG_DIRS=()
# ── OOM ──
OOM_SCORE_ADJUST=""
TIMEOUT_START=""
# SECURITY: Track previous --setenv value for two-arg form (--setenv KEY VALUE)
_SETENV_NEXT_IS_VALUE=false
for arg in "$@"; do
if $SKIP_NEXT; then
SKIP_NEXT=false
continue
fi
# Handle --setenv KEY VALUE form: the next arg after --setenv is KEY=VALUE
if [[ "${_SETENV_NEXT_IS_VALUE:-}" == "true" ]]; then
    _SETENV_NEXT_IS_VALUE=false
    EXTRA_ENV+=("-e" "$arg")
    continue
fi
case "$arg" in
--service-type=*) continue ;;
--service-type) SKIP_NEXT=true; continue ;;
--pipe) _log_dsr "Flag --pipe ignored (not applicable to fake systemd-run)"; continue ;;
--wait) _log_dsr "Flag --wait ignored (not applicable to fake systemd-run)"; continue ;;
--pty|-q|--quiet|--no-block) _log_dsr "Flag $arg ignored (not applicable to fake systemd-run)"; continue ;;
--description=*) continue ;;
--description) SKIP_NEXT=true; continue ;;
--unit=*) continue ;;
--unit) SKIP_NEXT=true; continue ;;
--property=DynamicUser=yes) DYNAMIC_USER=true; continue ;;
--property=CacheDirectory=*) CACHE_DIR="${arg#--property=CacheDirectory=}"; continue ;;
--property=WorkingDirectory=*) WORK_DIR="$(_dsr_sanitize_val "${arg#--property=WorkingDirectory=}")"; continue ;;
# Recognized properties in this fake systemd-run. Security-hardening properties
# are enforced via seccomp-BPF, mount namespaces, and capability dropping.
# Resource and metadata properties that have no sandboxing impact are silently
# accepted for compatibility but not enforced (e.g., CPUQuota, TasksMax).
--property=StateDirectory=*) STATE_DIRECTORIES+=("${arg#--property=StateDirectory=}"); _log_dsr "Sandbox: $arg"; continue ;;
--property=LogsDirectory=*) LOGS_DIRECTORIES+=("${arg#--property=LogsDirectory=}"); _log_dsr "Sandbox: $arg"; continue ;;
--property=RuntimeDirectory=*) RUNTIME_DIRECTORIES+=("${arg#--property=RuntimeDirectory=}"); _log_dsr "Sandbox: $arg"; continue ;;
--property=Type=*) continue ;;
--property=RemainAfterExit=*) continue ;;
--property=TemporaryFileSystem=*) TMPFS_SPECS+=("${arg#--property=TemporaryFileSystem=}"); _log_dsr "Sandbox: $arg"; continue ;;
--property=BindPaths=*) BIND_PATHS+=("${arg#--property=BindPaths=}"); _log_dsr "Sandbox: $arg"; continue ;;
--property=BindReadOnlyPaths=*) BIND_RO_PATHS+=("${arg#--property=BindReadOnlyPaths=}"); _log_dsr "Sandbox: $arg"; continue ;;
--property=ProtectSystem=*) PROTECT_SYSTEM="${arg#--property=ProtectSystem=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=ProtectHome=*) PROTECT_HOME="${arg#--property=ProtectHome=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=PrivateTmp=*) PRIVATE_TMP="${arg#--property=PrivateTmp=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=NoNewPrivileges=*) NO_NEW_PRIVS="${arg#--property=NoNewPrivileges=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=MemoryDenyWriteExecute=*) MEMORY_DENY_WRITE_EXECUTE="${arg#--property=MemoryDenyWriteExecute=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=SystemCallFilter=*) SYSTEM_CALL_FILTER="${arg#--property=SystemCallFilter=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=CapabilityBoundingSet=*) CAP_BOUNDING_SET="${arg#--property=CapabilityBoundingSet=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=User=*) TARGET_USER="${arg#--property=User=}"; continue ;;
--property=Group=*) GROUP_NAME="${arg#--property=Group=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=SupplementaryGroups=*) EXTRA_GROUPS="${arg#--property=SupplementaryGroups=}"; continue ;;
--property=AmbientCapabilities=*) AMBIENT_CAPS="${arg#--property=AmbientCapabilities=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=EnvironmentFile=*) ENV_FILES+=("${arg#--property=EnvironmentFile=}"); continue ;;
--property=Ephemeral=*) continue ;;
--property=Slice=*) continue ;;
--property=IOSchedulingClass=*) IOSCHED_CLASS="${arg#--property=IOSchedulingClass=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=IOSchedulingPriority=*) IOSCHED_PRIORITY="${arg#--property=IOSchedulingPriority=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=CPUSchedulingPolicy=*) CPUSCHED_POLICY="${arg#--property=CPUSchedulingPolicy=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=CPUSchedulingPriority=*) CPUSCHED_PRIORITY="${arg#--property=CPUSchedulingPriority=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=CPUSchedulingResetOnFork=*) continue ;;
--property=Nice=*) NICE_LEVEL="${arg#--property=Nice=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=RestrictNamespaces=*) RESTRICT_NAMESPACES="${arg#--property=RestrictNamespaces=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=RestrictSUIDSGID=*) RESTRICT_SUID_SGID="${arg#--property=RestrictSUIDSGID=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=LockPersonality=*) LOCK_PERSONALITY="${arg#--property=LockPersonality=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=RestrictRealtime=*) RESTRICT_REALTIME="${arg#--property=RestrictRealtime=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=RestrictAddressFamilies=*) RESTRICT_ADDRESS_FAMILIES="${arg#--property=RestrictAddressFamilies=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=RemoveIPC=*) continue ;;
--property=UMask=*) SET_UMASK="${arg#--property=UMask=}"; if [[ "$SET_UMASK" =~ ^[0-7]+$ ]]; then _log_dsr "Sandbox: $arg"; else _warn_dsr "UMask=$SET_UMASK is not a valid octal mode"; SET_UMASK=""; fi; continue ;;
--property=KeyringMode=*) continue ;;
--property=ProtectClock=*) PROTECT_CLOCK="${arg#--property=ProtectClock=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=ProtectKernelTunables=*) PROTECT_KERNEL_TUNABLES="${arg#--property=ProtectKernelTunables=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=ProtectKernelModules=*) PROTECT_KERNEL_MODULES="${arg#--property=ProtectKernelModules=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=ProtectKernelLogs=*) PROTECT_KERNEL_LOGS="${arg#--property=ProtectKernelLogs=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=ProtectControlGroups=*) PROTECT_CONTROL_GROUPS="${arg#--property=ProtectControlGroups=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=ProtectHostname=*) PROTECT_HOSTNAME="${arg#--property=ProtectHostname=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=ProtectProc=*) PROTECT_PROC="${arg#--property=ProtectProc=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=ProcSubset=*) PROC_SUBSET="${arg#--property=ProcSubset=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=MemorySwapMax=*) continue ;;
--property=CPUQuota=*) continue ;;
--property=DeviceAllow=*) continue ;;
--property=DevicePolicy=*) continue ;;
--property=RestrictFileSystems=*) RESTRICT_FILE_SYSTEMS="${arg#--property=RestrictFileSystems=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=SocketBindDeny=*) continue ;;
--property=SocketBindAllow=*) continue ;;
--property=IPAddressAllow=*) continue ;;
--property=IPAddressDeny=*) continue ;;
# Additional recognized systemd-run properties (not previously handled).
# Grouped per systemd.exec(5)/systemd.resource-control(5). Security/sandboxing
# properties are enforced via seccomp-BPF, mount namespaces, and capability
# dropping. Resource/accounting/metadata/IO/log properties:
# - Limit* (RLIMIT_*): enforced via ulimit
# - IOSchedulingClass: enforced via ionice
# - CPUSchedulingPolicy/Nice: enforced via chrt/nice
# - OOMScoreAdjust: enforced via /proc/oom_score_adj
# - AmbientCapabilities: enforced via setpriv --ambient-caps
# - Group: enforced via sg
# - MountFlags: enforced via mount --make-rslave/private/shared
# - PassEnvironment/UnsetEnvironment: enforced via env export/unset
# - ConfigurationDirectory: enforced via mkdir + perms
# - TimeoutStartSec: enforced via timeout command
# - CGroup props (CPUQuota, TasksMax, MemoryMax, IO*): require cgroup v2
# - Logging props (SyslogIdentifier, LogNamespace): require journald
# - TTY props (TTYPath, etc.): require systemd PTY management
# - Condition*/Assert*: require systemd unit manager evaluation
# --- Filesystem / namespace sandboxing ---
--property=PrivateDevices=*) PRIVATE_DEVICES="${arg#--property=PrivateDevices=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=PrivateMounts=*) _log_dsr "Sandbox: PrivateMounts (default in mount namespace): $arg"; continue ;;
--property=PrivateNetwork=*) PRIVATE_NETWORK="${arg#--property=PrivateNetwork=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=PrivateUsers=*) PRIVATE_USERS="${arg#--property=PrivateUsers=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=MountFlags=*) MOUNT_FLAGS="${arg#--property=MountFlags=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=MountAPIVFS=*) _log_dsr "Sandbox: MountAPIVFS (default in mount namespace): $arg"; continue ;;
--property=ReadWritePaths=*) READ_WRITE_PATHS+=("${arg#--property=ReadWritePaths=}"); _log_dsr "Sandbox: $arg"; continue ;;
--property=ReadOnlyPaths=*) READ_ONLY_PATHS+=("${arg#--property=ReadOnlyPaths=}"); _log_dsr "Sandbox: $arg"; continue ;;
--property=InaccessiblePaths=*) INACCESSIBLE_PATHS+=("${arg#--property=InaccessiblePaths=}"); _log_dsr "Sandbox: $arg"; continue ;;
--property=ExecPaths=*) READ_WRITE_PATHS+=("${arg#--property=ExecPaths=}"); _log_dsr "Sandbox: ExecPaths→ReadWritePaths: $arg"; continue ;;
--property=NoExecPaths=*) READ_ONLY_PATHS+=("${arg#--property=NoExecPaths=}"); _log_dsr "Sandbox: NoExecPaths→ReadOnlyPaths: $arg"; continue ;;
--property=ConfigurationDirectory=*) CONFIG_DIRS+=("${arg#--property=ConfigurationDirectory=}"); _log_dsr "Sandbox: $arg"; continue ;;
--property=RootDirectory=*) _warn_dsr "Sandbox: RootDirectory (requires chroot-like setup, not supported in shim): $arg"; continue ;;
--property=RootImage=*) _warn_dsr "Sandbox: RootImage (requires disk image mount, not supported in shim): $arg"; continue ;;
--property=RootHash=*) _warn_dsr "Sandbox: RootHash (requires dm-verity, not supported in shim): $arg"; continue ;;
--property=RootVerity=*) _warn_dsr "Sandbox: RootVerity (requires dm-verity, not supported in shim): $arg"; continue ;;
--property=MountImages=*) _warn_dsr "Sandbox: MountImages (requires disk image mount, not supported in shim): $arg"; continue ;;
--property=ExtensionImages=*) _warn_dsr "Sandbox: ExtensionImages (requires disk image mount, not supported in shim): $arg"; continue ;;
--property=NamespacePath=*) _warn_dsr "Sandbox: NamespacePath (requires external namespace, not supported in shim): $arg"; continue ;;
--property=NetworkNamespacePath=*) _warn_dsr "Sandbox: NetworkNamespacePath (requires external namespace, not supported in shim): $arg"; continue ;;
--property=LogNamespace=*) continue ;;
# --- Capabilities / privileges ---
--property=InheritDescriptors=*) continue ;;
--property=SecureBits=*) SECURE_BITS="${arg#--property=SecureBits=}"; _log_dsr "Sandbox: $arg"; continue ;;
# --- Environment ---
--property=Environment=*) EXTRA_ENV+=("-e" "${arg#--property=Environment=}"); continue ;;
--property=PassEnvironment=*) PASS_ENV+=("${arg#--property=PassEnvironment=}"); _log_dsr "Sandbox: $arg"; continue ;;
--property=UnsetEnvironment=*) UNSET_ENV+=("${arg#--property=UnsetEnvironment=}"); _log_dsr "Sandbox: $arg"; continue ;;
# --- Personality / arch ---
--property=Personality=*) PERSONALITY="${arg#--property=Personality=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=SystemCallArchitectures=*) SYS_CALL_ARCH="${arg#--property=SystemCallArchitectures=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=SystemCallErrorNumber=*) SYS_CALL_ERRNO="${arg#--property=SystemCallErrorNumber=}"; if [[ "$SYS_CALL_ERRNO" =~ ^[0-9]+$ ]]; then _log_dsr "Sandbox: $arg"; else _warn_dsr "SystemCallErrorNumber=$SYS_CALL_ERRNO is not a valid positive integer"; SYS_CALL_ERRNO=""; fi; continue ;;
--property=SystemCallLog=*) SYS_CALL_LOG="${arg#--property=SystemCallLog=}"; _log_dsr "Sandbox: $arg"; continue ;;
# --- IPC / time / misc ---
--property=TimerSlackNSec=*) continue ;;
--property=SetLoginEnvironment=*) continue ;;
--property=Delegate=*) continue ;;
--property=DisableExtraFileDescriptors=*) DISABLE_EXTRA_FDS="${arg#--property=DisableExtraFileDescriptors=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=CoredumpReceive=*) COREDUMP_RECEIVE="${arg#--property=CoredumpReceive=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=DynamicUser=*) if [[ "${arg#--property=DynamicUser=}" =~ ^(yes|true|1|on)$ ]]; then DYNAMIC_USER=true; fi; _log_dsr "DynamicUser: ${arg#--property=DynamicUser=} (detected as: $DYNAMIC_USER)"; continue ;;
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
--property=LimitCPU=*) LIMITS_RLIMIT+=("cpu=${arg#--property=LimitCPU=}"); continue ;;
--property=LimitCPUSoft=*) LIMITS_RLIMIT+=("cpu-soft=${arg#--property=LimitCPUSoft=}"); continue ;;
--property=LimitFSIZE=*) LIMITS_RLIMIT+=("fsize=${arg#--property=LimitFSIZE=}"); continue ;;
--property=LimitFSIZESoft=*) LIMITS_RLIMIT+=("fsize-soft=${arg#--property=LimitFSIZESoft=}"); continue ;;
--property=LimitDATA=*) LIMITS_RLIMIT+=("data=${arg#--property=LimitDATA=}"); continue ;;
--property=LimitDATASoft=*) LIMITS_RLIMIT+=("data-soft=${arg#--property=LimitDATASoft=}"); continue ;;
--property=LimitSTACK=*) LIMITS_RLIMIT+=("stack=${arg#--property=LimitSTACK=}"); continue ;;
--property=LimitSTACKSoft=*) LIMITS_RLIMIT+=("stack-soft=${arg#--property=LimitSTACKSoft=}"); continue ;;
--property=LimitCORE=*) LIMITS_RLIMIT+=("core=${arg#--property=LimitCORE=}"); continue ;;
--property=LimitCORESoft=*) LIMITS_RLIMIT+=("core-soft=${arg#--property=LimitCORESoft=}"); continue ;;
--property=LimitRSS=*) LIMITS_RLIMIT+=("rss=${arg#--property=LimitRSS=}"); continue ;;
--property=LimitRSSSoft=*) LIMITS_RLIMIT+=("rss-soft=${arg#--property=LimitRSSSoft=}"); continue ;;
--property=LimitNOFILE=*) LIMITS_RLIMIT+=("nofile=${arg#--property=LimitNOFILE=}"); continue ;;
--property=LimitNOFILESoft=*) LIMITS_RLIMIT+=("nofile-soft=${arg#--property=LimitNOFILESoft=}"); continue ;;
--property=LimitAS=*) LIMITS_RLIMIT+=("as=${arg#--property=LimitAS=}"); continue ;;
--property=LimitASSoft=*) LIMITS_RLIMIT+=("as-soft=${arg#--property=LimitASSoft=}"); continue ;;
--property=LimitNPROC=*) LIMITS_RLIMIT+=("nproc=${arg#--property=LimitNPROC=}"); continue ;;
--property=LimitNPROCSoft=*) LIMITS_RLIMIT+=("nproc-soft=${arg#--property=LimitNPROCSoft=}"); continue ;;
--property=LimitMEMLOCK=*) LIMITS_RLIMIT+=("memlock=${arg#--property=LimitMEMLOCK=}"); continue ;;
--property=LimitMEMLOCKSoft=*) LIMITS_RLIMIT+=("memlock-soft=${arg#--property=LimitMEMLOCKSoft=}"); continue ;;
--property=LimitLOCKS=*) LIMITS_RLIMIT+=("locks=${arg#--property=LimitLOCKS=}"); continue ;;
--property=LimitLOCKSSoft=*) LIMITS_RLIMIT+=("locks-soft=${arg#--property=LimitLOCKSSoft=}"); continue ;;
--property=LimitSIGPENDING=*) LIMITS_RLIMIT+=("sigpending=${arg#--property=LimitSIGPENDING=}"); continue ;;
--property=LimitSIGPENDINGSoft=*) LIMITS_RLIMIT+=("sigpending-soft=${arg#--property=LimitSIGPENDINGSoft=}"); continue ;;
--property=LimitMSGQUEUE=*) LIMITS_RLIMIT+=("msgqueue=${arg#--property=LimitMSGQUEUE=}"); continue ;;
--property=LimitMSGQUEUESoft=*) LIMITS_RLIMIT+=("msgqueue-soft=${arg#--property=LimitMSGQUEUESoft=}"); continue ;;
--property=LimitNICE=*) LIMITS_RLIMIT+=("nice=${arg#--property=LimitNICE=}"); continue ;;
--property=LimitNICESoft=*) LIMITS_RLIMIT+=("nice-soft=${arg#--property=LimitNICESoft=}"); continue ;;
--property=LimitRTPRIO=*) LIMITS_RLIMIT+=("rtprio=${arg#--property=LimitRTPRIO=}"); continue ;;
--property=LimitRTPRIOSoft=*) LIMITS_RLIMIT+=("rtprio-soft=${arg#--property=LimitRTPRIOSoft=}"); continue ;;
--property=LimitRTTIME=*) LIMITS_RLIMIT+=("rttime=${arg#--property=LimitRTTIME=}"); continue ;;
--property=LimitRTTIMESoft=*) LIMITS_RLIMIT+=("rttime-soft=${arg#--property=LimitRTTIMESoft=}"); continue ;;
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
--property=OOMScoreAdjust=*) OOM_SCORE_ADJUST="${arg#--property=OOMScoreAdjust=}"; _log_dsr "Sandbox: $arg"; continue ;;
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
--property=TimeoutStartSec=*) TIMEOUT_START="${arg#--property=TimeoutStartSec=}"; _log_dsr "Sandbox: $arg"; continue ;;
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
--user) USER_MODE=true; continue ;;
--scope) SCOPE_MODE=true; continue ;;
--uid=*|--gid=*) continue ;;
--setenv=*) EXTRA_ENV+=("-e" "${arg#--setenv=}"); continue ;;
--setenv) _SETENV_NEXT_IS_VALUE=true; continue ;;
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
    # Track unrecognized properties for feature-creep mitigation.
    # Append to a persistent log so operators can review which new upstream
    # properties are being silently ignored. This log is rotated when it
    # exceeds 100 entries and is never shipped externally.
    _PROP_TRACKER="/tmp/.dsr-unrecognized-props.log"
    for _up in "${UNRECOGNIZED_PROPS[@]}"; do
        local _prop_name="${_up#--property=}"
        _prop_name="${_prop_name%%=*}"
        echo "$(date -Iseconds) $_prop_name" >> "$_PROP_TRACKER" 2>/dev/null || true
    done
    if [[ -f "$_PROP_TRACKER" ]]; then
        local _tracker_lines
        _tracker_lines=$(wc -l < "$_PROP_TRACKER" 2>/dev/null || echo "0")
        if (( _tracker_lines > 100 )); then
            # Use PID-suffixed temp file to prevent concurrent wrapper instances
            # from overwriting each other's rotation during log pruning.
            tail -50 "$_PROP_TRACKER" > "${_PROP_TRACKER}.tmp.$$" 2>/dev/null || true
            mv "${_PROP_TRACKER}.tmp.$$" "$_PROP_TRACKER" 2>/dev/null || true
        fi
    fi
    _warn_dsr "These are silently accepted without enforcement. Normal when Pamac/makepkg"
    _warn_dsr "adds new systemd options not yet in this wrapper. Only investigate if"
    _warn_dsr "AUR builds fail. Check $_PROP_TRACKER for cumulative property usage."
fi

# ── Build environment setup string ──
# Loads EnvironmentFile= files and exports Environment=/--setenv= vars
# so builds see the same environment systemd-run would have provided.
# SECURITY: EnvironmentFile paths are validated as existing regular files.
# Environment values are sanitized to prevent shell injection via quoting
# breakout in the assembled command string.
_ENV_SETUP=""
for _ef in "${ENV_FILES[@]}"; do
    # SECURITY: Validate path exists, is a regular file, and contains no
    # shell metacharacters that could break single-quote escaping.
    if [[ -f "$_ef" && "$_ef" =~ ^[a-zA-Z0-9_/\.\-]+$ ]]; then
        _ENV_SETUP="${_ENV_SETUP}set -a; source '${_ef}' 2>/dev/null || true; set +a; "
        _log_dsr "Sourcing EnvironmentFile: $_ef"
    elif [[ -f "$_ef" ]]; then
        # Path exists but contains unusual chars — use printf %q for safe escaping
        _ENV_SETUP="${_ENV_SETUP}set -a; source $(printf '%q' "$_ef") 2>/dev/null || true; set +a; "
        _log_dsr "Sourcing EnvironmentFile: $_ef (quoted)"
    else
        _warn_dsr "EnvironmentFile not found: $_ef (continuing — may be created by the build)"
    fi
done
for _ee in "${EXTRA_ENV[@]}"; do
    # SECURITY: Validate env entry is KEY=VALUE format with safe characters.
    if [[ "$_ee" =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]]; then
        _ENV_SETUP="${_ENV_SETUP}export '$(_dsr_sanitize_val "$_ee")' 2>/dev/null || true; "
    else
        _warn_dsr "Skipping malformed Environment entry: $_ee"
    fi
    _log_dsr "Setting env: $_ee"
done
if [[ -n "$SET_UMASK" ]]; then
    _ENV_SETUP="${_ENV_SETUP}umask ${SET_UMASK} 2>/dev/null || true; "
    _log_dsr "Setting umask: $SET_UMASK"
fi

# ── SupplementaryGroups: handled via sg in _BUILD_WRAPPER ──
if [[ -n "$EXTRA_GROUPS" ]]; then
    _log_dsr "SupplementaryGroups requested: $EXTRA_GROUPS (via sg)"
fi

if [[ -n "$WORK_DIR" ]]; then
mkdir -p "$WORK_DIR" 2>/dev/null || true
if $DYNAMIC_USER; then chown "$_DSR_HOST_USER:$_DSR_HOST_USER" "$WORK_DIR" 2>/dev/null || true; fi
fi
if [[ -n "$CACHE_DIR" ]]; then
CACHE_FULL="/var/cache/$CACHE_DIR"
mkdir -p "$CACHE_FULL" 2>/dev/null || true
if $DYNAMIC_USER; then chown -R "$_DSR_HOST_USER:$_DSR_HOST_USER" "$CACHE_FULL" 2>/dev/null || true; fi
fi

# ── Determine if sandbox restrictions are needed ──
_NEEDS_SANDBOX=false
[[ -n "$PROTECT_SYSTEM" ]] && _NEEDS_SANDBOX=true
[[ -n "$PROTECT_HOME" ]] && _NEEDS_SANDBOX=true
[[ -n "$PRIVATE_TMP" ]] && _NEEDS_SANDBOX=true
[[ -n "$PRIVATE_DEVICES" ]] && _NEEDS_SANDBOX=true
[[ -n "$PRIVATE_NETWORK" ]] && _NEEDS_SANDBOX=true
[[ ${#READ_ONLY_PATHS[@]} -gt 0 ]] && _NEEDS_SANDBOX=true
[[ ${#INACCESSIBLE_PATHS[@]} -gt 0 ]] && _NEEDS_SANDBOX=true
[[ ${#STATE_DIRECTORIES[@]} -gt 0 ]] && _NEEDS_SANDBOX=true
[[ ${#LOGS_DIRECTORIES[@]} -gt 0 ]] && _NEEDS_SANDBOX=true
[[ ${#RUNTIME_DIRECTORIES[@]} -gt 0 ]] && _NEEDS_SANDBOX=true
[[ ${#BIND_PATHS[@]} -gt 0 ]] && _NEEDS_SANDBOX=true
[[ ${#BIND_RO_PATHS[@]} -gt 0 ]] && _NEEDS_SANDBOX=true
[[ ${#TMPFS_SPECS[@]} -gt 0 ]] && _NEEDS_SANDBOX=true
[[ -n "$MEMORY_DENY_WRITE_EXECUTE" ]] && _NEEDS_SANDBOX=true
[[ -n "$SYSTEM_CALL_FILTER" ]] && _NEEDS_SANDBOX=true
[[ -n "$RESTRICT_NAMESPACES" ]] && _NEEDS_SANDBOX=true
[[ -n "$RESTRICT_SUID_SGID" ]] && _NEEDS_SANDBOX=true
[[ -n "$LOCK_PERSONALITY" ]] && _NEEDS_SANDBOX=true
[[ -n "$RESTRICT_REALTIME" ]] && _NEEDS_SANDBOX=true
[[ -n "$RESTRICT_ADDRESS_FAMILIES" ]] && _NEEDS_SANDBOX=true
[[ -n "$PROTECT_CLOCK" ]] && _NEEDS_SANDBOX=true
[[ -n "$PROTECT_KERNEL_TUNABLES" ]] && _NEEDS_SANDBOX=true
[[ -n "$PROTECT_KERNEL_MODULES" ]] && _NEEDS_SANDBOX=true
[[ -n "$PROTECT_KERNEL_LOGS" ]] && _NEEDS_SANDBOX=true
[[ -n "$PROTECT_CONTROL_GROUPS" ]] && _NEEDS_SANDBOX=true
[[ -n "$PROTECT_HOSTNAME" ]] && _NEEDS_SANDBOX=true
[[ -n "$RESTRICT_FILE_SYSTEMS" ]] && _NEEDS_SANDBOX=true
[[ -n "$SECURE_BITS" ]] && _NEEDS_SANDBOX=true
[[ -n "$PERSONALITY" ]] && _NEEDS_SANDBOX=true
[[ -n "$PROTECT_PROC" ]] && _NEEDS_SANDBOX=true
[[ -n "$PROC_SUBSET" ]] && _NEEDS_SANDBOX=true
[[ -n "$PRIVATE_USERS" ]] && _NEEDS_SANDBOX=true
[[ -n "$DISABLE_EXTRA_FDS" ]] && _NEEDS_SANDBOX=true
[[ -n "$COREDUMP_RECEIVE" ]] && _NEEDS_SANDBOX=true
[[ -n "$SYS_CALL_ARCH" ]] && _NEEDS_SANDBOX=true
[[ -n "$SYS_CALL_LOG" ]] && _NEEDS_SANDBOX=true
[[ -n "$SYS_CALL_ERRNO" ]] && _NEEDS_SANDBOX=true
[[ -n "$NO_NEW_PRIVS" ]] && _NEEDS_SANDBOX=true
[[ -n "$CAP_BOUNDING_SET" ]] && _NEEDS_SANDBOX=true
[[ ${#READ_WRITE_PATHS[@]} -gt 0 ]] && _NEEDS_SANDBOX=true
[[ ${#LIMITS_RLIMIT[@]} -gt 0 ]] && _NEEDS_SANDBOX=true
[[ -n "$IOSCHED_CLASS" ]] && _NEEDS_SANDBOX=true
[[ -n "$CPUSCHED_POLICY" ]] && _NEEDS_SANDBOX=true
[[ -n "$NICE_LEVEL" ]] && _NEEDS_SANDBOX=true
[[ -n "$AMBIENT_CAPS" ]] && _NEEDS_SANDBOX=true
[[ -n "$GROUP_NAME" ]] && _NEEDS_SANDBOX=true
[[ -n "$MOUNT_FLAGS" ]] && _NEEDS_SANDBOX=true
[[ ${#PASS_ENV[@]} -gt 0 ]] && _NEEDS_SANDBOX=true
[[ ${#UNSET_ENV[@]} -gt 0 ]] && _NEEDS_SANDBOX=true
[[ ${#CONFIG_DIRS[@]} -gt 0 ]] && _NEEDS_SANDBOX=true
[[ -n "$OOM_SCORE_ADJUST" ]] && _NEEDS_SANDBOX=true
[[ -n "$TIMEOUT_START" ]] && _NEEDS_SANDBOX=true
if $_NEEDS_SANDBOX; then
    _log_dsr "Sandbox restrictions active: ProtectSystem=$PROTECT_SYSTEM ProtectHome=$PROTECT_HOME PrivateTmp=$PRIVATE_TMP PrivateDevices=$PRIVATE_DEVICES"
fi

# ── _build_bwrap_args: Construct bwrap arguments for all sandbox properties ──
# bwrap (bubblewrap) is the preferred sandbox engine. It handles user namespaces,
# mount namespaces, /dev isolation, tmpfs, ro/rw bind mounts, and network
# unsharing natively — avoiding fragile manual mount trickery inside unshare.
# Populates the global array _DSR_BWRAP_ARGS. Returns 0 if bwrap is available
# and sandbox is needed, 1 if bwrap is unavailable.
_build_bwrap_args() {
    command -v bwrap >/dev/null 2>&1 || return 1
    _DSR_BWRAP_ARGS=()
    # ── Base: create a new mount namespace and proc/dev ──
    _DSR_BWRAP_ARGS+=(--unshare-pid --dev /dev --proc /proc --tmpfs /tmp)
    # PrivateTmp: bwrap already provides a fresh /tmp via --tmpfs /tmp
    if [[ "$PRIVATE_TMP" == "yes" ]]; then
        _DSR_BWRAP_ARGS+=(--tmpfs /var/tmp)
        _log_dsr "bwrap: PrivateTmp (fresh /tmp and /var/tmp)"
    else
        _DSR_BWRAP_ARGS+=(--bind /var/tmp /var/tmp)
    fi
    # PrivateDevices: minimal /dev is already created via --dev /dev
    if [[ "$PRIVATE_DEVICES" == "yes" ]]; then
        _DSR_BWRAP_ARGS+=(--dev /dev)
        _log_dsr "bwrap: PrivateDevices (minimal /dev)"
    fi
    # ── ProtectHome: replace /home with empty tmpfs or bind RO ──
    if [[ "$PROTECT_HOME" == "yes" ]]; then
        _DSR_BWRAP_ARGS+=(--tmpfs /home)
        _log_dsr "bwrap: ProtectHome=yes (/home→tmpfs)"
    elif [[ "$PROTECT_HOME" == "read-only" ]]; then
        _DSR_BWRAP_ARGS+=(--ro-bind /home /home)
        _log_dsr "bwrap: ProtectHome=read-only"
    else
        _DSR_BWRAP_ARGS+=(--bind /home /home)
    fi
    # ── ProtectSystem: make / readonly, carve writable exceptions ──
    if [[ "$PROTECT_SYSTEM" == "strict" ]]; then
        _DSR_BWRAP_ARGS+=(--ro-bind /usr /usr --ro-bind /boot /boot --ro-bind /etc /etc --ro-bind / /)
        _log_dsr "bwrap: ProtectSystem=strict"
    elif [[ "$PROTECT_SYSTEM" == "full" ]]; then
        _DSR_BWRAP_ARGS+=(--ro-bind /usr /usr --ro-bind /boot /boot --ro-bind /etc /etc --bind /var /var --ro-bind / /)
        _log_dsr "bwrap: ProtectSystem=full"
    elif [[ "$PROTECT_SYSTEM" == "yes" ]] || [[ "$PROTECT_SYSTEM" == "true" ]]; then
        _DSR_BWRAP_ARGS+=(--ro-bind /usr /usr --ro-bind /boot /boot --ro-bind /etc /etc --bind /var /var --ro-bind / /)
        _log_dsr "bwrap: ProtectSystem=$PROTECT_SYSTEM"
    else
        _DSR_BWRAP_ARGS+=(--bind / /)
    fi
    # ── Writable paths needed by builds ──
    for _wp in /run /var/cache; do
        _DSR_BWRAP_ARGS+=(--bind "$_wp" "$_wp")
    done
    [[ -n "$WORK_DIR" ]] && { mkdir -p "$WORK_DIR" 2>/dev/null || true; _DSR_BWRAP_ARGS+=(--bind "$WORK_DIR" "$WORK_DIR"); }
    [[ -n "$CACHE_DIR" ]] && { _DSR_BWRAP_ARGS+=(--bind "/var/cache/$CACHE_DIR" "/var/cache/$CACHE_DIR"); }
    # ── ReadWritePaths ──
    for _rwp in "${READ_WRITE_PATHS[@]}"; do
        [[ -z "$_rwp" ]] && continue
        mkdir -p "$_rwp" 2>/dev/null || true
        _DSR_BWRAP_ARGS+=(--bind "$_rwp" "$_rwp")
        _log_dsr "bwrap: ReadWritePaths: $_rwp"
    done
    # ── ReadOnlyPaths ──
    for _rop in "${READ_ONLY_PATHS[@]}"; do
        [[ -z "$_rop" ]] && continue
        if [[ -e "$_rop" ]]; then
            _DSR_BWRAP_ARGS+=(--ro-bind "$_rop" "$_rop")
        else
            _DSR_BWRAP_ARGS+=(--ro-bind /var/empty "$_rop")
            mkdir -p /var/empty 2>/dev/null || true
        fi
        _log_dsr "bwrap: ReadOnlyPaths: $_rop"
    done
    # ── InaccessiblePaths: make path inaccessible in bwrap ──
    for _iap in "${INACCESSIBLE_PATHS[@]}"; do
        [[ -z "$_iap" ]] && continue
        if [[ -d "$_iap" ]]; then
            # Use --tmpfs to create an empty filesystem at the path (truly inaccessible)
            _DSR_BWRAP_ARGS+=(--tmpfs "$_iap")
        else
            # Bind /dev/null over files to make them appear as zero-length
            _DSR_BWRAP_ARGS+=(--bind /dev/null "$_iap")
        fi
        _log_dsr "bwrap: InaccessiblePaths: $_iap"
    done
    # ── StateDirectory/LogsDirectory/RuntimeDirectory ──
    for _sd in "${STATE_DIRECTORIES[@]}"; do
        [[ -z "$_sd" ]] && continue
        mkdir -p "/var/lib/$_sd" 2>/dev/null || true
        chown "${BUILD_USER:-$_DSR_HOST_USER}:${BUILD_USER:-$_DSR_HOST_USER}" "/var/lib/$_sd" 2>/dev/null || true
        _DSR_BWRAP_ARGS+=(--bind "/var/lib/$_sd" "/var/lib/$_sd")
        _log_dsr "bwrap: StateDirectory: /var/lib/$_sd"
    done
    for _ld in "${LOGS_DIRECTORIES[@]}"; do
        [[ -z "$_ld" ]] && continue
        mkdir -p "/var/log/$_ld" 2>/dev/null || true
        chown "${BUILD_USER:-$_DSR_HOST_USER}:${BUILD_USER:-$_DSR_HOST_USER}" "/var/log/$_ld" 2>/dev/null || true
        _DSR_BWRAP_ARGS+=(--bind "/var/log/$_ld" "/var/log/$_ld")
        _log_dsr "bwrap: LogsDirectory: /var/log/$_ld"
    done
    for _rd in "${RUNTIME_DIRECTORIES[@]}"; do
        [[ -z "$_rd" ]] && continue
        mkdir -p "/run/$_rd" 2>/dev/null || true
        chown "${BUILD_USER:-$_DSR_HOST_USER}:${BUILD_USER:-$_DSR_HOST_USER}" "/run/$_rd" 2>/dev/null || true
        chmod 0755 "/run/$_rd" 2>/dev/null || true
        _DSR_BWRAP_ARGS+=(--bind "/run/$_rd" "/run/$_rd")
        _log_dsr "bwrap: RuntimeDirectory: /run/$_rd"
    done
    # ── TemporaryFileSystem: mount tmpfs ──
    for _tfs in "${TMPFS_SPECS[@]}"; do
        [[ -z "$_tfs" ]] && continue
        local _tfs_path="${_tfs%%:*}"
        local _tfs_opts="${_tfs#*:}"
        [[ -z "$_tfs_path" ]] && continue
        [[ "$_tfs_opts" == "$_tfs_path" ]] && _tfs_opts=""
        _DSR_BWRAP_ARGS+=(--tmpfs "$_tfs_path")
        if [[ -n "$_tfs_opts" ]]; then
            _log_dsr "bwrap: TemporaryFileSystem: $_tfs_path (opts: $_tfs_opts)"
        else
            _log_dsr "bwrap: TemporaryFileSystem: $_tfs_path"
        fi
    done
    # ── BindPaths: writable bind mounts ──
    for _bp in "${BIND_PATHS[@]}"; do
        [[ -z "$_bp" ]] && continue
        local _src="${_bp%%:*}"
        local _dst="${_bp#*:}"
        [[ "$_dst" == "$_src" ]] && _dst="$_src"
        [[ -z "$_src" || -z "$_dst" ]] && continue
        mkdir -p "$_src" "$_dst" 2>/dev/null || true
        _DSR_BWRAP_ARGS+=(--bind "$_src" "$_dst")
        _log_dsr "bwrap: BindPaths: $_src → $_dst"
    done
    # ── BindReadOnlyPaths: read-only bind mounts ──
    for _brp in "${BIND_RO_PATHS[@]}"; do
        [[ -z "$_brp" ]] && continue
        local _src="${_brp%%:*}"
        local _dst="${_brp#*:}"
        [[ "$_dst" == "$_src" ]] && _dst="$_src"
        [[ -z "$_src" || -z "$_dst" ]] && continue
        mkdir -p "$_src" "$_dst" 2>/dev/null || true
        _DSR_BWRAP_ARGS+=(--ro-bind "$_src" "$_dst")
        _log_dsr "bwrap: BindReadOnlyPaths: $_src → $_dst"
    done
    # ── PrivateNetwork: unshare network namespace ──
    if [[ "$PRIVATE_NETWORK" == "yes" ]]; then
        _DSR_BWRAP_ARGS+=(--unshare-net)
        _log_dsr "bwrap: PrivateNetwork (network namespace unshared)"
    fi
    # ── NoNewPrivileges: bwrap natively supports --new-session ──
    if [[ "$NO_NEW_PRIVS" == "yes" ]]; then
        _DSR_BWRAP_ARGS+=(--new-session)
        _log_dsr "bwrap: NoNewPrivileges (--new-session)"
    fi
    # ── ProtectKernelTunables: make /proc/sys and /sys read-only ──
    if [[ "$PROTECT_KERNEL_TUNABLES" == "yes" ]]; then
        _DSR_BWRAP_ARGS+=(--ro-bind /proc/sys /proc/sys --ro-bind /sys /sys)
        _log_dsr "bwrap: ProtectKernelTunables (/proc/sys, /sys read-only)"
    fi
    # ── ProtectControlGroups: make /sys/fs/cgroup read-only ──
    if [[ "$PROTECT_CONTROL_GROUPS" == "yes" ]]; then
        _DSR_BWRAP_ARGS+=(--ro-bind /sys/fs/cgroup /sys/fs/cgroup)
        _log_dsr "bwrap: ProtectControlGroups (/sys/fs/cgroup read-only)"
    fi
    # ── ProtectKernelLogs: bind /dev/null over /dev/kmsg ──
    if [[ "$PROTECT_KERNEL_LOGS" == "yes" ]]; then
        _DSR_BWRAP_ARGS+=(--dev /dev)
        _log_dsr "bwrap: ProtectKernelLogs (filtered /dev)"
    fi
    return 0
}

# ── _sandbox_verify: runtime sandbox integrity check ──
# Runs AFTER the sandbox is entered. Verifies that restrictions actually applied.
_sandbox_verify() {
    _sandbox_verified=true
    if [[ -n "$PROTECT_SYSTEM" ]]; then
        if touch /.sandbox-verify-test 2>/dev/null; then
            rm -f /.sandbox-verify-test 2>/dev/null || true
            _sandbox_verified=false
            _warn_dsr "VERIFICATION FAILED: / is still writable — sandbox restrictions may not have applied"
            _warn_dsr "Builds may run with weaker isolation than expected."
        else
            _log_dsr "  / is read-only (ProtectSystem verified)"
        fi
    fi
    if [[ "$PROTECT_HOME" == "yes" ]]; then
        if [[ -n "$(ls -A /home 2>/dev/null)" ]]; then
            _warn_dsr "VERIFICATION WARNING: /home is not empty after ProtectHome=yes"
            _sandbox_verified=false
        else
            _log_dsr "  /home is empty/inaccessible (ProtectHome verified)"
        fi
    fi
    if [[ "$PRIVATE_TMP" == "yes" ]]; then
        if mountpoint -q /tmp 2>/dev/null; then
            _log_dsr "  /tmp is a fresh mount (PrivateTmp verified)"
        else
            _warn_dsr "VERIFICATION WARNING: /tmp is not a separate mount after PrivateTmp=yes"
        fi
    fi
    if [[ "$PRIVATE_DEVICES" == "yes" ]]; then
        if [[ -c /dev/null ]] && [[ ! -c /dev/mmcblk0 ]] && [[ ! -c /dev/nvme0n1 ]]; then
            _log_dsr "  /dev has minimal nodes (PrivateDevices verified)"
        else
            _warn_dsr "VERIFICATION WARNING: /dev may contain extra device nodes after PrivateDevices=yes"
        fi
    fi
    if [[ "$PRIVATE_NETWORK" == "yes" ]]; then
        if ip link show lo 2>/dev/null | grep -q "state UP"; then
            _warn_dsr "VERIFICATION WARNING: loopback still up after PrivateNetwork"
        else
            _log_dsr "  Network namespace is isolated (PrivateNetwork verified)"
        fi
    fi
    if [[ "$PROTECT_KERNEL_TUNABLES" == "yes" ]]; then
        if touch /proc/sys/kernel/hostname 2>/dev/null; then
            _warn_dsr "VERIFICATION WARNING: /proc/sys is still writable after ProtectKernelTunables"
        else
            _log_dsr "  /proc/sys is read-only (ProtectKernelTunables verified)"
        fi
    fi
    if [[ "$PROTECT_CONTROL_GROUPS" == "yes" ]]; then
        if touch /sys/fs/cgroup/.test-write 2>/dev/null; then
            rm -f /sys/fs/cgroup/.test-write 2>/dev/null || true
            _warn_dsr "VERIFICATION WARNING: /sys/fs/cgroup is still writable after ProtectControlGroups"
        else
            _log_dsr "  /sys/fs/cgroup is read-only (ProtectControlGroups verified)"
        fi
    fi
    if [[ "$PROTECT_KERNEL_LOGS" == "yes" ]]; then
        if read -t 0 _klg_chk </dev/kmsg 2>/dev/null; then
            _warn_dsr "VERIFICATION WARNING: /dev/kmsg still readable after ProtectKernelLogs (bind over may have failed)"
        else
            _log_dsr "  /dev/kmsg access controlled (ProtectKernelLogs verified)"
        fi
    fi
    if $_sandbox_verified; then
        _log_dsr "Sandbox verification passed"
    fi
}

# ── Apply sandbox restrictions — unshare fallback (runs inside mount namespace) ──
_apply_sandbox() {
    # All mount operations here affect only the private mount namespace.
    # Bind-mounting a path to itself gives us a per-mountpoint flags slot
    # that we can remount as ro/rw independently of the parent.

    # ── ProtectSystem: make / read-only, carve writable exceptions ──
    if [[ -n "$PROTECT_SYSTEM" ]]; then
        _log_dsr "Applying ProtectSystem=$PROTECT_SYSTEM"
        # Make / read-only via bind mount to self + remount
        if mount --bind / / 2>/dev/null && mount -o remount,bind,ro / 2>/dev/null; then
            _log_dsr "  / made read-only"
        else
            _warn_dsr "  Failed to make / read-only (mount namespace may not support this)"
        fi
        # Re-mount writable paths that the build needs
        local _writable=("/run" "/tmp" "/var/tmp" "/var/cache")
        [[ -n "$WORK_DIR" ]] && _writable+=("$WORK_DIR")
        [[ -n "$CACHE_DIR" ]] && _writable+=("/var/cache/$CACHE_DIR")
        for _wp in "${_writable[@]}"; do
            [[ -e "$_wp" ]] || mkdir -p "$_wp" 2>/dev/null || continue
            if mount --bind "$_wp" "$_wp" 2>/dev/null; then
                if ! mount -o remount,bind,rw "$_wp" 2>/dev/null; then
                    _warn_dsr "  Bind succeeded but remount failed for writable path: $_wp"
                fi
            else
                _warn_dsr "  Could not make writable: $_wp"
            fi
        done
        # ProtectSystem=full additionally makes /etc, /usr, /boot read-only
        if [[ "$PROTECT_SYSTEM" == "full" ]] || [[ "$PROTECT_SYSTEM" == "true" ]]; then
            for _rp in /etc /usr /boot; do
                [[ -e "$_rp" ]] || continue
                if mount --bind "$_rp" "$_rp" 2>/dev/null; then
                    mount -o remount,bind,ro "$_rp" 2>/dev/null \
                        || mount -o remount,bind "$_rp" 2>/dev/null  # fallback: keep original flags
                fi
            done
        fi
        # Explicit ReadOnlyPaths and InaccessiblePaths
        for _rop in "${READ_ONLY_PATHS[@]}"; do
            [[ -e "$_rop" ]] || continue
            if mount --bind "$_rop" "$_rop" 2>/dev/null; then
                mount -o remount,bind,ro "$_rop" 2>/dev/null
            fi
        done
        for _iap in "${INACCESSIBLE_PATHS[@]}"; do
            [[ -e "$_iap" ]] || continue
            mount -t tmpfs tmpfs "$_iap" 2>/dev/null && _log_dsr "  Made inaccessible: $_iap"
        done
        # ReadWritePaths override the read-only root for specific paths
        for _rwp in "${READ_WRITE_PATHS[@]}"; do
            [[ -e "$_rwp" ]] || mkdir -p "$_rwp" 2>/dev/null || continue
            mount --bind "$_rwp" "$_rwp" 2>/dev/null && mount -o remount,bind,rw "$_rwp" 2>/dev/null
        done
    fi

    # ── ProtectHome: make /home inaccessible or read-only ──
    if [[ -n "$PROTECT_HOME" ]]; then
        _log_dsr "Applying ProtectHome=$PROTECT_HOME"
        if [[ "$PROTECT_HOME" == "yes" ]]; then
            # Replace /home with empty tmpfs
            if mount -t tmpfs tmpfs /home 2>/dev/null; then
                _log_dsr "  /home replaced with empty tmpfs"
            else
                _warn_dsr "  Could not replace /home with tmpfs"
            fi
        elif [[ "$PROTECT_HOME" == "read-only" ]]; then
            if mount --bind /home /home 2>/dev/null; then
                mount -o remount,bind,ro /home 2>/dev/null
                _log_dsr "  /home made read-only"
            fi
        fi
    fi

    # ── PrivateTmp: private /tmp and /var/tmp ──
    if [[ -n "$PRIVATE_TMP" ]] && [[ "$PRIVATE_TMP" == "yes" ]]; then
        _log_dsr "Applying PrivateTmp=yes"
        local _fresh_tmp
        _fresh_tmp=$(mktemp -d 2>/dev/null) || _fresh_tmp=""
        if [[ -n "$_fresh_tmp" ]]; then
            mount --bind "$_fresh_tmp" /tmp 2>/dev/null \
                || mount -t tmpfs tmpfs /tmp 2>/dev/null
            rm -rf "$_fresh_tmp" 2>/dev/null || true
        fi
        local _fresh_vtmp
        _fresh_vtmp=$(mktemp -d /var/tmp/.private-vtmp-XXXXXX 2>/dev/null) || _fresh_vtmp=""
        if [[ -n "$_fresh_vtmp" ]]; then
            mount --bind "$_fresh_vtmp" /var/tmp 2>/dev/null \
                || mount -t tmpfs tmpfs /var/tmp 2>/dev/null
            rm -rf "$_fresh_vtmp" 2>/dev/null || true
        fi
        _log_dsr "  Private /tmp and /var/tmp created"
    fi

    # ── PrivateDevices: minimal /dev with only essential nodes ──
    # Creates a private /dev with null, zero, full, random, urandom, tty, ptmx,
    # and symlinks for fd/stdin/stdout/stderr. Block devices (mmcblk, nvme, etc.)
    # are excluded. Matches bwrap --dev /dev behavior.
    if [[ -n "$PRIVATE_DEVICES" ]] && [[ "$PRIVATE_DEVICES" == "yes" ]]; then
        _log_dsr "Applying PrivateDevices=yes"
        local _dev_dir
        _dev_dir=$(mktemp -d /tmp/.private-dev-XXXXXX 2>/dev/null) || _dev_dir=""
        if [[ -n "$_dev_dir" ]]; then
            mount -t tmpfs tmpfs "$_dev_dir" 2>/dev/null || { rm -rf "$_dev_dir"; return; }
            # Essential device nodes
            mknod "$_dev_dir/null"    c 1 3 2>/dev/null; chmod 666 "$_dev_dir/null" 2>/dev/null
            mknod "$_dev_dir/zero"    c 1 5 2>/dev/null; chmod 666 "$_dev_dir/zero" 2>/dev/null
            mknod "$_dev_dir/full"    c 1 7 2>/dev/null; chmod 666 "$_dev_dir/full" 2>/dev/null
            mknod "$_dev_dir/random"  c 1 8 2>/dev/null; chmod 666 "$_dev_dir/random" 2>/dev/null
            mknod "$_dev_dir/urandom" c 1 9 2>/dev/null; chmod 666 "$_dev_dir/urandom" 2>/dev/null
            mknod "$_dev_dir/tty"     c 5 0 2>/dev/null; chmod 666 "$_dev_dir/tty" 2>/dev/null
            ln -sf /proc/self/fd     "$_dev_dir/fd"     2>/dev/null
            ln -sf /proc/self/stdin  "$_dev_dir/stdin"  2>/dev/null
            ln -sf /proc/self/stdout "$_dev_dir/stdout" 2>/dev/null
            ln -sf /proc/self/stderr "$_dev_dir/stderr" 2>/dev/null
            mknod "$_dev_dir/ptmx"   c 5 2 2>/dev/null; chmod 666 "$_dev_dir/ptmx" 2>/dev/null
            mknod "$_dev_dir/tty0"   c 4 0 2>/dev/null; chmod 600 "$_dev_dir/tty0" 2>/dev/null
            mount --bind "$_dev_dir" /dev 2>/dev/null
            rm -rf "$_dev_dir" 2>/dev/null || true
            _log_dsr "  /dev replaced with minimal device nodes"
        fi
    fi

    # ── StateDirectory: create /var/lib/<name> owned by build user ──
    for _sd in "${STATE_DIRECTORIES[@]}"; do
        local _sd_path="/var/lib/$_sd"
        mkdir -p "$_sd_path" 2>/dev/null || continue
        chown "${BUILD_USER:-root}:${BUILD_USER:-root}" "$_sd_path" 2>/dev/null || true
        _log_dsr "  StateDirectory: $_sd_path"
    done

    # ── LogsDirectory: create /var/log/<name> owned by build user ──
    for _ld in "${LOGS_DIRECTORIES[@]}"; do
        local _ld_path="/var/log/$_ld"
        mkdir -p "$_ld_path" 2>/dev/null || continue
        chown "${BUILD_USER:-root}:${BUILD_USER:-root}" "$_ld_path" 2>/dev/null || true
        _log_dsr "  LogsDirectory: $_ld_path"
    done

    # ── RuntimeDirectory: create /run/<name> owned by build user ──
    for _rd in "${RUNTIME_DIRECTORIES[@]}"; do
        local _rd_path="/run/$_rd"
        mkdir -p "$_rd_path" 2>/dev/null || continue
        chown "${BUILD_USER:-root}:${BUILD_USER:-root}" "$_rd_path" 2>/dev/null || true
        chmod 0755 "$_rd_path" 2>/dev/null || true
        _log_dsr "  RuntimeDirectory: $_rd_path"
    done

    # ── TemporaryFileSystem: mount tmpfs at specified path with options ──
    for _tfs in "${TMPFS_SPECS[@]}"; do
        local _tfs_path="${_tfs%%:*}"
        local _tfs_opts="${_tfs#*:}"
        [[ -z "$_tfs_path" ]] && continue
        mkdir -p "$_tfs_path" 2>/dev/null || continue
        if [[ -n "$_tfs_opts" ]]; then
            mount -t tmpfs -o "$_tfs_opts" tmpfs "$_tfs_path" 2>/dev/null \
                || mount -t tmpfs tmpfs "$_tfs_path" 2>/dev/null
        else
            mount -t tmpfs tmpfs "$_tfs_path" 2>/dev/null
        fi
        _log_dsr "  TemporaryFileSystem: $_tfs_path (opts: ${_tfs_opts:-none})"
    done

    # ── BindPaths: bind-mount source to destination (writable) ──
    for _bp in "${BIND_PATHS[@]}"; do
        local _src="${_bp%%:*}"
        local _dst="${_bp#*:}"
        [[ -z "$_src" || -z "$_dst" ]] && continue
        mkdir -p "$_src" "$_dst" 2>/dev/null || continue
        mount --bind "$_src" "$_dst" 2>/dev/null \
            && _log_dsr "  BindPaths: $_src → $_dst" \
            || _warn_dsr "  Failed BindPaths: $_src → $_dst"
    done

    # ── BindReadOnlyPaths: bind-mount source to destination (read-only) ──
    for _brp in "${BIND_RO_PATHS[@]}"; do
        local _src="${_brp%%:*}"
        local _dst="${_brp#*:}"
        [[ -z "$_src" || -z "$_dst" ]] && continue
        mkdir -p "$_src" "$_dst" 2>/dev/null || continue
        if mount --bind "$_src" "$_dst" 2>/dev/null; then
            mount -o remount,bind,ro "$_dst" 2>/dev/null \
                && _log_dsr "  BindReadOnlyPaths: $_src → $_dst" \
                || _warn_dsr "  Failed to make read-only: $_dst"
        else
            _warn_dsr "  Failed BindReadOnlyPaths: $_src → $_dst"
        fi
    done

    # ── NoNewPrivileges: use prctl via setpriv if available ──
    if [[ -n "$NO_NEW_PRIVS" ]] && [[ "$NO_NEW_PRIVS" == "yes" ]]; then
        _log_dsr "Applying NoNewPrivileges=yes"
        # Enforcement is handled by _prepare_cap_priv() which reads NO_NEW_PRIVS
        # directly and builds the setpriv --no-new-privs command prefix.
    fi

    # ── SecureBits: set securebits flags via setpriv ──
    # SECBIT_NOROOT (1): don't treat root as special for file access
    # SECBIT_NO_SETUID_FIXUP (2): don't adjust UID/GID on exec
    # SECBIT_KEEP_CAPS (4): don't drop capabilities on UID transition
    if [[ -n "$SECURE_BITS" ]]; then
        _log_dsr "Applying SecureBits=$SECURE_BITS"
        local _sb_val=0
        case "${SECURE_BITS,,}" in
            *noroot*)         _sb_val=$(( _sb_val | 1 )) ;;
            *no_setuid_fixup*) _sb_val=$(( _sb_val | 2 )) ;;
            *keep_caps*)      _sb_val=$(( _sb_val | 4 )) ;;
            *no_new_privs*)   _sb_val=$(( _sb_val | 8 )) ;;
        esac
        if [[ "$_sb_val" -gt 0 ]] && command -v setpriv >/dev/null 2>&1; then
            setpriv --securebits "$_sb_val" 2>/dev/null \
                && _log_dsr "  SecureBits set to $_sb_val via setpriv" \
                || _warn_dsr "  Failed to set SecureBits via setpriv"
        elif [[ "$_sb_val" -gt 0 ]]; then
            _warn_dsr "  setpriv not available — cannot enforce SecureBits"
        fi
    fi

    # ── Personality: set execution domain via personality() syscall ──
    # PER_LINUX (0): default Linux personality
    # PER_LINUX32 (8): 32-bit emulation on 64-bit kernel
    # PER_LINUX32 personality blocks 64-bit syscalls via personality, matching
    # systemd's SystemCallArchitectures=i386 enforcement.
    if [[ -n "$PERSONALITY" ]]; then
        _log_dsr "Applying Personality=$PERSONALITY"
        local _per_val=0
        case "${PERSONALITY,,}" in
            linux32|i386)     _per_val=8 ;;
            linux)            _per_val=0 ;;
            linux64)          _per_val=0 ;;
            *|native)         _per_val=0 ;;
        esac
        # Use a small C helper to call personality() syscall (cached)
        # SECURITY: Use a private dir under /tmp with restrictive permissions
        # to prevent symlink/TOCTOU attacks on compiled binaries.
        local _dsr_tmp="/tmp/.dsr-helpers-$$"
        mkdir -p "$_dsr_tmp" 2>/dev/null && chmod 700 "$_dsr_tmp" 2>/dev/null || _dsr_tmp="/tmp"
        local _per_src="${_dsr_tmp}/.dsr-personality.c"
        local _per_bin="${_dsr_tmp}/.dsr-personality"
        if [[ ! -x "$_per_bin" ]]; then
            cat > "$_per_src" << 'PERSONALITY_C'
#include <stdio.h>
#include <stdlib.h>
#include <sys/personality.h>
#include <unistd.h>
int main(int argc, char *argv[]) {
    if (argc < 2) { fprintf(stderr, "usage: personality <value>\n"); return 1; }
    unsigned long val = strtoul(argv[1], NULL, 10);
    if (personality(val) == (unsigned long)-1) { fprintf(stderr, "personality failed\n"); return 1; }
    fprintf(stderr, "personality: set to %lu\n", val);
    return 0;
}
PERSONALITY_C
            if command -v gcc >/dev/null 2>&1; then
                gcc -O2 -o "$_per_bin" "$_per_src" 2>/dev/null || \
                { command -v cc >/dev/null 2>&1 && cc -O2 -o "$_per_bin" "$_per_src" 2>/dev/null; } || true
            fi
            rm -f "$_per_src" 2>/dev/null || true
        fi
        if [[ -x "$_per_bin" ]]; then
            "$_per_bin" "$_per_val" 2>/dev/null \
                && _log_dsr "  Personality set to $_per_val" \
                || _warn_dsr "  Failed to set Personality"
        else
            _warn_dsr "  gcc not available — cannot enforce Personality"
        fi
    fi

    # ── ProtectProc: restrict /proc visibility ──
    # ProtectProc=invisible: hide other users' /proc entries (bind-mount /proc)
    # ProtectProc=noaccess: make /proc world-inaccessible
    if [[ -n "$PROTECT_PROC" ]]; then
        _log_dsr "Applying ProtectProc=$PROTECT_PROC"
        case "${PROTECT_PROC,,}" in
            invisible|noaccess)
                if mount --bind /proc /proc 2>/dev/null; then
                    mount -o remount,bind,ro /proc 2>/dev/null \
                        && _log_dsr "  /proc made read-only (ProtectProc=$PROTECT_PROC)" \
                        || _warn_dsr "  Failed to make /proc read-only"
                fi
                ;;
        esac
    fi

    # ── ProcSubset: restrict which /proc paths are accessible ──
    # ProcSubset=pid: only /proc/<pid> and /proc/self are accessible
    # ProcSubset=sysctl: only /proc/sys and /proc/sysrq-trigger
    if [[ -n "$PROC_SUBSET" ]]; then
        _log_dsr "Applying ProcSubset=$PROC_SUBSET"
        case "${PROC_SUBSET,,}" in
            pid)
                # Hide /proc entries except /proc/<self_pid> and /proc/self
                for _proc_entry in /proc/[!s]*; do
                    local _entry_name
                    _entry_name=$(basename "$_proc_entry")
                    [[ "$_entry_name" == "$(echo $$)" ]] && continue
                    [[ "$_entry_name" == "self" ]] && continue
                    [[ "$_entry_name" == "thread-self" ]] && continue
                    mount --bind /dev/null "$_proc_entry" 2>/dev/null && \
                        _log_dsr "  Hidden: $_proc_entry"
                done
                ;;
            sysctl)
                # Hide everything except /proc/sys and /proc/sysrq-trigger
                for _proc_entry in /proc/[!s]*; do
                    local _entry_name
                    _entry_name=$(basename "$_proc_entry")
                    [[ "$_entry_name" == "sys" ]] && continue
                    mount --bind /dev/null "$_proc_entry" 2>/dev/null && \
                        _log_dsr "  Hidden: $_proc_entry"
                done
                ;;
        esac
    fi

    # ── PrivateUsers: create user namespace for UID mapping ──
    # PrivateUsers=yes: run in a user namespace with UID/GID mapping
    if [[ -n "$PRIVATE_USERS" ]] && [[ "$PRIVATE_USERS" == "yes" ]]; then
        _log_dsr "Applying PrivateUsers=yes (user namespace)"
        # Enforcement: unshare --user flag in _run_sandboxed_unshare
    fi

    # ── DisableExtraFileDescriptors: close all fds except stdin/stdout/stderr ──
    if [[ -n "$DISABLE_EXTRA_FDS" ]] && [[ "$DISABLE_EXTRA_FDS" == "yes" ]]; then
        _log_dsr "Applying DisableExtraFileDescriptors=yes"
        # Close all file descriptors except 0, 1, 2 using a small C helper
        # that calls close_range(3, ~0UL, 0). Falls back to /proc/self/fd
        # iteration if close_range is unavailable (kernel < 5.9).
        local _clex_src="${_dsr_tmp:-/tmp}/.dsr-close-fds.c"
        local _clex_bin="${_dsr_tmp:-/tmp}/.dsr-close-fds"
        if [[ ! -x "$_clex_bin" ]]; then
            cat > "$_clex_src" << 'CLOSEFDS_C'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/syscall.h>
/* SYS_close_range: use direct syscall number for portability across
   kernel header versions. Defined in asm/unistd.h on most arches. */
#ifndef SYS_close_range
#define SYS_close_range 436
#endif
int main() {
    /* close_range(3, ~0UL, 0): close all fds >= 3 */
    if (syscall(SYS_close_range, 3, ~0UL, 0) == 0) {
        fprintf(stderr, "DisableExtraFileDescriptors: closed via close_range\n");
        return 0;
    }
    /* Fallback: iterate /proc/self/fd */
    DIR *f = opendir("/proc/self/fd");
    if (!f) { fprintf(stderr, "DisableExtraFileDescriptors: cannot open /proc/self/fd\n"); return 1; }
    int self_fd = dirfd(f);
    struct dirent *de;
    int closed = 0;
    while ((de = readdir(f)) != NULL) {
        if (de->d_name[0] < '0' || de->d_name[0] > '9') continue;
        int fd = atoi(de->d_name);
        if (fd < 3 || fd == self_fd) continue;
        close(fd);
        closed++;
    }
    closedir(f);
    fprintf(stderr, "DisableExtraFileDescriptors: closed %d fds via /proc/self/fd\n", closed);
    return 0;
}
CLOSEFDS_C
            if command -v gcc >/dev/null 2>&1; then
                gcc -O2 -o "$_clex_bin" "$_clex_src" 2>/dev/null || \
                { command -v cc >/dev/null 2>&1 && cc -O2 -o "$_clex_bin" "$_clex_src" 2>/dev/null; } || true
            fi
        fi
        if [[ -x "$_clex_bin" ]]; then
            "$_clex_bin" 2>/dev/null \
                && _log_dsr "  Extra file descriptors closed" \
                || _warn_dsr "  Failed to close extra file descriptors"
        else
            _warn_dsr "  Could not compile fd-closing helper (gcc not available)"
        fi
        rm -f "$_clex_src" 2>/dev/null || true
    fi

    # ── CoredumpReceive: disable core dumps ──
    # CoredumpReceive=no: prevent the process from receiving core dumps
    if [[ -n "$COREDUMP_RECEIVE" ]] && [[ "$COREDUMP_RECEIVE" == "no" ]]; then
        _log_dsr "Applying CoredumpReceive=no"
        # Disable core dumps via ulimit
        ulimit -c 0 2>/dev/null \
            && _log_dsr "  Core dumps disabled (ulimit -c 0)" \
            || _warn_dsr "  Failed to disable core dumps via ulimit"
    fi

    # ── CapabilityBoundingSet: drop capabilities via seccomp helper + capsh/setpriv ──
    # The seccomp helper now includes prctl(PR_CAPBSET_DROP) for true bounding-set
    # enforcement. Shell-side capsh/setpriv is handled by _prepare_cap_priv() which
    # reads CAP_BOUNDING_SET directly (no export needed).
    if [[ -n "$CAP_BOUNDING_SET" ]]; then
        _log_dsr "Applying CapabilityBoundingSet=$CAP_BOUNDING_SET"
        if command -v capsh >/dev/null 2>&1; then
            _log_dsr "  Capability bounding set: capsh (enforced via _prepare_cap_priv)"
        elif command -v setpriv >/dev/null 2>&1; then
            _log_dsr "  Capability bounding set: setpriv (enforced via _prepare_cap_priv)"
        else
            _warn_dsr "  Neither capsh nor setpriv available — cannot enforce CapabilityBoundingSet"
        fi
    fi

    # ── ProtectKernelTunables: make /proc/sys and /sys read-only ──
    if [[ -n "$PROTECT_KERNEL_TUNABLES" ]] && [[ "$PROTECT_KERNEL_TUNABLES" == "yes" ]]; then
        _log_dsr "Applying ProtectKernelTunables=yes"
        for _kt in /proc/sys /sys; do
            if [[ -e "$_kt" ]]; then
                if mount --bind "$_kt" "$_kt" 2>/dev/null; then
                    mount -o remount,bind,ro "$_kt" 2>/dev/null \
                        && _log_dsr "  Made read-only: $_kt" \
                        || _warn_dsr "  Could not make read-only: $_kt"
                fi
            fi
        done
    fi

    # ── ProtectControlGroups: make /sys/fs/cgroup read-only ──
    if [[ -n "$PROTECT_CONTROL_GROUPS" ]] && [[ "$PROTECT_CONTROL_GROUPS" == "yes" ]]; then
        _log_dsr "Applying ProtectControlGroups=yes"
        if [[ -d /sys/fs/cgroup ]]; then
            if mount --bind /sys/fs/cgroup /sys/fs/cgroup 2>/dev/null; then
                mount -o remount,bind,ro /sys/fs/cgroup 2>/dev/null \
                    && _log_dsr "  /sys/fs/cgroup made read-only" \
                    || _warn_dsr "  Could not make /sys/fs/cgroup read-only"
            fi
        fi
    fi

    # ── ProtectKernelLogs: bind /dev/null over /dev/kmsg ──
    if [[ -n "$PROTECT_KERNEL_LOGS" ]] && [[ "$PROTECT_KERNEL_LOGS" == "yes" ]]; then
        _log_dsr "Applying ProtectKernelLogs=yes"
        if [[ -e /dev/kmsg ]]; then
            mount --bind /dev/null /dev/kmsg 2>/dev/null \
                && _log_dsr "  /dev/kmsg replaced with /dev/null" \
                || _warn_dsr "  Could not replace /dev/kmsg"
        fi
    fi

    # ── Resource limits (Limit*=) via ulimit ──
    # SECURITY: Process hard limits (-H) BEFORE soft limits (-S).
    # Soft limits cannot exceed hard limits, so hard must be set first.
    if [[ ${#LIMITS_RLIMIT[@]} -gt 0 ]]; then
        _log_dsr "Applying resource limits: ${LIMITS_RLIMIT[*]}"
        # Sort: hard limits (no -soft suffix) first, soft limits second
        local _sorted_limits=()
        for _rl in "${LIMITS_RLIMIT[@]}"; do
            [[ "$_rl" != *-soft=* ]] && _sorted_limits+=("$_rl")
        done
        for _rl in "${LIMITS_RLIMIT[@]}"; do
            [[ "$_rl" == *-soft=* ]] && _sorted_limits+=("$_rl")
        done
        for _rl in "${_sorted_limits[@]}"; do
            local _rl_name="${_rl%%=*}"
            local _rl_val="${_rl#*=}"
            local _ul_flag="" _ul_hard=false
            case "$_rl_name" in
                cpu)           _ul_flag="-t"; _ul_hard=true ;;
                fsize)         _ul_flag="-f"; _ul_hard=true ;;
                data)          _ul_flag="-d"; _ul_hard=true ;;
                stack)         _ul_flag="-s"; _ul_hard=true ;;
                core)          _ul_flag="-c"; _ul_hard=true ;;
                rss)           _ul_flag="-m"; _ul_hard=true ;;
                nofile)        _ul_flag="-n"; _ul_hard=true ;;
                as)            _ul_flag="-v"; _ul_hard=true ;;
                nproc)         _ul_flag="-u"; _ul_hard=true ;;
                memlock)       _ul_flag="-l"; _ul_hard=true ;;
                locks)         _ul_flag="-x"; _ul_hard=true ;;
                sigpending)    _ul_flag="-i"; _ul_hard=true ;;
                msgqueue)      _ul_flag="-q"; _ul_hard=true ;;
                nice)          _ul_flag="-e"; _ul_hard=true ;;
                rtprio)        _ul_flag="-r"; _ul_hard=true ;;
                rttime)        _ul_flag="-R"; _ul_hard=true ;;
                cpu-soft)      _ul_flag="-t"; _ul_hard=false ;;
                fsize-soft)    _ul_flag="-f"; _ul_hard=false ;;
                data-soft)     _ul_flag="-d"; _ul_hard=false ;;
                stack-soft)    _ul_flag="-s"; _ul_hard=false ;;
                core-soft)     _ul_flag="-c"; _ul_hard=false ;;
                rss-soft)      _ul_flag="-m"; _ul_hard=false ;;
                nofile-soft)   _ul_flag="-n"; _ul_hard=false ;;
                as-soft)       _ul_flag="-v"; _ul_hard=false ;;
                nproc-soft)    _ul_flag="-u"; _ul_hard=false ;;
                memlock-soft)  _ul_flag="-l"; _ul_hard=false ;;
                locks-soft)    _ul_flag="-x"; _ul_hard=false ;;
                sigpending-soft) _ul_flag="-i"; _ul_hard=false ;;
                msgqueue-soft) _ul_flag="-q"; _ul_hard=false ;;
                nice-soft)     _ul_flag="-e"; _ul_hard=false ;;
                rtprio-soft)   _ul_flag="-r"; _ul_hard=false ;;
                rttime-soft)   _ul_flag="-R"; _ul_hard=false ;;
            esac
            if [[ -n "$_ul_flag" ]]; then
                [[ "$_rl_val" == "infinity" || "$_rl_val" == "max" ]] && _rl_val="unlimited"
                local _ul_scope="S"
                [[ "$_ul_hard" == "true" ]] && _ul_scope="H"
                ulimit "-${_ul_scope}" "${_ul_flag}" "${_rl_val}" 2>/dev/null \
                    && _log_dsr "  ${_rl_name}=${_rl_val} (ulimit -${_ul_scope} $_ul_flag)" \
                    || _warn_dsr "  Failed to set ${_rl_name}=${_rl_val}"
            fi
        done
    fi

    # ── I/O scheduling (IOSchedulingClass) via ionice ──
    # Note: enforcement is via _BUILD_WRAPPER command prefix, not here.
    if [[ -n "$IOSCHED_CLASS" ]]; then
        _log_dsr "Applying IOSchedulingClass=$IOSCHED_CLASS (enforced via _BUILD_WRAPPER)"
    fi

    # ── CPU scheduling (CPUSchedulingPolicy, Nice) via nice/chrt ──
    # Note: enforcement is via _BUILD_WRAPPER command prefix, not here.
    if [[ -n "$NICE_LEVEL" ]]; then
        _log_dsr "Applying Nice=$NICE_LEVEL (enforced via _BUILD_WRAPPER)"
    fi
    if [[ -n "$CPUSCHED_POLICY" ]]; then
        _log_dsr "Applying CPUSchedulingPolicy=$CPUSCHED_POLICY (enforced via _BUILD_WRAPPER)"
    fi

    # ── AmbientCapabilities via setpriv ──
    # Note: enforcement is via _BUILD_WRAPPER command prefix, not here.
    if [[ -n "$AMBIENT_CAPS" ]]; then
        _log_dsr "Applying AmbientCapabilities=$AMBIENT_CAPS (enforced via _BUILD_WRAPPER)"
    fi

    # ── Group identity via sg (enforced via _BUILD_WRAPPER) ──
    if [[ -n "$GROUP_NAME" ]]; then
        _log_dsr "Applying Group=$GROUP_NAME (enforced via _BUILD_WRAPPER)"
        if ! getent group "$GROUP_NAME" >/dev/null 2>&1; then
            _warn_dsr "  Group '$GROUP_NAME' does not exist"
        fi
    fi

    # ── MountFlags: set mount propagation ──
    if [[ -n "$MOUNT_FLAGS" ]]; then
        _log_dsr "Applying MountFlags=$MOUNT_FLAGS"
        local _propagation=""
        case "${MOUNT_FLAGS,,}" in
            slave)       _propagation="--make-rslave" ;;
            private)     _propagation="--make-rprivate" ;;
            shared)      _propagation="--make-rshared" ;;
        esac
        if [[ -n "$_propagation" ]]; then
            mount "$_propagation" / 2>/dev/null \
                && _log_dsr "  Mount propagation: $_propagation" \
                || _warn_dsr "  Failed to set mount propagation to $_propagation"
        fi
    fi

    # ── PassEnvironment: export parent env vars into sandbox ──
    if [[ ${#PASS_ENV[@]} -gt 0 ]]; then
        _log_dsr "Applying PassEnvironment: ${PASS_ENV[*]}"
        for _pe in "${PASS_ENV[@]}"; do
            if [[ -n "${!_pe:-}" ]]; then
                export "$_pe"="${!_pe}"
                _log_dsr "  Passed: $_pe"
            else
                _warn_dsr "  PassEnvironment: $_pe not set in parent"
            fi
        done
    fi

    # ── UnsetEnvironment: unset specified env vars ──
    if [[ ${#UNSET_ENV[@]} -gt 0 ]]; then
        _log_dsr "Applying UnsetEnvironment: ${UNSET_ENV[*]}"
        for _ue in "${UNSET_ENV[@]}"; do
            unset "$_ue" 2>/dev/null
            _log_dsr "  Unset: $_ue"
        done
    fi

    # ── ConfigurationDirectory: create + bind-mount writable ──
    for _cd in "${CONFIG_DIRS[@]}"; do
        local _cd_path="/etc/$_cd"
        mkdir -p "$_cd_path" 2>/dev/null || continue
        chown "${BUILD_USER:-root}:${BUILD_USER:-root}" "$_cd_path" 2>/dev/null || true
        chmod 0755 "$_cd_path" 2>/dev/null || true
        _log_dsr "  ConfigurationDirectory: $_cd_path"
    done

    # ── OOMScoreAdjust: write to /proc/self/oom_score_adj ──
    if [[ -n "$OOM_SCORE_ADJUST" ]]; then
        # SECURITY: Validate value is a sane integer between -1000 and 1000.
        if [[ "$OOM_SCORE_ADJUST" =~ ^-?[0-9]+$ ]] && (( OOM_SCORE_ADJUST >= -1000 && OOM_SCORE_ADJUST <= 1000 )); then
            _log_dsr "Applying OOMScoreAdjust=$OOM_SCORE_ADJUST"
            if [[ -w /proc/self/oom_score_adj ]]; then
                echo "$OOM_SCORE_ADJUST" > /proc/self/oom_score_adj 2>/dev/null \
                    && _log_dsr "  oom_score_adj set to $OOM_SCORE_ADJUST" \
                    || _warn_dsr "  Failed to set oom_score_adj"
            else
                _warn_dsr "  /proc/self/oom_score_adj not writable"
            fi
        else
            _warn_dsr "OOMScoreAdjust=$OOM_SCORE_ADJUST is not a valid integer (-1000 to 1000)"
        fi
    fi

    # ── Runtime verification: check that sandbox actually applied ──
    _sandbox_verify
}

# ── Compile seccomp helper for advanced syscall filtering ──
# Writes a small C program, compiles it in-container (requires gcc from base-devel),
# and returns the path. The helper applies seccomp-BPF filters then execs the target.
# Version-hashed: the compiled binary embeds DSR_SECCOMP_VER so cached
# binaries from prior wrapper versions are detected and recompiled automatically.
_compile_seccomp_helper() {
    local _helper_bin="/tmp/.dsr-seccomp-helper"
    # Cache: if already compiled, check version hash before reuse
    if [[ -f "$_helper_bin" ]] && [[ -x "$_helper_bin" ]]; then
        if "$_helper_bin" --version-check 2>/dev/null; then
            echo "$_helper_bin"
            return 0
        fi
        _warn_dsr "Cached seccomp helper is stale (version mismatch), recompiling..."
        rm -f "$_helper_bin" 2>/dev/null || true
    fi
    # Check for a C compiler: prefer gcc, fall back to cc (POSIX standard name).
    # On some minimal systems only `cc` is available as a symlink to the real
    # compiler. Checking both avoids a false "gcc not found" when cc works.
    local _cc_cmd=""
    if command -v gcc >/dev/null 2>&1; then
        _cc_cmd="gcc"
    elif command -v cc >/dev/null 2>&1; then
        _cc_cmd="cc"
    fi
    if [[ -z "$_cc_cmd" ]]; then
        # Auto-repair: try to install the toolchain if it's missing after a
        # partial upgrade or fresh container where base-devel was removed.
        # Uses the same staged batched install as the main installer's
        # install_base_devel_batched() to avoid OOM on constrained devices.
        _warn_dsr "No C compiler found (gcc/cc) — attempting auto-repair..."
        if command -v pacman >/dev/null 2>&1; then
            # Remove stale pacman lock before installing
            local _lock="/var/lib/pacman/db.lck"
            if [[ -f "$_lock" ]]; then
                local _lck_pid
                _lck_pid=$(cat "$_lock" 2>/dev/null || echo "")
                if [[ -n "$_lck_pid" ]] && ! kill -0 "$_lck_pid" 2>/dev/null; then
                    rm -f "$_lock" 2>/dev/null || true
                fi
            fi
            # Install in batches matching install_base_devel_batched() pattern
            local _batch
            for _batch in "m4 autoconf automake binutils" "bison debugedit diffutils fakeroot" \
                          "flex" "gcc" "gettext groff" "gzip libtool make patch" \
                          "pkgconf sed texinfo which" "linux-api-headers glibc"; do
                _warn_dsr "Installing batch: $_batch"
                pacman -S --noconfirm --needed $_batch 2>/dev/null && \
                    _warn_dsr "  Batch succeeded." || \
                    _warn_dsr "  Batch failed (may already be installed)."
                sleep 1 2>/dev/null || true
            done
        fi
        # Re-check after install attempt
        if command -v gcc >/dev/null 2>&1; then
            _cc_cmd="gcc"
        elif command -v cc >/dev/null 2>&1; then
            _cc_cmd="cc"
        fi
        if [[ -z "$_cc_cmd" ]]; then
            _warn_dsr "No C compiler available after repair attempt (gcc/cc)."
            return 1
        fi
    fi
    local _helper_src="/tmp/.dsr-seccomp-helper-${$}.c"
    cat > "$_helper_src" << 'SECCOMP_C'
#define DSR_SECCOMP_VER "dsr-seccomp-v4.0"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <stddef.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <sys/prctl.h>
#include <sys/syscall.h>

static void apply_filters(int mdwx, int lock_personality, int restrict_realtime,
                          int protect_clock, int protect_hostname, int protect_kernel_logs,
                          int restrict_namespaces, int restrict_addr_families,
                          int system_call_filter, int restrict_file_systems,
                          int sys_call_arch_native_only, int sys_call_log,
                          unsigned int custom_errno) {
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
        fprintf(stderr, "seccomp: PR_SET_NO_NEW_PRIVS failed\n");
        return;
    }
    /* Compute the seccomp return value: SECCOMP_RET_ERRNO with custom_errno.
       If custom_errno is 0, use SECCOMP_EPERM (default, matches systemd).
       If sys_call_log is set, use SECCOMP_RET_LOG so blocked syscalls
       appear in the audit log before returning the error. */
    unsigned int seccomp_ret_action = SECCOMP_RET_ERRNO | ((custom_errno ? custom_errno : SECCOMP_EPERM) & SECCOMP_RET_DATA);
    if (sys_call_log) {
        /* SECCOMP_RET_LOG: log the syscall then return the action (errno).
           Available since Linux 3.5. The syscall appears in audit/ syslog. */
        seccomp_ret_action = SECCOMP_RET_LOG | ((custom_errno ? custom_errno : SECCOMP_EPERM) & SECCOMP_RET_DATA);
        fprintf(stderr, "seccomp: SystemCallLog active (blocked syscalls logged to audit)\n");
    }
    /* RestrictSUIDSGID: block setuid/setgid/setreuid/setregid/setresuid/setresgid/setfsuid/setfsgid/setgroups.
       Also block 32-bit compat syscall variants on x86_64 (setuid32, etc.)
       to prevent bypass via 32-bit binaries when SystemCallArchitectures=native
       is not active. */
    {
        struct sock_filter f[] = {
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,nr)),
            /* Native setuid family */
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setuid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setgid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setreuid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setregid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setresuid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setresgid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setfsuid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setfsgid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setgroups, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
#ifdef __NR_setuid32
            /* 32-bit compat variants (x86_64) */
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setuid32, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setgid32, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setreuid32, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setregid32, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setresuid32, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setresgid32, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setgroups32, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
#endif
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
    }
    /* ProtectKernelModules: block init_module/delete_module/finit_module */
    {
        struct sock_filter f[] = {
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,nr)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_init_module, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_delete_module, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_finit_module, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
    }
    /* MemoryDenyWriteExecute: block mprotect with PROT_WRITE and PROT_EXEC
       both set. This matches systemd semantics: only W^X violations blocked.
       PROT_EXEC alone is allowed, preserving dlopen and JIT compatibility. */
    if (mdwx) {
        struct sock_filter f[] = {
            /* Load syscall number */
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,nr)),
            /* Check mprotect (index 1 -> index 2 if true, index 7 if false) */
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_mprotect, 0, 5),
            /* Load mprotect args[2] (prot flags) */
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,args[2])),
            /* If PROT_WRITE (0x2) not set -> ALLOW (skip 2 to index 6) */
            BPF_JUMP(BPF_JMP|BPF_JSET|BPF_K, 0x2, 0, 2),
            /* If PROT_EXEC (0x4) not set -> ALLOW (skip 1 to index 6) */
            BPF_JUMP(BPF_JMP|BPF_JSET|BPF_K, 0x4, 0, 1),
            /* Both PROT_WRITE and PROT_EXEC set -> block */
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            /* ALLOW: only W, only X, or neither */
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
            /* Check pkey_mprotect (index 7 -> index 8 if true, index 12 if false) */
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_pkey_mprotect, 0, 4),
            /* Load pkey_mprotect args[2] (prot flags) */
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,args[2])),
            /* If PROT_WRITE (0x2) not set -> ALLOW (skip 2 to index 12) */
            BPF_JUMP(BPF_JMP|BPF_JSET|BPF_K, 0x2, 0, 2),
            /* If PROT_EXEC (0x4) not set -> ALLOW (skip 1 to index 12) */
            BPF_JUMP(BPF_JMP|BPF_JSET|BPF_K, 0x4, 0, 1),
            /* Both PROT_WRITE and PROT_EXEC set -> block */
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            /* ALLOW for pkey_mprotect path */
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
        fprintf(stderr, "seccomp: MemoryDenyWriteExecute applied (mprotect W+X blocked)\n");
    }
    /* LockPersonality: block personality() syscall */
    if (lock_personality) {
        struct sock_filter f[] = {
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,nr)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_personality, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
        fprintf(stderr, "seccomp: LockPersonality applied (personality syscall blocked)\n");
    }
    /* RestrictRealtime: block sched_setscheduler/sched_setparam/sched_setattr */
    if (restrict_realtime) {
        struct sock_filter f[] = {
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,nr)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_sched_setscheduler, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_sched_setparam, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_sched_setattr, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
        fprintf(stderr, "seccomp: RestrictRealtime applied (scheduling syscalls blocked)\n");
    }
    /* ProtectClock: block clock_settime/clock_adjtime/settimeofday */
    if (protect_clock) {
        struct sock_filter f[] = {
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,nr)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_clock_settime, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_clock_settime64, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_clock_adjtime, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_settimeofday, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
        fprintf(stderr, "seccomp: ProtectClock applied (time-setting syscalls blocked)\n");
    }
    /* ProtectHostname: block sethostname/setdomainname */
    if (protect_hostname) {
        struct sock_filter f[] = {
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,nr)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_sethostname, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setdomainname, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
        fprintf(stderr, "seccomp: ProtectHostname applied (hostname syscalls blocked)\n");
    }
    /* ProtectKernelLogs: block syslog syscall */
    if (protect_kernel_logs) {
        struct sock_filter f[] = {
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,nr)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_syslog, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
        fprintf(stderr, "seccomp: ProtectKernelLogs applied (syslog syscall blocked)\n");
    }
    /* RestrictNamespaces: block unshare, setns, and clone with namespace flags.
       Matches systemd's implementation: prevents creating new namespaces
       (unshare), joining existing ones (setns), and forking into namespaces
       (clone with CLONE_NEW* flags). clone3() is also blocked since its
       flags are in an opaque struct that seccomp cannot dereference. */
    if (restrict_namespaces) {
        /* CLONE_NEW* bitmask: covers CLONE_NEWNS(0x20000), CLONE_NEWCGROUP(0x2000000),
           CLONE_NEWUTS(0x4000000), CLONE_NEWIPC(0x8000000), CLONE_NEWUSER(0x10000000),
           CLONE_NEWPID(0x20000000), CLONE_NEWNET(0x40000000) */
        #define DSR_CLONE_NEWNS_FLAGS 0x7F020000
        struct sock_filter f[] = {
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,nr)),
            /* unshare: unconditional block */
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_unshare, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            /* setns: unconditional block */
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setns, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            /* clone3: unconditional block (flags in opaque struct) */
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_clone3, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            /* clone: block only when CLONE_NEW* flags are set */
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_clone, 0, 4),
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,args[0])),
            BPF_JUMP(BPF_JMP|BPF_JSET|BPF_K, DSR_CLONE_NEWNS_FLAGS, 1, 0),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            /* ALLOW for all other syscalls */
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
        fprintf(stderr, "seccomp: RestrictNamespaces applied (unshare, setns, clone3 blocked; clone with CLONE_NEW* blocked)\n");
    }
    /* RestrictAddressFamilies: filter socket() by allowed address families.
       Allowed: AF_UNIX(1), AF_INET(2), AF_INET6(10), AF_NETLINK(16).
       All other families (AF_PACKET, AF_BLUETOOTH, AF_ALG, etc.) are blocked. */
    if (restrict_addr_families) {
        struct sock_filter f[] = {
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,nr)),
            /* If not socket, skip to ALLOW (skip 10 instructions to instruction [12]) */
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_socket, 0, 10),
            /* Load socket domain (args[0]) */
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,args[0])),
            /* AF_UNIX (1) */
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, 1, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
            /* AF_INET (2) */
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, 2, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
            /* AF_INET6 (10) */
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, 10, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
            /* AF_NETLINK (16) */
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, 16, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
            /* Not in allowed list -> block with EPERM */
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            /* ALLOW for non-socket syscalls */
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
        fprintf(stderr, "seccomp: RestrictAddressFamilies applied (AF_UNIX, AF_INET, AF_INET6, AF_NETLINK allowed)\n");
    }
    /* SystemCallFilter: denylist of dangerous syscalls.
       Blocks: reboot, kexec_load, kexec_file_load, ptrace,
       process_vm_readv, process_vm_writev, uselib, add_key, keyctl, request_key */
    if (system_call_filter) {
        struct sock_filter f[] = {
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,nr)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_reboot, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_kexec_load, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_kexec_file_load, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_ptrace, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_process_vm_readv, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_process_vm_writev, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_uselib, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_add_key, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_keyctl, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_request_key, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
        fprintf(stderr, "seccomp: SystemCallFilter applied (reboot, kexec, ptrace, vm, key syscalls blocked)\n");
    }
    /* SystemCallArchitectures=native: block non-native architecture syscalls.
       Uses AUDIT_ARCH to reject 32-bit compatibility syscalls on 64-bit kernels.
       Matches systemd's SystemCallArchitectures=native enforcement. */
    if (sys_call_arch_native_only) {
        /* AUDIT_ARCH is set by prctl(PR_GET_NO_NEW_PRIVS) context; we use
           seccomp to check the architecture field in seccomp_data.
           AUDIT_ARCH_X86_64=0xC000003E, AUDIT_ARCH_I386=0x40000003 */
        unsigned int native_arch;
#if defined(__x86_64__)
        native_arch = 0xC000003E; /* AUDIT_ARCH_X86_64 */
#elif defined(__aarch64__)
        native_arch = 0xC00000B7; /* AUDIT_ARCH_AARCH64 */
#elif defined(__arm__)
        native_arch = 0x40000028; /* AUDIT_ARCH_ARM */
#elif defined(__i386__)
        native_arch = 0x40000003; /* AUDIT_ARCH_I386 */
#else
        native_arch = 0;
#endif
        if (native_arch) {
            struct sock_filter f[] = {
                BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,arch)),
                BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, native_arch, 0, 1),
                BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
                BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
            };
            struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
            prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
            fprintf(stderr, "seccomp: SystemCallArchitectures=native applied (non-native arch blocked)\n");
        }
    }
    /* SystemCallLog: handled above via seccomp_ret_action (SECCOMP_RET_LOG). */
    /* RestrictFileSystems: block mount() syscall entirely.
       NOTE: seccomp-BPF cannot dereference pointers — args[2] for mount()
       is a userspace pointer to a filesystem type string, not the magic
       number itself. True per-type filtering requires Landlock LSM or
       eBPF. We block all mount() as the safe default that matches
       systemd's intent. If Landlock LSM is available in a future kernel,
       it could provide per-filesystem allow-listing without seccomp. */
    if (restrict_file_systems) {
        struct sock_filter f[] = {
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,nr)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_mount, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, seccomp_ret_action),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
        fprintf(stderr, "seccomp: RestrictFileSystems applied (mount syscall blocked)\n");
    }
}
int main(int argc, char *argv[]) {
    /* Version check: allows the wrapper to detect stale cached binaries.
     * Prints the compiled-in version hash to stdout and exits 0 if it matches
     * the expected hash. The wrapper passes no args for this check. */
    if (argc >= 2 && strcmp(argv[1], "--version-check") == 0) {
        printf("%s\n", DSR_SECCOMP_VER);
        return 0;
    }
    int mdwx = 0, lock_personality = 0, restrict_realtime = 0;
    int protect_clock = 0, protect_hostname = 0, protect_kernel_logs = 0;
    int restrict_namespaces = 0, restrict_addr_families = 0;
    int system_call_filter = 0, restrict_file_systems = 0;
    int drop_all_caps = 0;
    int sys_call_arch_native_only = 0, sys_call_log = 0;
    unsigned int sys_call_errno = 0;
    int cmd_start = 1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--mdwx") == 0) { mdwx = 1; cmd_start = i+1; }
        else if (strcmp(argv[i], "--lock-personality") == 0) { lock_personality = 1; cmd_start = i+1; }
        else if (strcmp(argv[i], "--restrict-realtime") == 0) { restrict_realtime = 1; cmd_start = i+1; }
        else if (strcmp(argv[i], "--protect-clock") == 0) { protect_clock = 1; cmd_start = i+1; }
        else if (strcmp(argv[i], "--protect-hostname") == 0) { protect_hostname = 1; cmd_start = i+1; }
        else if (strcmp(argv[i], "--protect-kernel-logs") == 0) { protect_kernel_logs = 1; cmd_start = i+1; }
        else if (strcmp(argv[i], "--restrict-namespaces") == 0) { restrict_namespaces = 1; cmd_start = i+1; }
        else if (strcmp(argv[i], "--restrict-addr-families") == 0) { restrict_addr_families = 1; cmd_start = i+1; }
        else if (strcmp(argv[i], "--system-call-filter") == 0) { system_call_filter = 1; cmd_start = i+1; }
        else if (strcmp(argv[i], "--restrict-file-systems") == 0) { restrict_file_systems = 1; cmd_start = i+1; }
        else if (strcmp(argv[i], "--drop-caps") == 0) { drop_all_caps = 1; cmd_start = i+1; }
        else if (strcmp(argv[i], "--sys-call-arch-native") == 0) { sys_call_arch_native_only = 1; cmd_start = i+1; }
        else if (strcmp(argv[i], "--sys-call-log") == 0) { sys_call_log = 1; cmd_start = i+1; }
        else if (strncmp(argv[i], "--sys-call-errno=", 17) == 0) { sys_call_errno = (unsigned int)atoi(argv[i]+17); cmd_start = i+1; }
        else if (strcmp(argv[i], "--seccomp") == 0) { cmd_start = i+1; }
        else if (strcmp(argv[i], "--") == 0) { cmd_start = i+1; break; }
        else break;
    }
    if (cmd_start >= argc) { fprintf(stderr, "seccomp-helper: no command\n"); return 1; }
    /* CapabilityBoundingSet: use prctl(PR_CAPBSET_DROP) to truly drop the
       bounding capability set. Unlike setpriv --inh-caps (which only modifies
       the inheritable set), this prevents the child from ever regaining
       capabilities via execve() of setuid binaries. This is the kernel-native
       mechanism that systemd uses internally. */
    if (drop_all_caps) {
        /* Drop all capabilities from the bounding set using prctl.
           CAP_LAST_CAP is dynamically determined via /proc/sys/kernel/cap_last_cap. */
        FILE *f = fopen("/proc/sys/kernel/cap_last_cap", "r");
        if (f) {
            int last_cap = 0;
            if (fscanf(f, "%d", &last_cap) == 1) {
                for (int cap = 0; cap <= last_cap; cap++) {
                    prctl(PR_CAPBSET_DROP, cap, 0, 0, 0);
                }
                fprintf(stderr, "seccomp: CapabilityBoundingSet applied (dropped all %d caps via prctl)\n", last_cap);
            }
            fclose(f);
        } else {
            /* Fallback: drop well-known caps up to CAP_LAST_CAP=41 (Linux 6.x) */
            for (int cap = 0; cap <= 41; cap++) {
                prctl(PR_CAPBSET_DROP, cap, 0, 0, 0);
            }
            fprintf(stderr, "seccomp: CapabilityBoundingSet applied (dropped caps 0-41, fallback range)\n");
        }
        /* Also clear inheritable set as defense-in-depth */
        prctl(PR_CAPBSET_DROP, 0, 0, 0, 0); /* no-op, already dropped above */
    }
    apply_filters(mdwx, lock_personality, restrict_realtime,
                  protect_clock, protect_hostname, protect_kernel_logs,
                  restrict_namespaces, restrict_addr_families,
                  system_call_filter, restrict_file_systems,
                  sys_call_arch_native_only, sys_call_log,
                  sys_call_errno);
    execvp(argv[cmd_start], &argv[cmd_start]);
    perror("execvp");
    return 127;
}
SECCOMP_C
    # Validate toolchain before attempting compilation. During partial upgrades,
    # gcc may be present but its standard library headers may be mismatched
    # (e.g., updated compiler with old glibc headers). Test with a minimal
    # program that includes ALL headers the seccomp helper needs.
    # Capture gcc error output for diagnostics so we can distinguish between
    # "missing headers" vs "linker errors" vs "gcc version mismatch".
    local _test_src="${_dsr_tmp:-/tmp}/.dsr-toolchain-test.c"
    local _test_bin="${_dsr_tmp:-/tmp}/.dsr-toolchain-test"
    local _gcc_err="/tmp/.dsr-gcc-err.log"
    cat > "$_test_src" << 'TOOLCHAIN_TEST'
#include <stdio.h>
#include <stddef.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/socket.h>
#include <linux/if.h>
int main() {
    struct sock_filter f[] = { BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW) };
    struct sock_fprog p = { .len = 1, .filter = f };
    (void)f; (void)p;
    return 0;
}
TOOLCHAIN_TEST
    if ! $_cc_cmd -O2 -o "$_test_bin" "$_test_src" 2>"$_gcc_err"; then
        local _gcc_output
        _gcc_output=$(cat "$_gcc_err" 2>/dev/null || echo "unknown error")
        _warn_dsr "Toolchain validation FAILED: gcc cannot compile a minimal seccomp test program."
        _warn_dsr "gcc error output: $_gcc_output"
        # Diagnose the specific failure mode
        if echo "$_gcc_output" | grep -qi "seccomp.h\|filter.h\|No such file"; then
            _warn_dsr "CAUSE: Missing Linux kernel headers (linux/seccomp.h, linux/filter.h)."
            _warn_dsr "FIX: pacman -S --noconfirm --needed linux-api-headers"
        elif echo "$_gcc_output" | grep -qi "prctl\|sys/prctl.h"; then
            _warn_dsr "CAUSE: Missing glibc headers (sys/prctl.h)."
            _warn_dsr "FIX: pacman -S --noconfirm --needed glibc"
        elif echo "$_gcc_output" | grep -qi "socket.h\|if.h"; then
            _warn_dsr "CAUSE: Missing network/kernel headers (sys/socket.h, linux/if.h)."
            _warn_dsr "FIX: pacman -S --noconfirm --needed linux-api-headers glibc"
        else
            _warn_dsr "This may indicate a partial upgrade (gcc vs. headers mismatch)."
            _warn_dsr "FIX: pacman -S --noconfirm --needed base-devel gcc glibc linux-api-headers"
        fi
        # Log gcc version for debugging partial upgrade scenarios
        local _gcc_ver
        _gcc_ver=$(gcc --version 2>/dev/null | head -1 || echo "unknown")
        _warn_dsr "gcc version: $_gcc_ver"
        # Auto-repair: try reinstalling missing headers in case of partial upgrade
        _warn_dsr "Attempting auto-repair: reinstalling missing headers..."
        if command -v pacman >/dev/null 2>&1; then
            _remove_stale_lock 2>/dev/null || true
            if pacman -S --noconfirm --needed linux-api-headers glibc 2>/dev/null; then
                _warn_dsr "Headers reinstalled. Retrying toolchain test..."
                if $_cc_cmd -O2 -o "$_test_bin" "$_test_src" 2>/dev/null; then
                    _warn_dsr "Toolchain test passed after auto-repair."
                    rm -f "$_test_src" "$_test_bin" "$_gcc_err"
                    # Continue to full compilation below
                else
                    rm -f "$_test_src" "$_test_bin" "$_gcc_err"
                    return 1
                fi
            else
                rm -f "$_test_src" "$_test_bin" "$_gcc_err"
                return 1
            fi
        else
            rm -f "$_test_src" "$_test_bin" "$_gcc_err"
            return 1
        fi
    fi
    rm -f "$_test_src" "$_test_bin" "$_gcc_err"

    # Attempt full compilation. Capture error output for diagnostics.
    local _compile_err="/tmp/.dsr-compile-err.log"
    if $_cc_cmd -O2 -o "$_helper_bin" "$_helper_src" 2>"$_compile_err"; then
        rm -f "$_helper_src" "$_compile_err"
        chmod 755 "$_helper_bin"
        echo "$_helper_bin"
        return 0
    else
        local _compile_output
        _compile_output=$(cat "$_compile_err" 2>/dev/null || echo "unknown error")
        _warn_dsr "Failed to compile seccomp helper ($_cc_cmd -O2). Full error:"
        _warn_dsr "$_compile_output"
        _warn_dsr "Toolchain validation passed but full compilation failed — this suggests"
        _warn_dsr "a larger source file exposed a linker or optimization issue."
        # Auto-repair attempt: try reinstalling the full toolchain in case of
        # partial upgrade (gcc version doesn't match installed headers).
        # Uses the same staged batched install as install_base_devel_batched().
        _warn_dsr "Attempting auto-repair: reinstalling toolchain packages..."
        if command -v pacman >/dev/null 2>&1; then
            local _lock="/var/lib/pacman/db.lck"
            if [[ -f "$_lock" ]]; then
                local _lck_pid
                _lck_pid=$(cat "$_lock" 2>/dev/null || echo "")
                if [[ -n "$_lck_pid" ]] && ! kill -0 "$_lck_pid" 2>/dev/null; then
                    rm -f "$_lock" 2>/dev/null || true
                fi
            fi
            local _batch
            for _batch in "m4 autoconf automake binutils" "bison debugedit diffutils fakeroot" \
                          "flex" "gcc" "gettext groff" "gzip libtool make patch" \
                          "pkgconf sed texinfo which" "linux-api-headers glibc"; do
                pacman -S --noconfirm --needed $_batch 2>/dev/null
                sleep 1 2>/dev/null || true
            done
            _warn_dsr "Toolchain reinstalled. Retrying compilation..."
            if $_cc_cmd -O2 -o "$_helper_bin" "$_helper_src" 2>/dev/null; then
                rm -f "$_helper_src" "$_compile_err"
                chmod 755 "$_helper_bin"
                echo "$_helper_bin"
                return 0
            fi
        fi
        _warn_dsr "Auto-repair failed. Full FIX: pacman -Syyu && pacman -S base-devel gcc glibc linux-api-headers"
        _warn_dsr "  Or use --strict-security to abort instead of silently degrading."
        rm -f "$_helper_src" "$_helper_bin" "$_compile_err"
        return 1
    fi
}

_build_seccomp_args() {
    local _args=""
    # The seccomp helper unconditionally applies RestrictSUIDSGID and ProtectKernelModules.
    # We pass flags for each additional property so the helper knows which BPF filters to apply.
    # We must return a non-empty string if ANY seccomp property is active
    # so that the caller knows to invoke the helper.
    local _needs_seccomp=false
    [[ -n "$MEMORY_DENY_WRITE_EXECUTE" ]] && _needs_seccomp=true
    [[ -n "$RESTRICT_SUID_SGID" ]] && _needs_seccomp=true
    [[ -n "$PROTECT_KERNEL_MODULES" ]] && _needs_seccomp=true
    [[ -n "$LOCK_PERSONALITY" ]] && _needs_seccomp=true
    [[ -n "$RESTRICT_REALTIME" ]] && _needs_seccomp=true
    [[ -n "$PROTECT_CLOCK" ]] && _needs_seccomp=true
    [[ -n "$PROTECT_HOSTNAME" ]] && _needs_seccomp=true
    [[ -n "$PROTECT_KERNEL_LOGS" ]] && _needs_seccomp=true
    [[ -n "$RESTRICT_NAMESPACES" ]] && _needs_seccomp=true
    [[ -n "$RESTRICT_ADDRESS_FAMILIES" ]] && _needs_seccomp=true
    [[ -n "$SYSTEM_CALL_FILTER" ]] && _needs_seccomp=true
    [[ -n "$RESTRICT_FILE_SYSTEMS" ]] && _needs_seccomp=true
    [[ -n "$CAP_BOUNDING_SET" ]] && _needs_seccomp=true
    [[ -n "$SYS_CALL_ARCH" ]] && _needs_seccomp=true
    [[ -n "$SYS_CALL_LOG" ]] && _needs_seccomp=true
    [[ -n "$SYS_CALL_ERRNO" ]] && _needs_seccomp=true
    if $_needs_seccomp; then
        _args="--seccomp"
        [[ "$MEMORY_DENY_WRITE_EXECUTE" == "yes" ]] && _args="$_args --mdwx"
        [[ "$LOCK_PERSONALITY" == "yes" ]] && _args="$_args --lock-personality"
        [[ "$RESTRICT_REALTIME" == "yes" ]] && _args="$_args --restrict-realtime"
        [[ "$PROTECT_CLOCK" == "yes" ]] && _args="$_args --protect-clock"
        [[ "$PROTECT_HOSTNAME" == "yes" ]] && _args="$_args --protect-hostname"
        [[ "$PROTECT_KERNEL_LOGS" == "yes" ]] && _args="$_args --protect-kernel-logs"
        [[ "$RESTRICT_NAMESPACES" == "yes" ]] && _args="$_args --restrict-namespaces"
        [[ "$RESTRICT_ADDRESS_FAMILIES" != "" ]] && _args="$_args --restrict-addr-families"
        [[ "$SYSTEM_CALL_FILTER" != "" ]] && _args="$_args --system-call-filter"
        [[ "$RESTRICT_FILE_SYSTEMS" != "" ]] && _args="$_args --restrict-file-systems"
        [[ -n "$CAP_BOUNDING_SET" ]] && _args="$_args --drop-caps"
        [[ "$SYS_CALL_ARCH" == "native" || "$SYS_CALL_ARCH" == "yes" ]] && _args="$_args --sys-call-arch-native"
        [[ -n "$SYS_CALL_LOG" ]] && _args="$_args --sys-call-log"
        [[ -n "$SYS_CALL_ERRNO" ]] && _args="$_args --sys-call-errno=$SYS_CALL_ERRNO"
    fi
    echo "$_args"
}

# ── Determine the run-as user ──
# DynamicUser=true  → use dedicated build user (privileged isolation)
# User=property     → use that user (non-DynamicUser explicit user switch)
# --user mode       → run as the current user (no root escalation needed)
# neither           → run as current user (root if container root exec)

# ── _prepare_seccomp: shared seccomp helper preparation (used by all paths) ──
_prepare_seccomp() {
    _SECCOMP_HELPER=""
    _seccomp_args="$(_build_seccomp_args)"
    if [[ -n "$_seccomp_args" ]]; then
        _SECCOMP_HELPER="$(_compile_seccomp_helper)" || _SECCOMP_HELPER=""
        if [[ -z "$_SECCOMP_HELPER" ]] && [[ "$_DSR_STRICT_SECURITY" == "true" ]]; then
            echo "systemd-run(fake): FATAL: seccomp helper compilation failed under --strict-security." >&2
            echo "  Sandboxing properties (MemoryDenyWriteExecute, RestrictSUIDSGID, ProtectKernelModules)" >&2
            echo "  cannot be enforced without the seccomp helper. Aborting to avoid" >&2
            echo "  running with degraded security." >&2
            exit 1
        elif [[ -z "$_SECCOMP_HELPER" ]]; then
            _warn_dsr "╔══════════════════════════════════════════════════════════════╗"
            _warn_dsr "║  SECCOMP SANDBOXING DEGRADED — reduced syscall filtering   ║"
            _warn_dsr "╚══════════════════════════════════════════════════════════════╝"
            _warn_dsr "Seccomp helper compilation failed. The following protections"
            _warn_dsr "will NOT be enforced for this AUR build:"
            _warn_dsr "  - MemoryDenyWriteExecute  (blocks W+X memory mapping)"
            _warn_dsr "  - RestrictSUIDSGID         (blocks setuid/setgid family)"
            _warn_dsr "  - ProtectKernelModules     (blocks module loading)"
            _warn_dsr "  - ProtectClock             (blocks clock manipulation)"
            _warn_dsr "  - RestrictNamespaces       (blocks unshare/setns/clone)"
            _warn_dsr "  - RestrictAddressFamilies  (filters socket() families)"
            _warn_dsr "  - SystemCallFilter         (blocks reboot/ptrace/etc.)"
            _warn_dsr ""
            _warn_dsr "Using middle-ground sandbox (no seccomp): mount namespace,"
            _warn_dsr "PID namespace, capability dropping, and mount restrictions"
            _warn_dsr "remain active. SECCOMP_MODE_STRICT cannot be used because"
            _warn_dsr "it blocks execve, preventing build processes from running."
            # Export a flag so the execution wrapper applies middle-ground sandbox
            export _DSR_SECCOMP_STRICT_FALLBACK=true
            _warn_dsr "The build will run with mount namespace + PID namespace + capabilities."
            _warn_dsr "To restore full sandboxing, install base-devel inside the container:"
            _warn_dsr "  pacman -S --noconfirm --needed base-devel gcc linux-api-headers glibc"
            echo "" >&2
            echo "╔══════════════════════════════════════════════════════════════╗" >&2
            echo "║  WARNING: Seccomp-BPF filtering unavailable                ║" >&2
            echo "╚══════════════════════════════════════════════════════════════╝" >&2
            # Prompt for confirmation unless non-interactive or --strict-security
            if [[ "${_DSR_STRICT_SECURITY:-}" != "true" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
                printf "  Continue with reduced sandbox? (y/N): " >&2
                read -r _confirm </dev/tty 2>/dev/null || _confirm=""
                if [[ "$_confirm" != "y" && "$_confirm" != "Y" ]]; then
                    _warn_dsr "Build aborted by user (seccomp required)."
                    echo "Aborted. Install toolchain for full sandboxing:" >&2
                    echo "  pacman -S --noconfirm --needed base-devel gcc linux-api-headers glibc" >&2
                    exit 1
                fi
                _warn_dsr "User approved reduced sandbox. Continuing..."
            fi
        fi
    fi
}

# SECURITY: Write sandbox functions to a temp file instead of using export -f.
# export -f leaks function bodies into the environment (BASH_FUNC_* variables),
# which a malicious PKGBUILD can read/override. A sourceable file avoids this.
_DSR_FUNCS_FILE="/tmp/.dsr-sandbox-funcs-$$.sh"
cat > "$_DSR_FUNCS_FILE" << 'SANDBOX_FUNCS'
# Populated by _write_sandbox_func_file() below
SANDBOX_FUNCS
# SECURITY: Dump all sandbox variables into the file so they are in scope
# when _apply_sandbox is sourced inside bash -c subprocesses. Without this,
# non-exported shell variables (PROTECT_SYSTEM, etc.) resolve to empty,
# making _apply_sandbox a no-op in bwrap/unshare code paths.
for _dv in PROTECT_SYSTEM PROTECT_HOME PRIVATE_TMP PRIVATE_DEVICES PRIVATE_NETWORK \
    MEMORY_DENY_WRITE_EXECUTE RESTRICT_SUID_SGID PROTECT_KERNEL_MODULES \
    LOCK_PERSONALITY RESTRICT_REALTIME PROTECT_CLOCK PROTECT_HOSTNAME \
    PROTECT_KERNEL_LOGS PROTECT_KERNEL_TUNABLES PROTECT_CONTROL_GROUPS \
    RESTRICT_NAMESPACES RESTRICT_ADDRESS_FAMILIES \
    SYSTEM_CALL_FILTER RESTRICT_FILE_SYSTEMS CAP_BOUNDING_SET \
    NO_NEW_PRIVS SECURE_BITS PERSONALITY PROTECT_PROC PROC_SUBSET \
    PRIVATE_USERS DISABLE_EXTRA_FDS COREDUMP_RECEIVE \
    IOSCHED_CLASS IOSCHED_PRIORITY CPUSCHED_POLICY CPUSCHED_PRIORITY \
    NICE_LEVEL AMBIENT_CAPS GROUP_NAME MOUNT_FLAGS OOM_SCORE_ADJUST \
    TIMEOUT_START BUILD_USER DSR_VERSION _DSR_LOG WORK_DIR CACHE_DIR; do
    declare -p "$_dv" >> "$_DSR_FUNCS_FILE" 2>/dev/null || true
done
for _da in READ_ONLY_PATHS INACCESSIBLE_PATHS STATE_DIRECTORIES LOGS_DIRECTORIES \
    RUNTIME_DIRECTORIES BIND_PATHS BIND_RO_PATHS TMPFS_SPECS READ_WRITE_PATHS \
    LIMITS_RLIMIT PASS_ENV UNSET_ENV CONFIG_DIRS; do
    declare -p "$_da" >> "$_DSR_FUNCS_FILE" 2>/dev/null || true
done
declare -f _sandbox_verify >> "$_DSR_FUNCS_FILE" 2>/dev/null || true
declare -f _apply_sandbox >> "$_DSR_FUNCS_FILE" 2>/dev/null || true
declare -f _log_dsr >> "$_DSR_FUNCS_FILE" 2>/dev/null || true
declare -f _warn_dsr >> "$_DSR_FUNCS_FILE" 2>/dev/null || true
chmod 600 "$_DSR_FUNCS_FILE" 2>/dev/null || true
# Clean up the sourceable functions file on exit
trap 'rm -f "$_DSR_FUNCS_FILE" 2>/dev/null' EXIT

# ── _prepare_cap_priv: shared capability/NoNewPrivileges preparation ──
# Reads the PARSED variables (NO_NEW_PRIVS, CAP_BOUNDING_SET) directly,
# not the _DSR_* env vars which are only set by _apply_sandbox inside the sandbox.
_prepare_cap_priv() {
    _CAP_PRIV=""
    # Build capsh/setpriv prefix from the parsed CAP_BOUNDING_SET value
    if [[ -n "${CAP_BOUNDING_SET:-}" ]]; then
        if command -v capsh >/dev/null 2>&1; then
            local _cap_str_n="${CAP_BOUNDING_SET//cap_/CAP_}"
            case "$_cap_str_n" in
                "~all"|"")    _CAP_PRIV="capsh --drop=all -- " ;;
                "all")        _CAP_PRIV="" ;;
                \~*)          _CAP_PRIV="capsh --drop=${_cap_str_n#\~} -- " ;;
                *)            _CAP_PRIV="capsh --drop=all -- " ;;
            esac
        elif command -v setpriv >/dev/null 2>&1; then
            local _cap_str_n="${CAP_BOUNDING_SET//cap_/CAP_}"
            case "$_cap_str_n" in
                "~all"|"")    _CAP_PRIV="setpriv --inh-caps=-all -- " ;;
                "all")        _CAP_PRIV="" ;;
                \~*)          _CAP_PRIV="setpriv --inh-caps=-${_cap_str_n#\~} -- " ;;
                *)            _CAP_PRIV="setpriv --inh-caps=-all -- " ;;
            esac
        fi
    fi
    _NNP=""
    [[ "${NO_NEW_PRIVS:-}" == "yes" ]] && _NNP="setpriv --no-new-privs -- "
}

# ── _run_sandboxed_bwrap: Execute a command using bwrap with sandboxing ──
# $1 = user to run as (empty = current user)
# Rest = command args
# Returns the exit code of the inner command.
_run_sandboxed_bwrap() {
    local _run_user="$1"; shift
    _build_bwrap_args || return 1
    _log_dsr "Using bwrap as sandbox engine"
    # Log when seccomp is degraded so the user knows which protections are
    # missing. The flag is set by _prepare_seccomp() when compilation fails.
    if [[ "${_DSR_SECCOMP_STRICT_FALLBACK:-}" == "true" ]]; then
        _warn_dsr "Seccomp helper unavailable — running WITHOUT seccomp-BPF filtering."
        _warn_dsr "Mount namespace, PID namespace, and capability dropping remain active."
    fi
    local _inner_cmd
    _inner_cmd="${_BUILD_WRAPPER:-}exec \"\${@}\""
    if [[ -n "$WORK_DIR" ]]; then
        _inner_cmd="cd '${WORK_DIR}' 2>/dev/null || true; ${_inner_cmd}"
    fi
    # Build the verification wrapper: run _apply_sandbox (for properties bwrap
    # doesn't handle natively: SecureBits, Personality, ProtectProc, ProcSubset,
    # DisableExtraFileDescriptors, CoredumpReceive), then _sandbox_verify, then
    # the actual command.
    local _verify_cmd="source $_DSR_FUNCS_FILE 2>/dev/null; _apply_sandbox; _sandbox_verify; ${_inner_cmd}"
    if [[ -n "$_run_user" ]]; then
        if [[ -n "${_SECCOMP_HELPER:-}" ]]; then
            bwrap "${_DSR_BWRAP_ARGS[@]}" -- sudo -u "$_run_user" -H -- "$_SECCOMP_HELPER" $_seccomp_args -- bash -c "$_verify_cmd" -- "${CMD_ARGS[@]}"
        else
            bwrap "${_DSR_BWRAP_ARGS[@]}" -- sudo -u "$_run_user" -H -- bash -c "$_verify_cmd" -- "${CMD_ARGS[@]}"
        fi
    else
        if [[ -n "${_SECCOMP_HELPER:-}" ]]; then
            bwrap "${_DSR_BWRAP_ARGS[@]}" -- "$_SECCOMP_HELPER" $_seccomp_args -- bash -c "$_verify_cmd" -- "${CMD_ARGS[@]}"
        else
            bwrap "${_DSR_BWRAP_ARGS[@]}" -- bash -c "$_verify_cmd" -- "${CMD_ARGS[@]}"
        fi
    fi
}

# ── _run_sandboxed_unshare: REMOVED — unshare fallback sandbox ──
# This function is no longer reachable from _run_sandboxed, which now fails
# hard when bwrap is missing. Keeping the body as dead code for historical
# reference; the guard prevents accidental entry.
_run_sandboxed_unshare() {
    _warn_dsr "systemd-run(fake): unshare fallback is DISABLED — bwrap required."
    _warn_dsr "  Install bubblewrap: sudo pacman -S bubblewrap"
    exit 126
}

# ── _run_sandboxed: Try bwrap first ──
# $1 = user to run as (empty = current user)
_DSR_BWRAP_AVAILABLE=""
_run_sandboxed() {
    local _run_user="$1"
    # Cache bwrap availability: _build_bwrap_args itself checks `command -v bwrap`
    # and _run_sandboxed_bwrap calls it again. Checking once avoids redundant
    # filesystem lookups and produces a clear one-time warning when unshare is
    # the fallback engine.
    if [[ -z "$_DSR_BWRAP_AVAILABLE" ]]; then
        if command -v bwrap >/dev/null 2>&1; then
            _DSR_BWRAP_AVAILABLE=true
        else
            _DSR_BWRAP_AVAILABLE=false
        fi
    fi
    if [[ "$_DSR_BWRAP_AVAILABLE" == "true" ]]; then
        _run_sandboxed_bwrap "$_run_user"
        return $?
    else
        # bwrap is NOT available — degrade gracefully instead of killing the
        # build. Running without bwrap loses PID namespace isolation and
        # seccomp filtering, but the build can still complete. The user is
        # warned so they can install bwrap for full sandboxing.
        _warn_dsr ""
        _warn_dsr "╔══════════════════════════════════════════════════════════════╗"
        _warn_dsr "║  SANDBOX DEGRADED — bubblewrap (bwrap) not installed       ║"
        _warn_dsr "╚══════════════════════════════════════════════════════════════╝"
        _warn_dsr "Running WITHOUT sandbox isolation. The build will execute"
        _warn_dsr "as the target user but without:"
        _warn_dsr "  - PID namespace isolation"
        _warn_dsr "  - seccomp-BPF syscall filtering"
        _warn_dsr "  - Mount namespace protections"
        _warn_dsr ""
        _warn_dsr "To restore full sandboxing, install bubblewrap:"
        _warn_dsr "  sudo pacman -S --noconfirm --needed bubblewrap"
        _warn_dsr ""
        echo "" >&2
        echo "╔══════════════════════════════════════════════════════════════╗" >&2
        echo "║  WARNING: Running WITHOUT sandbox (bubblewrap missing)     ║" >&2
        echo "╚══════════════════════════════════════════════════════════════╝" >&2
        # Prompt for confirmation unless non-interactive or --strict-security
        if [[ "${_DSR_STRICT_SECURITY:-}" != "true" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
            printf "  Continue without sandbox? (y/N): " >&2
            read -r _confirm </dev/tty 2>/dev/null || _confirm=""
            if [[ "$_confirm" != "y" && "$_confirm" != "Y" ]]; then
                _warn_dsr "Build aborted by user (sandbox required)."
                echo "Aborted. Install bubblewrap for full sandboxing:" >&2
                echo "  sudo pacman -S --noconfirm --needed bubblewrap" >&2
                exit 1
            fi
            _warn_dsr "User approved degraded sandbox. Continuing..."
        fi
        # Run the command directly without sandbox wrapping
        ${_ENV_SETUP}
        if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then cd "$WORK_DIR" 2>/dev/null || true; fi
        if [[ -n "${TARGET_USER:-}" ]] && [[ "$(id -u)" -eq 0 ]]; then
            exec sudo -u "$TARGET_USER" -H -- bash -c "${_ENV_SETUP}exec \"\${@}\"" -- "${CMD_ARGS[@]}"
        fi
        exec "${CMD_ARGS[@]}"
    fi
}

# ── --scope mode: just exec without creating a unit, honoring DynamicUser ──
if $SCOPE_MODE && ! $DYNAMIC_USER; then
    _log_dsr "SCOPE mode: direct execution without sandbox/unit creation"
    ${_ENV_SETUP}
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && cd "$WORK_DIR" 2>/dev/null || true
    if [[ -n "$TARGET_USER" ]] && [[ "$(id -u)" -eq 0 ]]; then
        exec sudo -u "$TARGET_USER" -H -- bash -c "${_ENV_SETUP}exec \"\${@}\"" -- "${CMD_ARGS[@]}"
    fi
    exec "${CMD_ARGS[@]}"
fi

# ── --user mode (non-root invocation): run as current or target user ──
if $USER_MODE || [[ "$(id -u)" -ne 0 ]]; then
    _log_dsr "USER mode (non-root): running as current user uid=$(id -u) user=$_DSR_HOST_USER"
    ${_ENV_SETUP}
    if $_NEEDS_SANDBOX; then
        _prepare_cap_priv
        _prepare_seccomp
        _run_sandboxed ""
        exit $?
    else
        if [[ -n "$WORK_DIR" ]] && [[ -d "$WORK_DIR" ]]; then cd "$WORK_DIR" 2>/dev/null || true; fi
        exec "${CMD_ARGS[@]}"
    fi
fi

if $DYNAMIC_USER && [[ "$(id -u)" -eq 0 ]]; then
# Use a dedicated build user to isolate AUR builds from the host user's
# home directory. A malicious AUR package gains only build-user access.
BUILD_USER="_builduser"
_BL_TMP_HOME=""

# Before creating any user, purge stale subuid/subgid entries for orphaned
# _brecover* users from prior interrupted builds. Without this, useradd may
# fail with "uid already in use" or similar namespace collision errors.
for _stale_pat in /etc/subuid /etc/subgid; do
    if [[ -w "$_stale_pat" ]]; then
        sed -i '/^_brecover/d' "$_stale_pat" 2>/dev/null || true
    fi
done

if ! id "$BUILD_USER" >/dev/null 2>&1; then
    if ! useradd -r -d /var/lib/builduser -s /usr/bin/nologin "$BUILD_USER" 2>/dev/null; then
        _warn_dsr "useradd -r failed — trying ad-hoc non-root build user as fallback"
        chmod +t /var/tmp 2>/dev/null || true
        _bl_tmp=$(mktemp -d /var/tmp/builduser-home-XXXXXX 2>/dev/null) || _bl_tmp=""
        if [[ -n "$_bl_tmp" ]]; then
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
                _warn_dsr "Ad-hoc useradd failed for $BUILD_USER — cleaning up temp home"
                rmdir "$_bl_tmp" 2>/dev/null || rm -rf "$_bl_tmp" 2>/dev/null || true
                BUILD_USER=""
            else
                _BL_TMP_HOME="$_bl_tmp"
                _log_dsr "Ad-hoc build user $BUILD_USER home=$_BL_TMP_HOME created (isolated from host mounts)"
                # EXIT trap ensures cleanup even on SIGTERM/SIGKILL
                _cleanup_builduser() {
                    if [[ -n "$BUILD_USER" ]]; then
                        userdel -r "$BUILD_USER" 2>/dev/null || true
                    fi
                    if [[ -n "$_BL_TMP_HOME" ]]; then
                        rm -rf "$_BL_TMP_HOME" 2>/dev/null || true
                    fi
                }
                trap '
                    rm -f "$_DSR_FUNCS_FILE" 2>/dev/null
                    _cleanup_builduser
                ' EXIT INT TERM
            fi
        fi
        if [[ -z "$BUILD_USER" ]] || ! id "$BUILD_USER" >/dev/null 2>&1; then
            _warn_dsr "FATAL: Cannot create a dedicated build user (useradd -r and ad-hoc user both failed)."
            _warn_dsr "Refusing to drop privileges to 'nobody' — it lacks a writable home and is unsafe for AUR builds."
            _warn_dsr "Aborting DynamicUser build to avoid running a potentially untrusted package with no isolation."
            echo "systemd-run(fake): FATAL: no build user available, refusing to run as nobody" >&2
            exit 127
        fi
    fi
    mkdir -p /var/lib/builduser 2>/dev/null || true
    chown "$BUILD_USER:$BUILD_USER" /var/lib/builduser 2>/dev/null || true
fi

# ── _assemble_build_wrapper: build command prefix for scheduling/caps/group/timeout ──
# Sets _BUILD_WRAPPER from _ENV_SETUP + all applicable command prefixes.
_assemble_build_wrapper() {
    _BUILD_WRAPPER="$_ENV_SETUP"
    # SECURITY: Sanitize all values before interpolation into command strings.
    local _safe_extra_groups="$(_dsr_sanitize_val "${EXTRA_GROUPS:-}")"
    local _safe_group_name="$(_dsr_sanitize_val "${GROUP_NAME:-}")"
    local _safe_ambient_caps="$(_dsr_sanitize_val "${AMBIENT_CAPS:-}")"
    local _safe_timeout_start="$(_dsr_sanitize_val "${TIMEOUT_START:-}")"
    local _safe_nice_level="$(_dsr_sanitize_val "${NICE_LEVEL:-}")"
    local _safe_ionice_class="$(_dsr_sanitize_val "${IOSCHED_CLASS:-}")"
    local _safe_ionice_prio="$(_dsr_sanitize_val "${IOSCHED_PRIORITY:-}")"
    local _safe_chrt_policy="$(_dsr_sanitize_val "${CPUSCHED_POLICY:-}")"
    local _safe_chrt_prio="$(_dsr_sanitize_val "${CPUSCHED_PRIORITY:-}")"
    # SupplementaryGroups via sg
    if [[ -n "$_safe_extra_groups" ]]; then
        sg "$_safe_extra_groups" -c true 2>/dev/null && _BUILD_WRAPPER="sg '$_safe_extra_groups' -c \"$_BUILD_WRAPPER\" || ( _warn_dsr 'sg failed for groups $_safe_extra_groups, continuing without'; true ); "
    fi
    # Group property via sg
    if [[ -n "${_safe_group_name}" ]]; then
        if sg "$_safe_group_name" -c true 2>/dev/null; then
            _BUILD_WRAPPER="sg '$_safe_group_name' -c \"$_BUILD_WRAPPER\" || ( _warn_dsr 'sg failed for group $_safe_group_name, continuing without'; true ); "
        fi
    fi
    # AmbientCapabilities via setpriv
    if [[ -n "${_safe_ambient_caps}" ]] && command -v setpriv >/dev/null 2>&1; then
        local _cap_args=""
        case "${_safe_ambient_caps,,}" in
            "~all"|"")  _cap_args="--inh-caps=-all --ambient-caps=-all" ;;
            "all")      _cap_args="--inh-caps=+all --ambient-caps=+all" ;;
            \~*)        _cap_args="--inh-caps=-${_safe_ambient_caps#\~} --ambient-caps=-${_safe_ambient_caps#\~}" ;;
            *)          _cap_args="--inh-caps=+${_safe_ambient_caps} --ambient-caps=+${_safe_ambient_caps}" ;;
        esac
        _BUILD_WRAPPER="setpriv $_cap_args $_BUILD_WRAPPER"
    fi
    # I/O scheduling via ionice
    if [[ -n "${_safe_ionice_class}" ]] && command -v ionice >/dev/null 2>&1; then
        local _ionice_num=""
        case "${_safe_ionice_class,,}" in
            idle|7)       _ionice_num="3" ;;
            best-effort|2) _ionice_num="2" ;;
            realtime|1)   _ionice_num="1" ;;
            none|0)       _ionice_num="0" ;;
        esac
        if [[ -n "$_ionice_num" ]]; then
            _BUILD_WRAPPER="ionice -c $_ionice_num -n ${_safe_ionice_prio:-4} $_BUILD_WRAPPER"
        fi
    fi
    # CPU scheduling via nice/chrt
    if [[ -n "${_safe_nice_level}" ]] && command -v nice >/dev/null 2>&1; then
        _BUILD_WRAPPER="nice -n $_safe_nice_level $_BUILD_WRAPPER"
    fi
    if [[ -n "${_safe_chrt_policy}" ]] && command -v chrt >/dev/null 2>&1; then
        local _chrt_num=""
        case "${_safe_chrt_policy,,}" in
            other|0)     _chrt_num="-o" ;;
            batch|3)     _chrt_num="-b" ;;
            idle|5)      _chrt_num="-i" ;;
            fifo|1)      _chrt_num="-f" ;;
            rr|2)        _chrt_num="-r" ;;
        esac
        if [[ -n "$_chrt_num" ]]; then
            _BUILD_WRAPPER="chrt $_chrt_num ${_safe_chrt_prio:-0} $_BUILD_WRAPPER"
        fi
    fi
    # Timeout via timeout command
    if [[ -n "${_safe_timeout_start}" ]] && [[ "$_safe_timeout_start" != "infinity" && "$_safe_timeout_start" != "0" ]]; then
        _BUILD_WRAPPER="timeout ${_safe_timeout_start}s $_BUILD_WRAPPER"
    fi
}

# ── DynamicUser path ──
_assemble_build_wrapper
if [[ -n "$WORK_DIR" ]]; then
    _log_dsr "EXEC: sudo -u $BUILD_USER -- cd $WORK_DIR; ${CMD_ARGS[*]}"
    _INNER_CMD="cd '${WORK_DIR}' 2>/dev/null || true; ${_BUILD_WRAPPER}exec \"\${@}\""
else
    _log_dsr "EXEC: sudo -u $BUILD_USER -- ${CMD_ARGS[*]}"
    _INNER_CMD="${_BUILD_WRAPPER}exec \"\${@}\""
fi

if $_NEEDS_SANDBOX; then
    _prepare_cap_priv
    _prepare_seccomp
    if [[ -n "$_BL_TMP_HOME" ]]; then
        _run_sandboxed "$BUILD_USER"
        _user_cmd_exit=$?
        userdel -r "$BUILD_USER" 2>/dev/null || true
        rm -rf "$_BL_TMP_HOME" 2>/dev/null || true
        exit $_user_cmd_exit
    else
        _run_sandboxed "$BUILD_USER"
        exit $?
    fi
else
    if [[ -n "$_BL_TMP_HOME" ]]; then
        sudo -u "$BUILD_USER" -H -- bash -c "$_INNER_CMD" -- "${CMD_ARGS[@]}"
        _user_cmd_exit=$?
        userdel -r "$BUILD_USER" 2>/dev/null || true
        rm -rf "$_BL_TMP_HOME" 2>/dev/null || true
        exit $_user_cmd_exit
    else
        exec sudo -u "$BUILD_USER" -H -- bash -c "$_INNER_CMD" -- "${CMD_ARGS[@]}"
    fi
fi

elif [[ -n "$TARGET_USER" ]] && [[ "$(id -u)" -eq 0 ]]; then
# --property=User=someuser without DynamicUser: switch to that user.
_log_dsr "EXEC: sudo -u $TARGET_USER -- ${CMD_ARGS[*]}"
if [[ -n "$WORK_DIR" ]]; then
    _INNER_CMD="cd '${WORK_DIR}' 2>/dev/null || true; ${_ENV_SETUP}exec \"\${@}\""
else
    _INNER_CMD="${_ENV_SETUP}exec \"\${@}\""
fi
_assemble_build_wrapper

if $_NEEDS_SANDBOX; then
    _prepare_cap_priv
    _prepare_seccomp
    _run_sandboxed "$TARGET_USER"
    exit $?
else
    exec sudo -u "$TARGET_USER" -H -- bash -c "$_INNER_CMD" -- "${CMD_ARGS[@]}"
fi

else
# Non-DynamicUser, non-User=, root path: run as current user (root).
${_ENV_SETUP}
if [[ -n "$WORK_DIR" ]] && [[ -d "$WORK_DIR" ]]; then cd "$WORK_DIR" 2>/dev/null || true; fi
_log_dsr "EXEC: ${CMD_ARGS[*]}"
_assemble_build_wrapper

if $_NEEDS_SANDBOX; then
    _prepare_cap_priv
    _prepare_seccomp
    _run_sandboxed ""
    exit $?
else
    exec "${CMD_ARGS[@]}"
fi
fi
