#!/bin/bash
set +e

CONTAINER_NAME="arch-pamac"
APP_DIR="/home/deck/.local/share/applications"
LOG="/tmp/diverse-aur-results-v3.log"
PASS=0
FAIL=0
SKIP=0

log_test() { echo "[TEST] $*"; }
pass() { echo " PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo " FAIL: $*"; FAIL=$((FAIL + 1)); }
skip() { echo " SKIP: $*"; SKIP=$((SKIP + 1)); }

CAPTURE_DIR="$(mktemp -d)"

capture_exec() {
  local varname="$1"
  shift
  local tmpf="$CAPTURE_DIR/$varname"
  echo "DEBUG: running: $* > $tmpf" >&2
  "$@" < /dev/null > "$tmpf" 2>&1
  local rc=$?
  echo "DEBUG: rc=$rc size=$(wc -c < "$tmpf" 2>/dev/null || echo 0)" >&2
  local content
  content="$(cat "$tmpf" 2>/dev/null || true)"
  printf -v "$varname" '%s' "$content"
}

container_exec() {
  podman exec -u 0 "$CONTAINER_NAME" bash -c "$1" </dev/null 2>/dev/null
}

echo "=== Daemon Check ==="
echo "DEBUG: About to capture pamac_ver..."
capture_exec pamac_ver podman exec -u 0 "$CONTAINER_NAME" pamac --version
echo "DEBUG: pamac_ver='$pamac_ver'"
pamac_ver="$(echo "$pamac_ver" | head -1 || true)"
if [[ -n "$pamac_ver" ]]; then
  echo "Daemon OK ($pamac_ver)"
else
  echo "Version check empty"
fi

echo "=== Test capture_exec with search ==="
capture_exec search_out podman exec -u 0 "$CONTAINER_NAME" pamac search neofetch
echo "DEBUG: search_out first 80: '${search_out:0:80}'"

echo "=== All done ==="
rm -rf "$CAPTURE_DIR" 2>/dev/null
