#!/bin/bash
# Apply all fixes to the running arch-pamac container
set -e

echo "=== Re-enabling D-Bus service files ==="
for svc_file in /usr/share/dbus-1/system-services/org.manjaro.pamac.daemon.service \
/usr/share/dbus-1/system-services/org.freedesktop.PolicyKit1.service; do
if [[ -f "${svc_file}.disabled-by-steamos-pamac" ]] && [[ ! -f "$svc_file" ]]; then
cp "${svc_file}.disabled-by-steamos-pamac" "$svc_file"
echo "Re-enabled: $svc_file"
elif [[ -f "$svc_file" ]]; then
echo "Already enabled: $svc_file"
fi
done

echo "=== Installing fake systemd-run ==="
if [[ -f /usr/local/sbin/systemd-run ]] && grep -q "DYNAMIC_USER" /usr/local/sbin/systemd-run 2>/dev/null; then
echo "Fake systemd-run already installed"
else
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
if $DYNAMIC_USER; then chown deck:deck "$WORK_DIR" 2>/dev/null || true; fi
fi
if [[ -n "$CACHE_DIR" ]]; then
CACHE_FULL="/var/cache/$CACHE_DIR"
mkdir -p "$CACHE_FULL" 2>/dev/null || true
if $DYNAMIC_USER; then chown -R deck:deck "$CACHE_FULL" 2>/dev/null || true; fi
fi
if $DYNAMIC_USER && [[ "$(id -u)" -eq 0 ]]; then
BUILD_USER="deck"
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
echo "Fake systemd-run installed"
fi

echo "=== Patching polkit policy ==="
pamac_policy="/usr/share/polkit-1/actions/org.manjaro.pamac.policy"
if [[ -f "$pamac_policy" ]]; then
sed -i 's|<allow_any>auth_admin_keep</allow_any>|<allow_any>yes</allow_any>|' "$pamac_policy"
sed -i 's|<allow_inactive>auth_admin_keep</allow_inactive>|<allow_inactive>yes</allow_inactive>|' "$pamac_policy"
sed -i 's|<allow_active>auth_admin_keep</allow_active>|<allow_active>yes</allow_active>|' "$pamac_policy"
echo "Polkit policy patched"
fi

echo "=== Changing build directory ==="
if grep -q '^BuildDirectory = /var/tmp' /etc/pamac.conf 2>/dev/null; then
sed -i 's|^BuildDirectory = /var/tmp|BuildDirectory = /home/deck/.pamac-build|' /etc/pamac.conf
mkdir -p /home/deck/.pamac-build
chown deck:deck /home/deck/.pamac-build
echo "Build directory changed to /home/deck/.pamac-build"
else
echo "Build directory already configured"
fi

echo "=== All fixes applied ==="
