#!/bin/bash
set +e

CONTAINER_NAME="arch-pamac"
CAPTURE_DIR="$(mktemp -d)"

capture_exec() {
  local varname="$1"
  shift
  local tmpf="$CAPTURE_DIR/$varname"
  echo "DEBUG: capture_exec varname=$varname cmd=$* tmpf=$tmpf" >&2
  "$@" < /dev/null > "$tmpf" 2>&1
  local rc=$?
  echo "DEBUG: capture_exec rc=$rc tmpf_size=$(wc -c < "$tmpf" 2>/dev/null || echo missing)" >&2
  local content
  content="$(cat "$tmpf" 2>/dev/null || true)"
  printf -v "$varname" '%s' "$content"
  echo "DEBUG: captured value first 80: '${!varname:0:80}'" >&2
}

echo "=== Debug capture_exec ==="

capture_exec pamac_ver podman exec -u 0 "$CONTAINER_NAME" pamac --version

echo ""
echo "pamac_ver='$pamac_ver'"

rm -rf "$CAPTURE_DIR" 2>/dev/null
echo "done"
