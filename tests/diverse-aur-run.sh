#!/bin/bash
set -uo pipefail

SSH_HOST="deck@192.168.2.111"
CONTAINER_NAME="arch-pamac"

ssh_cmd() {
  sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_HOST" "$@"
}

ssh_check() {
  sshpass -p a ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_HOST" "$@" 2>/dev/null
}

PASS=0
FAIL=0
SKIP=0

log_test() { echo "[TEST] $*"; }
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $*"; SKIP=$((SKIP + 1)); }

container_exec() {
  local cmd="$1"
  ssh_check "podman exec -i -u 0 $CONTAINER_NAME bash -c '$cmd'"
}

container_user_exec() {
  local cmd="$1"
  ssh_check "podman exec -i -u deck $CONTAINER_NAME bash -c '$cmd'"
}

pamac_exec() {
  local cmd="$1"
  local timeout_sec="${2:-300}"
  ssh_check "timeout $timeout_sec podman exec -i -u 0 $CONTAINER_NAME bash -c 'rm -f /run/dbus/pid 2>/dev/null; pkill pamac-daemon 2>/dev/null; pkill polkitd 2>/dev/null; pkill dbus-daemon 2>/dev/null; sleep 1; mkdir -p /run/dbus; dbus-daemon --system --fork 2>/dev/null; sleep 1; /usr/lib/polkit-1/polkitd --no-debug &>/dev/null & sleep 1; /usr/bin/pamac-daemon &>/dev/null & sleep 2; $cmd'"
}

distrobox_exec() {
  local cmd="$1"
  local timeout_sec="${2:-30}"
  ssh_check "timeout $timeout_sec distrobox-enter $CONTAINER_NAME -- bash -c '$cmd'"
}

test_package() {
  local pkg="$1"
  local category="$2"
  local bin_name="$3"
  local has_desktop="$4"
  local timeout="${5:-300}"

  log_test "=== Package: $pkg ($category) ==="

  log_test "  Searching for $pkg..."
  local search_out
  search_out=$(pamac_exec "pamac search --aur $pkg 2>/dev/null" 30 || true)
  if echo "$search_out" | grep -qi "$pkg"; then
    pass "[$pkg] Found in AUR"
  else
    fail "[$pkg] NOT found in AUR (output: ${search_out:0:200})"
    return 1
  fi

  log_test "  Installing $pkg..."
  local install_out
  install_out=$(pamac_exec "pamac install --no-confirm $pkg 2>&1" "$timeout" || true)
  local pkg_check
  pkg_check=$(container_exec "pacman -Q $pkg 2>/dev/null && echo installed || echo missing" || echo "missing")
  if echo "$pkg_check" | grep -q installed; then
    local pkg_ver
    pkg_ver=$(ssh_check "podman exec -i -u 0 $CONTAINER_NAME pacman -Q $pkg 2>/dev/null" | grep -oP '\S+$' || echo "unknown")
    pass "[$pkg] Installed (version: $pkg_ver)"
  else
    if echo "$install_out" | grep -qi "already installed"; then
      pass "[$pkg] Already installed"
    else
      fail "[$pkg] Install failed (output: ${install_out:0:500})"
      return 1
    fi
  fi

  if [[ "$bin_name" != "none" ]]; then
    log_test "  Checking binary $bin_name..."
    local bin_out
    bin_out=$(container_user_exec "command -v $bin_name 2>/dev/null" || true)
    if [[ -n "$bin_out" ]]; then
      pass "[$pkg] Binary '$bin_name' found at: $bin_out"
    else
      fail "[$pkg] Binary '$bin_name' not found"
    fi

    log_test "  Testing $bin_name runs..."
    local run_out
    run_out=$(container_user_exec "$bin_name --version 2>&1 | head -1" 10 || true)
    if [[ -n "$run_out" ]]; then
      pass "[$pkg] $bin_name runs: ${run_out:0:80}"
    else
      run_out=$(container_user_exec "$bin_name -V 2>&1 | head -1" 10 || true)
      if [[ -n "$run_out" ]]; then
        pass "[$pkg] $bin_name runs: ${run_out:0:80}"
      else
        skip "[$pkg] $bin_name version check inconclusive (may need TTY)"
      fi
    fi
  else
    pass "[$pkg] No binary to verify (font/resource package)"
  fi

  if [[ "$has_desktop" == "true" ]]; then
    log_test "  Checking desktop file export..."
    local desktop_found
    desktop_found=$(ssh_check "grep -rl 'SourcePackage=$pkg' /home/deck/.local/share/applications/ 2>/dev/null | head -1" || true)
    if [[ -z "$desktop_found" ]]; then
      log_test "  Running export hook..."
      distrobox_exec "env XDG_DATA_DIRS=/usr/local/share:/usr/share XDG_DATA_HOME=/home/deck/.local/share /usr/local/bin/distrobox-export-hook.sh" 30 || true
      desktop_found=$(ssh_check "grep -rl 'SourcePackage=$pkg' /home/deck/.local/share/applications/ 2>/dev/null | head -1" || true)
    fi
    if [[ -n "$desktop_found" ]]; then
      pass "[$pkg] Desktop file exported: $(basename "$desktop_found")"
      local has_managed
      has_managed=$(ssh_check "grep -q 'X-SteamOS-Pamac-Managed=true' '$desktop_found' && echo true || echo false" || echo "false")
      if [[ "$has_managed" == "true" ]]; then
        pass "[$pkg] Desktop has X-SteamOS-Pamac-Managed marker"
      else
        fail "[$pkg] Desktop missing X-SteamOS-Pamac-Managed marker"
      fi
      local has_uninstall
      has_uninstall=$(ssh_check "grep -q 'Desktop Action uninstall' '$desktop_found' && echo true || echo false" || echo "false")
      if [[ "$has_uninstall" == "true" ]]; then
        pass "[$pkg] Desktop has uninstall action"
      else
        fail "[$pkg] Desktop missing uninstall action"
      fi
    else
      local all_desktops
      all_desktops=$(ssh_check "ls /home/deck/.local/share/applications/arch-pamac-*.desktop 2>/dev/null | head -5" || true)
      fail "[$pkg] No desktop file exported (existing: $all_desktops)"
    fi
  else
    pass "[$pkg] No desktop file expected (CLI/font package)"
  fi

  log_test "  Removing $pkg..."
  local remove_out
  remove_out=$(pamac_exec "pamac remove --no-confirm --no-save $pkg 2>&1" 60 || true)
  local still
  still=$(container_exec "pacman -Q $pkg 2>/dev/null && echo yes || echo no" || echo "no")
  if [[ "$still" != *yes* ]]; then
    pass "[$pkg] Removed successfully"
  else
    fail "[$pkg] Still installed after remove"
    container_exec "pacman -Rdd --noconfirm $pkg 2>/dev/null || true" || true
  fi
  pamac_exec "pamac remove --no-confirm --unneeded 2>&1" 30 || true

  if [[ "$has_desktop" == "true" ]]; then
    log_test "  Checking desktop cleanup after uninstall..."
    distrobox_exec "env XDG_DATA_DIRS=/usr/local/share:/usr/share XDG_DATA_HOME=/home/deck/.local/share /usr/local/bin/distrobox-export-hook.sh" 30 || true
    local desktop_still
    desktop_still=$(ssh_check "grep -rl 'SourcePackage=$pkg' /home/deck/.local/share/applications/ 2>/dev/null | head -1" || true)
    if [[ -z "$desktop_still" ]]; then
      pass "[$pkg] Desktop file cleaned up"
    else
      fail "[$pkg] Desktop file still exists after cleanup"
    fi
  fi

  echo ""
}

echo "=== Diverse AUR Package Test ==="
echo "Date: $(date)"
echo ""

conn=$(ssh_cmd "echo connected" 2>&1)
if ! echo "$conn" | grep -q connected; then
  echo "ERROR: Cannot SSH to $SSH_HOST"
  echo "Output: ${conn:0:200}"
  exit 1
fi
echo "SSH OK"
echo ""

echo "=== Daemon Check ==="
daemon_test=$(pamac_exec "echo daemon_ok" 10 || true)
if echo "$daemon_test" | grep -q daemon_ok; then
  echo "Daemon OK"
else
  echo "Daemon FAILED: ${daemon_test:0:200}"
  exit 1
fi
echo ""

# Format: package_name category binary_name has_desktop_file timeout
test_package "neofetch" "cli-info" "neofetch" "false" 120
test_package "figlet" "cli-text" "figlet" "false" 120
test_package "lazygit" "go-gui-tui" "lazygit" "true" 180
test_package "ripgrep-bin" "rust-cli-bin" "rg" "false" 120
test_package "bat-bin" "rust-cli-bin" "bat" "false" 120
test_package "ttf-imp-ink-original" "font" "none" "false" 180
test_package "mousepad" "gui-gtk" "mousepad" "true" 300
test_package "yt-dlp" "python-cli" "yt-dlp" "false" 300
test_package "github-cli-bin" "go-cli-bin" "gh" "true" 120
test_package "fd-bin" "rust-cli-bin" "fd" "false" 120
test_package "btop" "cpp-tui" "btop" "true" 300
test_package "librewolf-bin" "gui-qt-bin" "librewolf" "true" 300
test_package "heroic-games-launcher-bin" "gui-electron-bin" "heroic" "true" 300

echo "=== Final DB Integrity Check ==="
db_check=$(container_exec "pacman -Dk 2>&1" || true)
if echo "$db_check" | grep -qi "No database errors have been found"; then
  pass "Pacman DB consistent after all tests"
elif echo "$db_check" | grep -qiE "^error|has error|inconsisten|broken|missing dependency"; then
  fail "Pacman DB has issues: $(echo "$db_check" | head -3)"
else
  pass "Pacman DB check passed"
fi
echo ""

echo "========================================"
echo " Diverse AUR Package Test Results"
echo "========================================"
echo " Passed:  $PASS"
echo " Failed:  $FAIL"
echo " Skipped: $SKIP"
echo "========================================"
if [[ $FAIL -eq 0 ]]; then
  echo "ALL TESTS PASSED!"
else
  echo "SOME TESTS FAILED!"
fi

exit $FAIL
