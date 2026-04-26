#!/bin/bash
# Fake systemd-run wrapper for non-systemd containers
# Pamac's daemon runs as root and uses "systemd-run --property=DynamicUser=yes
# --property=CacheDirectory=pamac --property=WorkingDirectory=... git clone/makepkg ..."
# In non-systemd environments, we simulate DynamicUser by running the command
# as a regular user (deck) instead.

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
        --service-type=*)
            continue
            ;;
        --service-type)
            SKIP_NEXT=true
            continue
            ;;
        --pipe|--wait|--pty)
            continue
            ;;
        --property=DynamicUser=yes)
            DYNAMIC_USER=true
            continue
            ;;
        --property=CacheDirectory=*)
            CACHE_DIR="${arg#--property=CacheDirectory=}"
            continue
            ;;
        --property=WorkingDirectory=*)
            WORK_DIR="${arg#--property=WorkingDirectory=}"
            continue
            ;;
        --property=*)
            continue
            ;;
        --property)
            SKIP_NEXT=true
            continue
            ;;
        --user|--uid=*|--gid=*|--setenv=*)
            continue
            ;;
        --user|--setenv)
            SKIP_NEXT=true
            continue
            ;;
        -q|--quiet|--no-block)
            continue
            ;;
        *)
            CMD_ARGS+=("$arg")
            ;;
    esac
done

if [[ ${#CMD_ARGS[@]} -eq 0 ]]; then
    echo "systemd-run (fake): no command to execute" >&2
    exit 1
fi

if [[ -n "$WORK_DIR" ]]; then
    mkdir -p "$WORK_DIR" 2>/dev/null || true
    if $DYNAMIC_USER; then
        chown deck:deck "$WORK_DIR" 2>/dev/null || true
    fi
fi

if [[ -n "$CACHE_DIR" ]]; then
    CACHE_FULL="/var/cache/$CACHE_DIR"
    mkdir -p "$CACHE_FULL" 2>/dev/null || true
    if $DYNAMIC_USER; then
        chown -R deck:deck "$CACHE_FULL" 2>/dev/null || true
    fi
fi

if $DYNAMIC_USER && [[ "$(id -u)" -eq 0 ]]; then
    BUILD_USER="deck"
    if ! id "$BUILD_USER" >/dev/null 2>&1; then
        BUILD_USER="nobody"
    fi

    if [[ -n "$WORK_DIR" ]]; then
        exec sudo -u "$BUILD_USER" -H -- bash -c "cd '$WORK_DIR' 2>/dev/null; exec ${CMD_ARGS[*]}"
    else
        exec sudo -u "$BUILD_USER" -H -- "${CMD_ARGS[@]}"
    fi
else
    if [[ -n "$WORK_DIR" ]] && [[ -d "$WORK_DIR" ]]; then
        cd "$WORK_DIR" 2>/dev/null || true
    fi
    exec "${CMD_ARGS[@]}"
fi
