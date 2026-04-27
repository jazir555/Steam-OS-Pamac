#!/bin/bash
set +e

CONTAINER_NAME="arch-pamac"
CAPTURE_DIR="$(mktemp -d)"

capture_exec() {
  local varname="$1"
  shift
  local tmpf="$CAPTURE_DIR/$varname"
  "$@" > "$tmpf" 2>/dev/null || true
  local content
  content="$(cat "$tmpf" 2>/dev/null || true)"
  printf -v "$varname" '%s' "$content"
}

echo "=== capture_exec background test ==="

capture_exec ver_out podman exec -u 0 "$CONTAINER_NAME" pamac --version </dev/null
echo "pamac version: '$ver_out'"

capture_exec pac_out podman exec -u 0 "$CONTAINER_NAME" bash -c "pacman -Q pamac-aur 2>/dev/null && echo installed || echo missing" </dev/null
echo "pamac-aur status: '$pac_out'"

capture_exec search_out podman exec -u 0 "$CONTAINER_NAME" pamac search neofetch </dev/null
echo "search neofetch (first 80): '${search_out:0:80}'"

rm -rf "$CAPTURE_DIR" 2>/dev/null

if [[ -n "$ver_out" && -n "$pac_out" ]]; then
  echo "PASS: capture_exec works in background mode"
  exit 0
else
  echo "FAIL: capture_exec returned empty values"
  exit 1
fi
