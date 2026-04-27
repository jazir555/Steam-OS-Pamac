#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

CONTAINER_NAME="arch-pamac"

container_exec() {
    podman exec -u 0 "$CONTAINER_NAME" bash -c "$1" </dev/null 2>/dev/null
}

pamac_cli() {
    podman exec -u 0 "$CONTAINER_NAME" pamac "$@" </dev/null 2>/dev/null || true
}

echo "Test 1: pamac search neofetch directly..."
timeout 15 podman exec -u 0 arch-pamac pamac search neofetch 2>/dev/null | head -2
echo "Direct search exit: $?"

echo ""
echo "Test 2: pamac search via function..."
search_out=$(pamac_cli search neofetch)
echo "Function search exit: $?"
echo "Got ${#search_out} chars"
echo "First line: $(echo "$search_out" | head -1)"

echo ""
echo "Test 3: pamac install neofetch..."
install_out=$(timeout 120 podman exec -u 0 arch-pamac pamac install --no-confirm neofetch </dev/null 2>&1 || true)
echo "Install exit: $?"
echo "Output: ${install_out:0:300}"

echo ""
echo "Test 4: check if neofetch installed..."
pkg_check=$(container_exec "pacman -Q neofetch 2>/dev/null && echo installed || echo missing" || echo "missing")
echo "Package check: $pkg_check"

echo ""
echo "ALL QUICK TESTS DONE"
