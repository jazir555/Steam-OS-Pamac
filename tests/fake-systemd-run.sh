#!/bin/bash
# Fake systemd-run v3.0 for non-systemd containers (Distrobox).
# Mimics systemd-run for Pamac/makepkg DynamicUser AUR builds with full sandboxing.
# Uses bubblewrap (bwrap) as primary sandbox engine, falling back to unshare.
# Supports: --user, --scope, DynamicUser (yes/true/1/on), --property=*, --setenv.
# Logs diagnostics to /tmp/systemd-run-fake.log; warns on unrecognized properties.

_DSR_LOG="/tmp/systemd-run-fake.log"
DSR_VERSION="3.0"
DSR_SECCOMP_VERSION_HASH="sha256:d3d59c0b9a1e8f7c2a6b5e4f3d8c7a9b0e1f2a3c4d5e6f7a8b9c0d1e2f3a4"
_DSR_STRICT_SECURITY="${_STRICT_SECURITY_MODE:-false}"
_log_dsr() { echo "[$(date '+%H:%M:%S')] $*" >> "$_DSR_LOG" 2>/dev/null; }
_warn_dsr() { echo "systemd-run(fake): WARNING: $*" >> "$_DSR_LOG" 2>/dev/null; echo "systemd-run(fake): WARNING: $*" >&2 2>/dev/null || true; }

_resolve_host_user() {
    if [[ -n "${PAMAC_HOST_USER:-}" ]] && id "${PAMAC_HOST_USER:-}" >/dev/null 2>&1; then
        echo "$PAMAC_HOST_USER"; return 0
    fi
    if [[ -n "${SUDO_USER:-}" ]] && id "${SUDO_USER:-}" >/dev/null 2>&1; then
        echo "$SUDO_USER"; return 0
    fi
    for _h in /home/*; do
        local _u; _u=$(basename "$_h")
        if id "$_u" >/dev/null 2>&1 && [[ "$(stat -c '%u' "$_h" 2>/dev/null||echo 0)" -ge 1000 ]]; then
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

_cleanup_orphaned_buildusers() {
    local _orphan_users=""
    _orphan_users=$(getent passwd 2>/dev/null | awk -F: '$1 ~ /^_brecover/ { print $1 }' || true)
    for _ou in $_orphan_users; do
        _warn_dsr "Cleaning up orphaned build user: $_ou"
        userdel -r "$_ou" 2>/dev/null || userdel "$_ou" 2>/dev/null || true
    done
    for _dir in /var/tmp/builduser-home-*; do
        [[ -d "$_dir" ]] || continue
        if [[ "$(stat -c '%U' "$_dir" 2>/dev/null || echo root)" == "root" ]]; then
            _warn_dsr "Removing orphaned build-user home: $_dir"
            rm -rf "$_dir" 2>/dev/null || true
        fi
    done
    local _stale_helper="/tmp/.dsr-seccomp-helper"
    if [[ -f "$_stale_helper" ]] && ! "$_stale_helper" --version-check 2>/dev/null; then
        _warn_dsr "Removing stale seccomp helper (version mismatch)"
        rm -f "$_stale_helper" 2>/dev/null || true
    fi
}
_cleanup_orphaned_buildusers

for _a in "$@"; do
    case "$_a" in
        --help|-h) echo "systemd-run (fake) v${DSR_VERSION}: Mimics systemd-run for DynamicUser AUR builds in non-systemd containers."; echo ""; echo "ENFORCED via bwrap (bubblewrap) or unshare + bind mounts + capsh/setpriv + seccomp-BPF:"; echo "  Filesystem: ProtectSystem, ProtectHome, PrivateTmp, PrivateDevices,"; echo "              ReadWritePaths, ReadOnlyPaths, InaccessiblePaths"; echo "  Network:    PrivateNetwork (--unshare-net with bwrap)"; echo "  Privileges: NoNewPrivileges, CapabilityBoundingSet (capsh preferred)"; echo "  Seccomp:    MemoryDenyWriteExecute (blocks mprotect W+X),"; echo "              RestrictSUIDSGID (blocks setuid/setgid family),"; echo "              ProtectKernelModules (blocks init/delete_module)"; echo "  Runtime:    sandbox integrity verified after applying restrictions"; echo "  DynamicUser: isolated build user with private home under /var/tmp"; echo "  User, Environment, EnvironmentFile, CacheDirectory, WorkingDirectory,"; echo "              UMask, SupplementaryGroups"; echo "  --user:     run as host user (non-root invocation)"; echo "  --scope:    direct execution without transient unit creation"; echo ""; echo "BEST-EFFORT (logged): SystemCallFilter, RestrictNamespaces, LockPersonality,"; echo "  RestrictRealtime, RestrictAddressFamilies, ProtectClock,"; echo "  ProtectKernelTunables, ProtectKernelLogs, ProtectControlGroups,"; echo "  ProtectHostname, RestrictFileSystems"; echo ""; echo "Sandbox: bwrap (preferred) or unshare --mount --net + bind mounts + setpriv/capsh + seccomp helper (requires gcc)."; echo "  HOST_USER resolved dynamically from PAMAC_HOST_USER, SUDO_USER, or passwd."; echo "  Resource/accounting/logging/Condition/Assert/Timeout: recognized, silently dropped."; echo ""; echo "Use --strict-security on the installer to disable this wrapper entirely."; exit 0 ;;
        --version) echo "systemd-run (fake) v${DSR_VERSION} (SteamOS-Pamac)"; exit 0 ;;
    esac
done

DYNAMIC_USER=false
USER_MODE=false
SCOPE_MODE=false
CACHE_DIR=""
WORK_DIR=""
SKIP_NEXT=false
PIPE_MODE=false
WAIT_MODE=false
DESCRIPTION=""
UNRECOGNIZED_PROPS=()
CMD_ARGS=()
EXTRA_ENV=()
EXTRA_GROUPS=""
TARGET_USER=""
ENV_FILES=()
SET_UMASK=""
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
--property=Group=*) continue ;;
--property=SupplementaryGroups=*) EXTRA_GROUPS="${arg#--property=SupplementaryGroups=}"; continue ;;
--property=AmbientCapabilities=*) _log_dsr "Sandbox: AmbientCapabilities (best-effort via setpriv): $arg"; continue ;;
--property=EnvironmentFile=*) ENV_FILES+=("${arg#--property=EnvironmentFile=}"); continue ;;
--property=Ephemeral=*) continue ;;
--property=Slice=*) continue ;;
--property=IOSchedulingClass=*) continue ;;
--property=CPUSchedulingPolicy=*) continue ;;
--property=RestrictNamespaces=*) RESTRICT_NAMESPACES="${arg#--property=RestrictNamespaces=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=RestrictSUIDSGID=*) RESTRICT_SUID_SGID="${arg#--property=RestrictSUIDSGID=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=LockPersonality=*) LOCK_PERSONALITY="${arg#--property=LockPersonality=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=RestrictRealtime=*) RESTRICT_REALTIME="${arg#--property=RestrictRealtime=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=RestrictAddressFamilies=*) RESTRICT_ADDRESS_FAMILIES="${arg#--property=RestrictAddressFamilies=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=RemoveIPC=*) continue ;;
--property=UMask=*) SET_UMASK="${arg#--property=UMask=}"; continue ;;
--property=KeyringMode=*) continue ;;
--property=ProtectClock=*) PROTECT_CLOCK="${arg#--property=ProtectClock=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=ProtectKernelTunables=*) PROTECT_KERNEL_TUNABLES="${arg#--property=ProtectKernelTunables=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=ProtectKernelModules=*) PROTECT_KERNEL_MODULES="${arg#--property=ProtectKernelModules=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=ProtectKernelLogs=*) PROTECT_KERNEL_LOGS="${arg#--property=ProtectKernelLogs=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=ProtectControlGroups=*) PROTECT_CONTROL_GROUPS="${arg#--property=ProtectControlGroups=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=ProtectHostname=*) PROTECT_HOSTNAME="${arg#--property=ProtectHostname=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=ProtectProc=*) _log_dsr "Sandbox: ProtectProc (best-effort): $arg"; continue ;;
--property=ProcSubset=*) _log_dsr "Sandbox: ProcSubset (best-effort): $arg"; continue ;;
--property=MemorySwapMax=*) continue ;;
--property=CPUQuota=*) continue ;;
--property=DeviceAllow=*) continue ;;
--property=DevicePolicy=*) continue ;;
--property=RestrictFileSystems=*) RESTRICT_FILE_SYSTEMS="${arg#--property=RestrictFileSystems=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=SocketBindDeny=*) continue ;;
--property=SocketBindAllow=*) continue ;;
--property=IPAddressAllow=*) continue ;;
--property=IPAddressDeny=*) continue ;;
--property=PrivateDevices=*) PRIVATE_DEVICES="${arg#--property=PrivateDevices=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=PrivateMounts=*) _log_dsr "Sandbox: PrivateMounts (default in mount namespace): $arg"; continue ;;
--property=PrivateNetwork=*) PRIVATE_NETWORK="${arg#--property=PrivateNetwork=}"; _log_dsr "Sandbox: $arg"; continue ;;
--property=PrivateUsers=*) _log_dsr "Sandbox: PrivateUsers (best-effort): $arg"; continue ;;
--property=MountFlags=*) _log_dsr "Sandbox: MountFlags (default in mount namespace): $arg"; continue ;;
--property=MountAPIVFS=*) _log_dsr "Sandbox: MountAPIVFS (default in mount namespace): $arg"; continue ;;
--property=ReadWritePaths=*) READ_WRITE_PATHS+=("${arg#--property=ReadWritePaths=}"); _log_dsr "Sandbox: $arg"; continue ;;
--property=ReadOnlyPaths=*) READ_ONLY_PATHS+=("${arg#--property=ReadOnlyPaths=}"); _log_dsr "Sandbox: $arg"; continue ;;
--property=InaccessiblePaths=*) INACCESSIBLE_PATHS+=("${arg#--property=InaccessiblePaths=}"); _log_dsr "Sandbox: $arg"; continue ;;
--property=ExecPaths=*) READ_WRITE_PATHS+=("${arg#--property=ExecPaths=}"); _log_dsr "Sandbox: ExecPaths->ReadWritePaths: $arg"; continue ;;
--property=NoExecPaths=*) READ_ONLY_PATHS+=("${arg#--property=NoExecPaths=}"); _log_dsr "Sandbox: NoExecPaths->ReadOnlyPaths: $arg"; continue ;;
--property=ConfigurationDirectory=*) continue ;;
--property=RootDirectory=*) _log_dsr "Sandbox: RootDirectory (best-effort): $arg"; continue ;;
--property=RootImage=*) _log_dsr "Sandbox: RootImage (best-effort): $arg"; continue ;;
--property=RootHash=*) _log_dsr "Sandbox: RootHash (best-effort): $arg"; continue ;;
--property=RootVerity=*) _log_dsr "Sandbox: RootVerity (best-effort): $arg"; continue ;;
--property=MountImages=*) _log_dsr "Sandbox: MountImages (best-effort): $arg"; continue ;;
--property=ExtensionImages=*) _log_dsr "Sandbox: ExtensionImages (best-effort): $arg"; continue ;;
--property=NamespacePath=*) _log_dsr "Sandbox: NamespacePath (best-effort): $arg"; continue ;;
--property=NetworkNamespacePath=*) _log_dsr "Sandbox: NetworkNamespacePath (best-effort): $arg"; continue ;;
--property=LogNamespace=*) continue ;;
--property=InheritDescriptors=*) continue ;;
--property=SecureBits=*) _log_dsr "Sandbox: SecureBits (best-effort): $arg"; continue ;;
--property=Environment=*) EXTRA_ENV+=("-e" "${arg#--property=Environment=}"); continue ;;
--property=PassEnvironment=*) continue ;;
--property=UnsetEnvironment=*) continue ;;
--property=Personality=*) _log_dsr "Sandbox: Personality (best-effort): $arg"; continue ;;
--property=SystemCallArchitectures=*) _log_dsr "Sandbox: SystemCallArchitectures (best-effort): $arg"; continue ;;
--property=SystemCallErrorNumber=*) _log_dsr "Sandbox: SystemCallErrorNumber (best-effort): $arg"; continue ;;
--property=SystemCallLog=*) _log_dsr "Sandbox: SystemCallLog (best-effort): $arg"; continue ;;
--property=TimerSlackNSec=*) continue ;;
--property=SetLoginEnvironment=*) continue ;;
--property=Delegate=*) continue ;;
--property=DisableExtraFileDescriptors=*) _log_dsr "Sandbox: DisableExtraFileDescriptors (best-effort): $arg"; continue ;;
--property=CoredumpReceive=*) _log_dsr "Sandbox: CoredumpReceive (best-effort): $arg"; continue ;;
--property=DynamicUser=*) if [[ "${arg#--property=DynamicUser=}" =~ ^(yes|true|1|on)$ ]]; then DYNAMIC_USER=true; fi; _log_dsr "DynamicUser: ${arg#--property=DynamicUser=} (detected as: $DYNAMIC_USER)"; continue ;;
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
--property=OOMScoreAdjust=*) continue ;;
--property=OOMPolicy=*) continue ;;
--property=OOMScoreAdjustPerWeight=*) continue ;;
--property=MemoryPressureWatch=*) continue ;;
--property=MemoryPressureThresholdSec=*) continue ;;
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
--property=*) UNRECOGNIZED_PROPS+=("$arg"); continue ;;
--property) SKIP_NEXT=true; continue ;;
--user) USER_MODE=true; continue ;;
--scope) SCOPE_MODE=true; continue ;;
--uid=*|--gid=*) continue ;;
--setenv=*) EXTRA_ENV+=("-e" "${arg#--setenv=}"); continue ;;
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

_ENV_SETUP=""
for _ef in "${ENV_FILES[@]}"; do
    if [[ -f "$_ef" ]]; then
        _ENV_SETUP="${_ENV_SETUP}set -a; source '${_ef}' 2>/dev/null || true; set +a; "
        _log_dsr "Sourcing EnvironmentFile: $_ef"
    else
        _warn_dsr "EnvironmentFile not found: $_ef (continuing -- may be created by the build)"
    fi
done
for _ee in "${EXTRA_ENV[@]}"; do
    _ENV_SETUP="${_ENV_SETUP}export '${_ee}' 2>/dev/null || true; "
    _log_dsr "Setting env: $_ee"
done
if [[ -n "$SET_UMASK" ]]; then
    _ENV_SETUP="${_ENV_SETUP}umask ${SET_UMASK} 2>/dev/null || true; "
    _log_dsr "Setting umask: $SET_UMASK"
fi

_SGROUP_OPTS=()
if [[ -n "$EXTRA_GROUPS" ]]; then
    _SGROUP_OPTS=(-g "$EXTRA_GROUPS")
    _log_dsr "SupplementaryGroups requested: $EXTRA_GROUPS (best-effort)"
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
if $_NEEDS_SANDBOX; then
    _log_dsr "Sandbox restrictions active: ProtectSystem=$PROTECT_SYSTEM ProtectHome=$PROTECT_HOME PrivateTmp=$PRIVATE_TMP PrivateDevices=$PRIVATE_DEVICES"
fi

_build_bwrap_args() {
    command -v bwrap >/dev/null 2>&1 || return 1
    _DSR_BWRAP_ARGS=()
    _DSR_BWRAP_ARGS+=(--unshare-pid --dev /dev --proc /proc --tmpfs /tmp)
    if [[ "$PRIVATE_TMP" == "yes" ]]; then
        _DSR_BWRAP_ARGS+=(--tmpfs /var/tmp)
        _log_dsr "bwrap: PrivateTmp (fresh /tmp and /var/tmp)"
    else
        _DSR_BWRAP_ARGS+=(--bind /var/tmp /var/tmp)
    fi
    if [[ "$PRIVATE_DEVICES" == "yes" ]]; then
        _DSR_BWRAP_ARGS+=(--dev /dev)
        _log_dsr "bwrap: PrivateDevices (minimal /dev)"
    fi
    if [[ "$PROTECT_HOME" == "yes" ]]; then
        _DSR_BWRAP_ARGS+=(--tmpfs /home)
        _log_dsr "bwrap: ProtectHome=yes (/home->tmpfs)"
    elif [[ "$PROTECT_HOME" == "read-only" ]]; then
        _DSR_BWRAP_ARGS+=(--ro-bind /home /home)
        _log_dsr "bwrap: ProtectHome=read-only"
    else
        _DSR_BWRAP_ARGS+=(--bind /home /home)
    fi
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
    for _wp in /run /var/cache; do
        _DSR_BWRAP_ARGS+=(--bind "$_wp" "$_wp")
    done
    [[ -n "$WORK_DIR" ]] && { mkdir -p "$WORK_DIR" 2>/dev/null || true; _DSR_BWRAP_ARGS+=(--bind "$WORK_DIR" "$WORK_DIR"); }
    [[ -n "$CACHE_DIR" ]] && { _DSR_BWRAP_ARGS+=(--bind "/var/cache/$CACHE_DIR" "/var/cache/$CACHE_DIR"); }
    for _rwp in "${READ_WRITE_PATHS[@]}"; do
        [[ -z "$_rwp" ]] && continue
        mkdir -p "$_rwp" 2>/dev/null || true
        _DSR_BWRAP_ARGS+=(--bind "$_rwp" "$_rwp")
        _log_dsr "bwrap: ReadWritePaths: $_rwp"
    done
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
    for _iap in "${INACCESSIBLE_PATHS[@]}"; do
        [[ -z "$_iap" ]] && continue
        if [[ -d "$_iap" ]]; then
            _DSR_BWRAP_ARGS+=(--bind /var/empty "$_iap")
        else
            _DSR_BWRAP_ARGS+=(--bind /dev/null "$_iap")
        fi
        mkdir -p /var/empty 2>/dev/null || true
        _log_dsr "bwrap: InaccessiblePaths: $_iap"
    done
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
    for _bp in "${BIND_PATHS[@]}"; do
        [[ -z "$_bp" ]] && continue
        local _src="${_bp%%:*}"
        local _dst="${_bp#*:}"
        [[ "$_dst" == "$_src" ]] && _dst="$_src"
        [[ -z "$_src" || -z "$_dst" ]] && continue
        mkdir -p "$_src" "$_dst" 2>/dev/null || true
        _DSR_BWRAP_ARGS+=(--bind "$_src" "$_dst")
        _log_dsr "bwrap: BindPaths: $_src -> $_dst"
    done
    for _brp in "${BIND_RO_PATHS[@]}"; do
        [[ -z "$_brp" ]] && continue
        local _src="${_brp%%:*}"
        local _dst="${_brp#*:}"
        [[ "$_dst" == "$_src" ]] && _dst="$_src"
        [[ -z "$_src" || -z "$_dst" ]] && continue
        mkdir -p "$_src" "$_dst" 2>/dev/null || true
        _DSR_BWRAP_ARGS+=(--ro-bind "$_src" "$_dst")
        _log_dsr "bwrap: BindReadOnlyPaths: $_src -> $_dst"
    done
    if [[ "$PRIVATE_NETWORK" == "yes" ]]; then
        _DSR_BWRAP_ARGS+=(--unshare-net)
        _log_dsr "bwrap: PrivateNetwork (network namespace unshared)"
    fi
    if [[ "$NO_NEW_PRIVS" == "yes" ]]; then
        _DSR_BWRAP_ARGS+=(--new-session)
        _log_dsr "bwrap: NoNewPrivileges (--new-session)"
    fi
    return 0
}

_sandbox_verify() {
    _sandbox_verified=true
    if [[ -n "$PROTECT_SYSTEM" ]]; then
        if touch /.sandbox-verify-test 2>/dev/null; then
            rm -f /.sandbox-verify-test 2>/dev/null || true
            _sandbox_verified=false
            _warn_dsr "VERIFICATION FAILED: / is still writable -- sandbox restrictions may not have applied"
            _warn_dsr "Builds may run with weaker isolation than expected."
        else
            _log_dsr "  / is read-only (ProtectSystem verified)"
        fi
    fi
    if [[ "$PROTECT_HOME" == "yes" ]]; then
        if [[ -n "$(ls -A /home 2>/dev/null)" ]]; then
            _warn_dsr "VERIFICATION WARNING: /home is not empty after ProtectHome=yes"
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
    if $_sandbox_verified; then
        _log_dsr "Sandbox verification passed"
    fi
}

_apply_sandbox() {
    if [[ -n "$PROTECT_SYSTEM" ]]; then
        _log_dsr "Applying ProtectSystem=$PROTECT_SYSTEM"
        if mount --bind / / 2>/dev/null && mount -o remount,bind,ro / 2>/dev/null; then
            _log_dsr "  / made read-only"
        else
            _warn_dsr "  Failed to make / read-only (mount namespace may not support this)"
        fi
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
        if [[ "$PROTECT_SYSTEM" == "full" ]] || [[ "$PROTECT_SYSTEM" == "true" ]]; then
            for _rp in /etc /usr /boot; do
                [[ -e "$_rp" ]] || continue
                if mount --bind "$_rp" "$_rp" 2>/dev/null; then
                    mount -o remount,bind,ro "$_rp" 2>/dev/null \
                        || mount -o remount,bind "$_rp" 2>/dev/null
                fi
            done
        fi
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
        for _rwp in "${READ_WRITE_PATHS[@]}"; do
            [[ -e "$_rwp" ]] || mkdir -p "$_rwp" 2>/dev/null || continue
            mount --bind "$_rwp" "$_rwp" 2>/dev/null && mount -o remount,bind,rw "$_rwp" 2>/dev/null
        done
    fi
    if [[ -n "$PROTECT_HOME" ]]; then
        _log_dsr "Applying ProtectHome=$PROTECT_HOME"
        if [[ "$PROTECT_HOME" == "yes" ]]; then
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
    if [[ -n "$PRIVATE_TMP" ]] && [[ "$PRIVATE_TMP" == "yes" ]]; then
        _log_dsr "Applying PrivateTmp=yes"
        local _fresh_tmp
        _fresh_tmp=$(mktemp -d /tmp/.private-tmp-XXXXXX 2>/dev/null) || _fresh_tmp=""
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
    if [[ -n "$PRIVATE_DEVICES" ]] && [[ "$PRIVATE_DEVICES" == "yes" ]]; then
        _log_dsr "Applying PrivateDevices=yes"
        local _dev_dir
        _dev_dir=$(mktemp -d /tmp/.private-dev-XXXXXX 2>/dev/null) || _dev_dir=""
        if [[ -n "$_dev_dir" ]]; then
            mount -t tmpfs tmpfs "$_dev_dir" 2>/dev/null || { rm -rf "$_dev_dir"; return; }
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
    for _sd in "${STATE_DIRECTORIES[@]}"; do
        local _sd_path="/var/lib/$_sd"
        mkdir -p "$_sd_path" 2>/dev/null || continue
        chown "${BUILD_USER:-root}:${BUILD_USER:-root}" "$_sd_path" 2>/dev/null || true
        _log_dsr "  StateDirectory: $_sd_path"
    done
    for _ld in "${LOGS_DIRECTORIES[@]}"; do
        local _ld_path="/var/log/$_ld"
        mkdir -p "$_ld_path" 2>/dev/null || continue
        chown "${BUILD_USER:-root}:${BUILD_USER:-root}" "$_ld_path" 2>/dev/null || true
        _log_dsr "  LogsDirectory: $_ld_path"
    done
    for _rd in "${RUNTIME_DIRECTORIES[@]}"; do
        local _rd_path="/run/$_rd"
        mkdir -p "$_rd_path" 2>/dev/null || continue
        chown "${BUILD_USER:-root}:${BUILD_USER:-root}" "$_rd_path" 2>/dev/null || true
        chmod 0755 "$_rd_path" 2>/dev/null || true
        _log_dsr "  RuntimeDirectory: $_rd_path"
    done
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
    for _bp in "${BIND_PATHS[@]}"; do
        local _src="${_bp%%:*}"
        local _dst="${_bp#*:}"
        [[ -z "$_src" || -z "$_dst" ]] && continue
        mkdir -p "$_src" "$_dst" 2>/dev/null || continue
        mount --bind "$_src" "$_dst" 2>/dev/null \
            && _log_dsr "  BindPaths: $_src -> $_dst" \
            || _warn_dsr "  Failed BindPaths: $_src -> $_dst"
    done
    for _brp in "${BIND_RO_PATHS[@]}"; do
        local _src="${_brp%%:*}"
        local _dst="${_brp#*:}"
        [[ -z "$_src" || -z "$_dst" ]] && continue
        mkdir -p "$_src" "$_dst" 2>/dev/null || continue
        if mount --bind "$_src" "$_dst" 2>/dev/null; then
            mount -o remount,bind,ro "$_dst" 2>/dev/null \
                && _log_dsr "  BindReadOnlyPaths: $_src -> $_dst" \
                || _warn_dsr "  Failed to make read-only: $_dst"
        else
            _warn_dsr "  Failed BindReadOnlyPaths: $_src -> $_dst"
        fi
    done
    if [[ -n "$NO_NEW_PRIVS" ]] && [[ "$NO_NEW_PRIVS" == "yes" ]]; then
        _log_dsr "Applying NoNewPrivileges=yes"
        export _DSR_NO_NEW_PRIVS=true
    fi
    if [[ -n "$CAP_BOUNDING_SET" ]]; then
        _log_dsr "Applying CapabilityBoundingSet=$CAP_BOUNDING_SET"
        if command -v capsh >/dev/null 2>&1; then
            _cap_str_n="${CAP_BOUNDING_SET//cap_/CAP_}"
            case "$_cap_str_n" in
                "~all"|"")
                    export _DSR_CAPSH_ARGS="--drop=all"
                    _log_dsr "  Capability bounding set: capsh --drop=all" ;;
                "all")
                    unset _DSR_CAPSH_ARGS ;;
                \~*)
                    _d="${_cap_str_n#\~}"
                    export _DSR_CAPSH_ARGS="--drop=${_d//:/,}"
                    _log_dsr "  Capability bounding set: capsh ${_DSR_CAPSH_ARGS}" ;;
                *)
                    export _DSR_CAPSH_ARGS="--drop=all"
                    _log_dsr "  Capability bounding set: capsh --drop=all" ;;
            esac
        elif command -v setpriv >/dev/null 2>&1; then
            _warn_dsr "  capsh not available -- using setpriv fallback (inheritable set only)"
            _cap_str_n="${CAP_BOUNDING_SET//cap_/CAP_}"
            case "$_cap_str_n" in
                "~all"|"")
                    export _DSR_CAP_ARGS="--inh-caps=-all" ;;
                "all")
                    unset _DSR_CAP_ARGS ;;
                \~*)
                    _d="${_cap_str_n#\~}"
                    _caps=""
                    for _c in ${_d//:/ }; do
                        [[ -n "$_caps" ]] && _caps="${_caps},-${_c,,}" || _caps="-${_c,,}"
                    done
                    [[ -n "$_caps" ]] && export _DSR_CAP_ARGS="--inh-caps=${_caps}" ;;
                *)
                    _caps=""
                    for _c in ${_cap_str_n//:/ }; do
                        [[ -n "$_caps" ]] && _caps="${_caps},+${_c,,}" || _caps="+${_c,,}"
                    done
                    [[ -n "$_caps" ]] && export _DSR_CAP_ARGS="--inh-caps=${_caps}" ;;
            esac
            [[ -n "${_DSR_CAP_ARGS:-}" ]] && _log_dsr "  Capability bounding set: setpriv ${_DSR_CAP_ARGS}"
        else
            _warn_dsr "  Neither capsh nor setpriv available -- cannot enforce CapabilityBoundingSet"
        fi
    fi
    _sandbox_verify
}

_compile_seccomp_helper() {
    local _helper_bin="/tmp/.dsr-seccomp-helper"
    if [[ -f "$_helper_bin" ]] && [[ -x "$_helper_bin" ]]; then
        if "$_helper_bin" --version-check 2>/dev/null; then
            echo "$_helper_bin"
            return 0
        fi
        _warn_dsr "Cached seccomp helper is stale (version mismatch), recompiling..."
        rm -f "$_helper_bin" 2>/dev/null || true
    fi
    if ! command -v gcc >/dev/null 2>&1; then
        _warn_dsr "gcc not available -- cannot compile seccomp helper (install base-devel)"
        return 1
    fi
    local _helper_src="/tmp/.dsr-seccomp-helper.c"
    cat > "$_helper_src" << 'SECCOMP_C'
#define DSR_SECCOMP_VER "dsr-seccomp-v3.0"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <stddef.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <sys/prctl.h>
#include <sys/syscall.h>

static void apply_filters(int mdwx) {
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
        fprintf(stderr, "seccomp: PR_SET_NO_NEW_PRIVS failed\n");
        return;
    }
    {
        struct sock_filter f[] = {
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,nr)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setuid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_EPERM&SECCOMP_RET_DATA)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setgid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_EPERM&SECCOMP_RET_DATA)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setreuid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_EPERM&SECCOMP_RET_DATA)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setregid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_EPERM&SECCOMP_RET_DATA)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setresuid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_EPERM&SECCOMP_RET_DATA)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setresgid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_EPERM&SECCOMP_RET_DATA)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setfsuid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_EPERM&SECCOMP_RET_DATA)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setfsgid, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_EPERM&SECCOMP_RET_DATA)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_setgroups, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_EPERM&SECCOMP_RET_DATA)),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
    }
    {
        struct sock_filter f[] = {
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,nr)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_init_module, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_EPERM&SECCOMP_RET_DATA)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_delete_module, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_EPERM&SECCOMP_RET_DATA)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_finit_module, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_EPERM&SECCOMP_RET_DATA)),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
    }
    if (mdwx) {
        struct sock_filter f[] = {
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,nr)),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_mprotect, 0, 5),
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,args[2])),
            BPF_JUMP(BPF_JMP|BPF_JSET|BPF_K, 0x2, 0, 2),
            BPF_JUMP(BPF_JMP|BPF_JSET|BPF_K, 0x4, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_EPERM&SECCOMP_RET_DATA)),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
            BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_pkey_mprotect, 0, 4),
            BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data,args[2])),
            BPF_JUMP(BPF_JMP|BPF_JSET|BPF_K, 0x2, 0, 2),
            BPF_JUMP(BPF_JMP|BPF_JSET|BPF_K, 0x4, 0, 1),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|(SECCOMP_EPERM&SECCOMP_RET_DATA)),
            BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        };
        struct sock_fprog p = { .len=sizeof(f)/sizeof(f[0]), .filter=f };
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &p);
        fprintf(stderr, "seccomp: MemoryDenyWriteExecute applied (mprotect W+X blocked)\n");
    }
}
int main(int argc, char *argv[]) {
    if (argc >= 2 && strcmp(argv[1], "--version-check") == 0) {
        printf("%s\n", DSR_SECCOMP_VER);
        return 0;
    }
    int mdwx = 0, cmd_start = 1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--mdwx") == 0) { mdwx = 1; cmd_start = i+1; }
        else if (strcmp(argv[i], "--seccomp") == 0) { cmd_start = i+1; }
        else if (strcmp(argv[i], "--") == 0) { cmd_start = i+1; break; }
        else break;
    }
    if (cmd_start >= argc) { fprintf(stderr, "seccomp-helper: no command\n"); return 1; }
    apply_filters(mdwx);
    execvp(argv[cmd_start], &argv[cmd_start]);
    perror("execvp");
    return 127;
}
SECCOMP_C
    local _test_src="/tmp/.dsr-toolchain-test.c"
    local _test_bin="/tmp/.dsr-toolchain-test"
    cat > "$_test_src" << 'TOOLCHAIN_TEST'
#include <stdio.h>
#include <stddef.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
int main() {
    struct sock_filter f[] = { BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW) };
    struct sock_fprog p = { .len = 1, .filter = f };
    (void)f; (void)p;
    return 0;
}
TOOLCHAIN_TEST
    if ! gcc -O2 -o "$_test_bin" "$_test_src" 2>/dev/null; then
        _warn_dsr "Toolchain validation failed: gcc cannot compile a minimal seccomp test program."
        _warn_dsr "This may indicate a partial upgrade (compiler vs. headers mismatch)."
        _warn_dsr "Try: pacman -S --noconfirm --needed base-devel gcc glibc"
        rm -f "$_test_src" "$_test_bin"
        return 1
    fi
    rm -f "$_test_src" "$_test_bin"

    if gcc -O2 -o "$_helper_bin" "$_helper_src" 2>/dev/null; then
        rm -f "$_helper_src"
        chmod 755 "$_helper_bin"
        echo "$_helper_bin"
        return 0
    else
        _warn_dsr "Failed to compile seccomp helper (gcc -O2 -static failed)"
        rm -f "$_helper_src" "$_helper_bin"
        return 1
    fi
}

_build_seccomp_args() {
    local _args=""
    if [[ -n "$MEMORY_DENY_WRITE_EXECUTE" ]] || [[ -n "$RESTRICT_SUID_SGID" ]] || \
       [[ -n "$PROTECT_KERNEL_TUNABLES" ]] || [[ -n "$PROTECT_KERNEL_MODULES" ]] || \
       [[ -n "$PROTECT_KERNEL_LOGS" ]] || [[ -n "$PROTECT_CONTROL_GROUPS" ]]; then
        _args="--seccomp"
        [[ "$MEMORY_DENY_WRITE_EXECUTE" == "yes" ]] && _args="$_args --mdwx"
    fi
    echo "$_args"
}

_prepare_seccomp() {
    _SECCOMP_HELPER=""
    _seccomp_args="$(_build_seccomp_args)"
    if [[ -n "$_seccomp_args" ]]; then
        _SECCOMP_HELPER="$(_compile_seccomp_helper)" || _SECCOMP_HELPER=""
        if [[ -z "$_SECCOMP_HELPER" ]] && [[ "$_DSR_STRICT_SECURITY" == "true" ]]; then
            echo "systemd-run(fake): FATAL: seccomp helper compilation failed under --strict-security." >&2
            echo "  Sandboxing properties (MemoryDenyWriteExecute, RestrictSUIDSGID, etc.)" >&2
            echo "  cannot be enforced without the seccomp helper. Aborting to avoid" >&2
            echo "  running with degraded security." >&2
            exit 1
        elif [[ -z "$_SECCOMP_HELPER" ]]; then
            _warn_dsr "WARNING: seccomp helper compilation failed -- seccomp-based sandboxing will NOT be enforced for this build."
            _warn_dsr "  Install base-devel inside the container to enable seccomp sandboxing."
        fi
    fi
}

_prepare_cap_priv() {
    _CAP_PRIV=""
    if [[ -n "${_DSR_CAPSH_ARGS:-}" ]]; then
        _CAP_PRIV="capsh ${_DSR_CAPSH_ARGS} -- "
    elif [[ -n "${_DSR_CAP_ARGS:-}" ]]; then
        _CAP_PRIV="setpriv ${_DSR_CAP_ARGS} -- "
    fi
    _NNP=""
    [[ "${_DSR_NO_NEW_PRIVS:-}" == "true" ]] && _NNP="setpriv --no-new-privs -- "
}

_run_sandboxed_bwrap() {
    local _run_user="$1"; shift
    _build_bwrap_args || return 1
    _log_dsr "Using bwrap as sandbox engine"
    local _inner_cmd
    _inner_cmd="${_BUILD_WRAPPER:-}exec \"\${@}\""
    if [[ -n "$WORK_DIR" ]]; then
        _inner_cmd="cd '${WORK_DIR}' 2>/dev/null || true; ${_inner_cmd}"
    fi
    local _verify_cmd="_sandbox_verify; ${_inner_cmd}"
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

_run_sandboxed_unshare() {
    local _run_user="$1"; shift
    local _unshare_net=""
    [[ -n "$PRIVATE_NETWORK" ]] && _unshare_net="--net"
    _log_dsr "Using unshare --mount as sandbox engine (bwrap unavailable)"
    local _inner_cmd
    _inner_cmd="${_BUILD_WRAPPER:-}exec \"\${@}\""
    if [[ -n "$WORK_DIR" ]]; then
        _inner_cmd="cd '${WORK_DIR}' 2>/dev/null || true; ${_inner_cmd}"
    fi
    local _verify_cmd="_apply_sandbox; ${_inner_cmd}"
    if [[ -n "$_run_user" ]]; then
        if [[ -n "${_SECCOMP_HELPER:-}" ]]; then
            _DSR_SBOX="${_CAP_PRIV}${_NNP}sudo -u '\''$_run_user'\'' -H -- $_SECCOMP_HELPER $_seccomp_args -- bash -c '\''$_verify_cmd'\'' -- ${CMD_ARGS[*]}"
        else
            _DSR_SBOX="${_CAP_PRIV}${_NNP}sudo -u '\''$_run_user'\'' -H -- bash -c '\''$_verify_cmd'\'' -- ${CMD_ARGS[*]}"
        fi
        unshare --mount $_unshare_net --propagation slave bash -c "$_DSR_SBOX"
    else
        if [[ -n "${_SECCOMP_HELPER:-}" ]]; then
            unshare --mount $_unshare_net --propagation slave bash -c "
                _apply_sandbox
                ${_NNP}${_CAP_PRIV}$_SECCOMP_HELPER $_seccomp_args -- exec \"\${@}\"
            " -- "${CMD_ARGS[@]}"
        else
            unshare --mount $_unshare_net --propagation slave bash -c "
                _apply_sandbox
                ${_NNP}${_CAP_PRIV}exec \"\${@}\"
            " -- "${CMD_ARGS[@]}"
        fi
    fi
}

_run_sandboxed() {
    local _run_user="$1"
    if _build_bwrap_args 2>/dev/null; then
        _run_sandboxed_bwrap "$_run_user"
        return $?
    else
        _run_sandboxed_unshare "$_run_user"
        return $?
    fi
}

if $SCOPE_MODE && ! $DYNAMIC_USER; then
    _log_dsr "SCOPE mode: direct execution without sandbox/unit creation"
    ${_ENV_SETUP}
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && cd "$WORK_DIR" 2>/dev/null || true
    if [[ -n "$TARGET_USER" ]] && [[ "$(id -u)" -eq 0 ]]; then
        exec sudo -u "$TARGET_USER" -H -- bash -c "${_ENV_SETUP}exec \"\${@}\"" -- "${CMD_ARGS[@]}"
    fi
    exec "${CMD_ARGS[@]}"
fi

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
BUILD_USER="_builduser"
_BL_TMP_HOME=""
if ! id "$BUILD_USER" >/dev/null 2>&1; then
    if ! useradd -r -d /var/lib/builduser -s /usr/bin/nologin "$BUILD_USER" 2>/dev/null; then
        _warn_dsr "useradd -r failed -- trying ad-hoc non-root build user as fallback"
        chmod +t /var/tmp 2>/dev/null || true
        _bl_tmp=$(mktemp -d /var/tmp/builduser-home-XXXXXX) || _bl_tmp=""
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
                rmdir "$_bl_tmp" 2>/dev/null || true
                BUILD_USER=""
            else
                _BL_TMP_HOME="$_bl_tmp"
                _log_dsr "Ad-hoc build user $_BL_TMP_HOME created (isolated from host mounts)"
                _cleanup_builduser() {
                    if [[ -n "$_BL_TMP_HOME" ]]; then
                        userdel -r "$BUILD_USER" 2>/dev/null || true
                        rm -rf "$_BL_TMP_HOME" 2>/dev/null || true
                    fi
                }
                trap _cleanup_builduser EXIT INT TERM
            fi
        fi
        if [[ -z "$BUILD_USER" ]] || ! id "$BUILD_USER" >/dev/null 2>&1; then
            _warn_dsr "FATAL: Cannot create a dedicated build user (useradd -r and ad-hoc user both failed)."
            _warn_dsr "Refusing to drop privileges to 'nobody' -- it lacks a writable home and is unsafe for AUR builds."
            _warn_dsr "Aborting DynamicUser build to avoid running a potentially untrusted package with no isolation."
            echo "systemd-run(fake): FATAL: no build user available, refusing to run as nobody" >&2
            exit 127
        fi
    fi
    mkdir -p /var/lib/builduser 2>/dev/null || true
    chown "$BUILD_USER:$BUILD_USER" /var/lib/builduser 2>/dev/null || true
fi

_BUILD_WRAPPER="$_ENV_SETUP"
if [[ -n "$EXTRA_GROUPS" ]]; then
    sg "$EXTRA_GROUPS" -c true 2>/dev/null && _BUILD_WRAPPER="sg '$EXTRA_GROUPS' -c \"$_BUILD_WRAPPER\" || ( _warn_dsr 'sg failed for groups $EXTRA_GROUPS, continuing without'; true ); "
fi

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
_log_dsr "EXEC: sudo -u $TARGET_USER -- ${CMD_ARGS[*]}"
if [[ -n "$WORK_DIR" ]]; then
    _INNER_CMD="cd '${WORK_DIR}' 2>/dev/null || true; ${_ENV_SETUP}exec \"\${@}\""
else
    _INNER_CMD="${_ENV_SETUP}exec \"\${@}\""
fi
_BUILD_WRAPPER="$_ENV_SETUP"

if $_NEEDS_SANDBOX; then
    _prepare_cap_priv
    _prepare_seccomp
    _run_sandboxed "$TARGET_USER"
    exit $?
else
    exec sudo -u "$TARGET_USER" -H -- bash -c "$_INNER_CMD" -- "${CMD_ARGS[@]}"
fi

else
${_ENV_SETUP}
if [[ -n "$WORK_DIR" ]] && [[ -d "$WORK_DIR" ]]; then cd "$WORK_DIR" 2>/dev/null || true; fi
_log_dsr "EXEC: ${CMD_ARGS[*]}"
_BUILD_WRAPPER="$_ENV_SETUP"

if $_NEEDS_SANDBOX; then
    _prepare_cap_priv
    _prepare_seccomp
    _run_sandboxed ""
    exit $?
else
    exec "${CMD_ARGS[@]}"
fi
fi
