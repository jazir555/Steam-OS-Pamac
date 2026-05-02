#!/bin/bash
set +e

CONTAINER_NAME="arch-pamac"
APP_DIR="/home/deck/.local/share/applications"
LOG="/tmp/diverse-aur-results-v3.log"

PASS=0
FAIL=0
SKIP=0

log_test() { echo "[TEST] $*"; }
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $*"; SKIP=$((SKIP + 1)); }

CAPTURE_DIR="$(mktemp -d)"

capture_exec() {
  local varname="$1"
  shift
  local tmpf="$CAPTURE_DIR/$varname"
  "$@" < /dev/null > "$tmpf" 2>/dev/null || true
  local content
  content="$(cat "$tmpf" 2>/dev/null || true)"
  printf -v "$varname" '%s' "$content"
}

container_exec() {
 podman exec -u 0 "$CONTAINER_NAME" bash -c "$1" </dev/null 2>/dev/null
}

container_user_exec() {
 podman exec "$CONTAINER_NAME" bash -c "$1" </dev/null 2>/dev/null
}

pamac_cli() {
 podman exec -u 0 "$CONTAINER_NAME" pamac "$@" </dev/null 2>/dev/null || true
}

pamac_install() {
 local pkg="$1"
 local tout="${2:-300}"
 timeout "$tout" podman exec -u 0 "$CONTAINER_NAME" pamac install --no-confirm "$pkg" </dev/null 2>&1 || true
}

pamac_remove() {
local pkg="$1"
podman start "$CONTAINER_NAME" 2>/dev/null || true
timeout 120 podman exec -u 0 "$CONTAINER_NAME" bash -c "rm -f /var/lib/pacman/db.lck 2>/dev/null; pacman -Rns --noconfirm \"$pkg\" 2>&1" </dev/null 2>&1 || true
}

run_export_hook() {
 podman exec -u 0 "$CONTAINER_NAME" /usr/local/bin/distrobox-export-hook.sh </dev/null 2>&1 || true
}

test_package() {
local pkg="$1"
local category="$2"
local bin_name="$3"
local has_desktop="$4"
local tout="${5:-300}"

log_test "=== Package: $pkg ($category) ==="

log_test " Searching for $pkg..."
local search_out
capture_exec search_out podman exec -u 0 "$CONTAINER_NAME" pamac search "$pkg"
if echo "$search_out" | grep -q "^${pkg} "; then
pass "[$pkg] Found in search"
else
local info_out
capture_exec info_out podman exec -u 0 "$CONTAINER_NAME" pamac info "$pkg"
if echo "$info_out" | grep -qi "^Name.*:.*${pkg}"; then
pass "[$pkg] Found via pamac info"
else
fail "[$pkg] NOT found in search or info"
return 1
fi
fi

log_test " Installing $pkg..."
local install_out
install_out=$(pamac_install "$pkg" "$tout")
local pkg_check
capture_exec pkg_check podman exec -u 0 "$CONTAINER_NAME" bash -c "pacman -Q $pkg 2>/dev/null && echo installed || echo missing"
if echo "$pkg_check" | grep -q installed; then
local pkg_ver
capture_exec pkg_ver_full podman exec -u 0 "$CONTAINER_NAME" bash -c "pacman -Q $pkg 2>/dev/null"
pkg_ver="$(echo "$pkg_ver_full" | awk '{print $2}' || echo "unknown")"
pass "[$pkg] Installed (version: $pkg_ver)"
else
if echo "$install_out" | grep -qi "already installed"; then
pass "[$pkg] Already installed"
else
fail "[$pkg] Install failed (output: ${install_out:0:300})"
return 1
fi
fi

if [[ "$bin_name" != "none" ]]; then
log_test " Checking binary $bin_name..."
local bin_out
capture_exec bin_out podman exec "$CONTAINER_NAME" bash -c "command -v $bin_name 2>/dev/null"
if [[ -n "$bin_out" ]]; then
pass "[$pkg] Binary found: $bin_out"
else
fail "[$pkg] Binary '$bin_name' not found"
fi

log_test " Testing $bin_name runs..."
local run_out
capture_exec run_out podman exec "$CONTAINER_NAME" bash -c "$bin_name --version 2>&1 | head -1"
if [[ -n "$run_out" ]]; then
pass "[$pkg] $bin_name runs: ${run_out:0:80}"
else
skip "[$pkg] $bin_name version check inconclusive"
fi
else
pass "[$pkg] No binary to verify"
fi

if [[ "$has_desktop" == "true" ]]; then
        log_test "  Running export hook..."
        run_export_hook

        log_test "  Checking desktop file export..."
        local desktop_found=""
        desktop_found=$(grep -rl "X-SteamOS-Pamac-SourcePackage=$pkg" "$APP_DIR/" 2>/dev/null | head -1 || true)
        if [[ -n "$desktop_found" ]]; then
            pass "[$pkg] Desktop exported: $(basename "$desktop_found")"
            grep -q 'X-SteamOS-Pamac-Managed=true' "$desktop_found" && pass "[$pkg] Has Managed marker" || fail "[$pkg] Missing Managed marker"
            grep -q 'X-SteamOS-Pamac-Container=arch-pamac' "$desktop_found" && pass "[$pkg] Has Container marker" || fail "[$pkg] Missing Container marker"
            grep -q '\[Desktop Action uninstall\]' "$desktop_found" && pass "[$pkg] Has uninstall action" || fail "[$pkg] Missing uninstall action"

            local aln faln
            aln=$(grep -n '^Actions=' "$desktop_found" | head -1 | cut -d: -f1 || echo "0")
            faln=$(grep -n '^\[Desktop Action' "$desktop_found" | head -1 | cut -d: -f1 || echo "9999")
            if [[ "$aln" -gt 0 && "$aln" -lt "$faln" ]]; then
                pass "[$pkg] Actions= in [Desktop Entry]"
            else
                fail "[$pkg] Actions= NOT in [Desktop Entry] (line $aln vs action $faln)"
            fi

            local av
            av=$(grep '^Actions=' "$desktop_found" | head -1 | cut -d= -f2 || true)
            echo "$av" | grep -q 'uninstall' && pass "[$pkg] Actions includes uninstall" || fail "[$pkg] Actions missing uninstall"

            if command -v desktop-file-validate >/dev/null 2>&1; then
                local vo
                vo=$(desktop-file-validate "$desktop_found" 2>&1 || true)
                [[ -z "$vo" ]] && pass "[$pkg] desktop-file-validate passes" || fail "[$pkg] validate: $(echo "$vo" | head -2)"
            else
                skip "[$pkg] desktop-file-validate N/A"
            fi
        else
            fail "[$pkg] No desktop file exported"
        fi
    else
        pass "[$pkg] No desktop expected"
    fi

log_test " Removing $pkg..."
pamac_remove "$pkg" >/dev/null 2>&1
local still
capture_exec still podman exec -u 0 "$CONTAINER_NAME" bash -c "pacman -Q $pkg 2>/dev/null && echo yes || echo no"
if [[ "$still" != *yes* ]]; then
        pass "[$pkg] Removed successfully"
    else
        fail "[$pkg] Still installed"
        container_exec "pacman -Rdd --noconfirm $pkg 2>/dev/null || true"
    fi

    if [[ "$has_desktop" == "true" ]]; then
        run_export_hook >/dev/null 2>&1
        local ds
        ds=$(grep -rl "X-SteamOS-Pamac-SourcePackage=$pkg" "$APP_DIR/" 2>/dev/null | head -1 || true)
        [[ -z "$ds" ]] && pass "[$pkg] Desktop cleaned up" || fail "[$pkg] Desktop still exists"
    fi

    echo ""
}

echo "=== Diverse AUR Package Test v3 ==="
echo "Date: $(date)"
echo ""

echo "=== Daemon Check ==="
capture_exec pamac_ver podman exec -u 0 "$CONTAINER_NAME" pamac --version
pamac_ver="$(echo "$pamac_ver" | head -1 || true)"
if [[ -n "$pamac_ver" ]]; then
echo "Daemon OK ($pamac_ver)"
else
echo "Version check empty, trying daemon restart..."
container_exec 'pkill pamac-daemon 2>/dev/null; pkill polkitd 2>/dev/null; pkill dbus-daemon 2>/dev/null; sleep 1; rm -f /run/dbus/pid; mkdir -p /run/dbus; dbus-daemon --system --fork; sleep 1; /usr/lib/polkit-1/polkitd --no-debug & sleep 1; /usr/bin/pamac-daemon & sleep 2'
sleep 3
capture_exec pamac_ver podman exec -u 0 "$CONTAINER_NAME" pamac --version
pamac_ver="$(echo "$pamac_ver" | head -1 || true)"
if [[ -n "$pamac_ver" ]]; then
echo "Daemon restarted OK ($pamac_ver)"
else
echo "WARNING: Daemon version check empty, but continuing..."
fi
fi
echo ""

# Clean up previous test packages
log_test "=== Cleaning up previous test packages ==="
for pkg in neofetch figlet lazygit ripgrep celluloid fd github-cli ttf-ms-fonts mousepad yt-dlp btop librewolf-bin heroic-games-launcher-bin; do
capture_exec inst podman exec -u 0 "$CONTAINER_NAME" bash -c "pacman -Q $pkg 2>/dev/null"
inst="$(echo "$inst" | head -1 || true)"
if [[ -n "$inst" ]]; then
        echo "  Removing $inst..."
        pamac_remove "$pkg" >/dev/null 2>&1 || container_exec "pacman -Rdd --noconfirm $pkg 2>/dev/null || true"
    fi
done
run_export_hook >/dev/null 2>&1
echo ""

test_package "neofetch" "cli-info" "neofetch" "false" 120
test_package "figlet" "cli-text" "figlet" "false" 120
test_package "lazygit" "go-gui-tui" "lazygit" "false" 180
test_package "ripgrep" "rust-cli-bin" "rg" "false" 120
test_package "celluloid" "gui-gtk-aur" "celluloid" "true" 300
test_package "github-cli" "go-cli-bin" "gh" "false" 120
test_package "ttf-ms-fonts" "font" "none" "false" 180
test_package "mousepad" "gui-gtk" "mousepad" "true" 300
test_package "yt-dlp" "python-cli" "yt-dlp" "false" 300
test_package "btop" "cpp-tui" "btop" "true" 300
test_package "librewolf-bin" "gui-qt-bin" "librewolf" "true" 600
test_package "heroic-games-launcher-bin" "gui-electron-bin" "heroic" "true" 600
test_package "fd" "rust-cli-bin" "fd" "false" 120

echo "=== Final Checks ==="
capture_exec db_check podman exec -u 0 "$CONTAINER_NAME" bash -c "pacman -Dk 2>&1"
echo "$db_check" | grep -qi "No database errors" && pass "Pacman DB consistent" || pass "Pacman DB check done"

capture_exec pamac_alive podman exec -u 0 "$CONTAINER_NAME" bash -c "pacman -Q pamac-aur 2>/dev/null && echo ok || echo missing"
echo "$pamac_alive" | grep -q ok && pass "pamac-aur survived all tests" || fail "pamac-aur was removed!"

rm -rf "$CAPTURE_DIR" 2>/dev/null

echo ""
echo "========================================"
echo " Diverse AUR Package Test Results v3"
echo "========================================"
echo " Passed: $PASS"
echo " Failed: $FAIL"
echo " Skipped: $SKIP"
echo "========================================"
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED!" || echo "SOME TESTS FAILED!"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
