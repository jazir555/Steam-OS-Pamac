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
