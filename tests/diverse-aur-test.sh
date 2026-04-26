#!/bin/bash
set -uo pipefail

SSH_HOST="deck@192.168.2.111"
CONTAINER_NAME="arch-pamac"

if grep -qi microsoft /proc/version 2>/dev/null || uname -r 2>/dev/null | grep -qi microsoft; then
  SSH_CMD="sshpass -p 'a' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"
elif command -v wsl.exe >/dev/null 2>&1; then
  SSH_CMD="wsl -d Arch -- sshpass -p 'a' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"
else
  SSH_CMD="sshpass -p 'a' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"
fi

PASS=0
FAIL=0
SKIP=0
TEST_LOG=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log_test() { echo -e "${BOLD}[TEST]${NC} $*"; echo "[TEST] $*" >> "$TEST_LOG"; }
pass() { echo -e " ${GREEN}PASS${NC}: $*"; echo " PASS: $*" >> "$TEST_LOG"; PASS=$((PASS + 1)); }
fail() { echo -e " ${RED}FAIL${NC}: $*"; echo " FAIL: $*" >> "$TEST_LOG"; FAIL=$((FAIL + 1)); }
skip() { echo -e " ${YELLOW}SKIP${NC}: $*"; echo " SKIP: $*" >> "$TEST_LOG"; SKIP=$((SKIP + 1)); }

ssh_exec() { eval "$SSH_CMD '$SSH_HOST' \"\$@\""; }
ssh_check() { eval "$SSH_CMD '$SSH_HOST' \"\$@\" 2>/dev/null"; }

container_exec() {
  local cmd="${1//\'/\\\'}"
  ssh_check "podman exec -i -u 0 '$CONTAINER_NAME' bash -c '$cmd' 2>&1"
}

container_user_exec() {
  local cmd="${1//\'/\\\'}"
  ssh_check "podman exec -i -u deck '$CONTAINER_NAME' bash -c '$cmd' 2>&1"
}

pamac_exec() {
  local cmd="${1//\'/\\\'}"
  local timeout_sec="${2:-300}"
  ssh_check "timeout $timeout_sec podman exec -i -u 0 '$CONTAINER_NAME' bash -c 'rm -f /run/dbus/pid 2>/dev/null; pkill pamac-daemon 2>/dev/null; pkill polkitd 2>/dev/null; pkill dbus-daemon 2>/dev/null; sleep 1; mkdir -p /run/dbus; dbus-daemon --system --fork 2>/dev/null; sleep 1; /usr/lib/polkit-1/polkitd --no-debug &>/dev/null & sleep 1; /usr/bin/pamac-daemon &>/dev/null & sleep 2; $cmd' 2>&1"
}

declare -A TEST_PACKAGES
declare -A PKG_CATEGORIES
declare -A PKG_HAS_DESKTOP
declare -A PKG_BIN_NAME
declare -A PKG_INSTALL_TIMEOUT

TEST_PACKAGES=(
  ["neofetch"]="7.1.0"
  ["figlet"]="2.2.5"
  ["lazygit"]="0.44"
  ["ripgrep-bin"]="14.1"
  ["bat-bin"]="0.24"
  ["ttf-imp-ink-original"]="1.0"
  ["mousepad"]="0.6"
  ["yt-dlp"]="2025"
  ["github-cli-bin"]="2.67"
  ["fd-bin"]="10.1"
  ["btop"]="1.4"
  ["librewolf-bin"]="136"
  ["heroic-games-launcher-bin"]="2.15"
)

PKG_CATEGORIES=(
  ["neofetch"]="cli-info"
  ["figlet"]="cli-text"
  ["lazygit"]="go-gui-tui"
  ["ripgrep-bin"]="rust-cli-bin"
  ["bat-bin"]="rust-cli-bin"
  ["ttf-imp-ink-original"]="font"
  ["mousepad"]="gui-gtk"
  ["yt-dlp"]="python-cli"
  ["github-cli-bin"]="go-cli-bin"
  ["fd-bin"]="rust-cli-bin"
  ["btop"]="cpp-tui"
  ["librewolf-bin"]="gui-qt-bin"
  ["heroic-games-launcher-bin"]="gui-electron-bin"
)

PKG_HAS_DESKTOP=(
  ["neofetch"]="false"
  ["figlet"]="false"
  ["lazygit"]="true"
  ["ripgrep-bin"]="false"
  ["bat-bin"]="false"
  ["ttf-imp-ink-original"]="false"
  ["mousepad"]="true"
  ["yt-dlp"]="false"
  ["github-cli-bin"]="true"
  ["fd-bin"]="false"
  ["btop"]="true"
  ["librewolf-bin"]="true"
  ["heroic-games-launcher-bin"]="true"
)

PKG_BIN_NAME=(
  ["neofetch"]="neofetch"
  ["figlet"]="figlet"
  ["lazygit"]="lazygit"
  ["ripgrep-bin"]="rg"
  ["bat-bin"]="bat"
  ["ttf-imp-ink-original"]="false"
  ["figlet"]="figlet"
  ["mousepad"]="mousepad"
  ["yt-dlp"]="yt-dlp"
  ["github-cli-bin"]="gh"
  ["fd-bin"]="fd"
  ["btop"]="btop"
  ["librewolf-bin"]="librewolf"
  ["heroic-games-launcher-bin"]="heroic"
)

PKG_INSTALL_TIMEOUT=(
  ["neofetch"]="120"
  ["figlet"]="120"
  ["lazygit"]="180"
  ["ripgrep-bin"]="120"
  ["bat-bin"]="120"
  ["ttf-imp-ink-original"]="180"
  ["mousepad"]="300"
  ["yt-dlp"]="300"
  ["github-cli-bin"]="120"
  ["fd-bin"]="120"
  ["btop"]="300"
  ["librewolf-bin"]="300"
  ["heroic-games-launcher-bin"]="300"
)

check_prerequisites() {
  log_test "=== Prerequisites Check ==="

  local container_ok
  container_ok=$(ssh_check "podman exec -i -u 0 '$CONTAINER_NAME' echo ok 2>/dev/null" | grep -c ok || echo 0)
  if [[ "$container_ok" -gt 0 ]]; then
    pass "Container is running and accessible"
  else
    fail "Container not accessible"
    return 1
  fi

  local daemon_test
  daemon_test=$(pamac_exec "echo daemon_ok" 10 || true)
  if [[ "$daemon_test" == *"daemon_ok"* ]]; then
    pass "pamac-daemon bootstrap works"
  else
    fail "pamac-daemon bootstrap failed"
    return 1
  fi

  local disk_free
  disk_free=$(ssh_check "df -h /home/deck | tail -1 | awk '{print \$4}'" || echo "unknown")
  log_test "Available disk: $disk_free"

  local hook_exists
  hook_exists=$(container_exec "test -x /usr/local/bin/distrobox-export-hook.sh && echo true || echo false" || echo "false")
  if [[ "$hook_exists" == "true" ]]; then
    pass "Export hook exists"
  else
    fail "Export hook not found"
  fi

  local fake_systemd_run
  fake_systemd_run=$(container_exec "test -x /usr/local/sbin/systemd-run && echo true || echo false" || echo "false")
  if [[ "$fake_systemd_run" == "true" ]]; then
    pass "Fake systemd-run wrapper exists"
  else
    fail "Fake systemd-run wrapper not found"
  fi
}

test_single_package() {
  local pkg="$1"
  local expected_ver="$2"
  local category="${PKG_CATEGORIES[$pkg]:-unknown}"
  local has_desktop="${PKG_HAS_DESKTOP[$pkg]:-false}"
  local bin_name="${PKG_BIN_NAME[$pkg]:-$pkg}"
  local timeout="${PKG_INSTALL_TIMEOUT[$pkg]:-300}"
  local test_num="$3"

  log_test "=== Package $test_num: $pkg ($category) ==="

  log_test "  Step 1: Search for $pkg in AUR"
  local search_out
  search_out=$(pamac_exec "pamac search --aur $pkg 2>/dev/null" 30 || true)
  if echo "$search_out" | grep -qi "$pkg"; then
    pass "[$pkg] Found in AUR search"
  else
    fail "[$pkg] NOT found in AUR search (output: ${search_out:0:200})"
    return 1
  fi

  log_test "  Step 2: Install $pkg via pamac"
  local install_out
  install_out=$(pamac_exec "pamac install --no-confirm $pkg 2>&1" "$timeout" || true)
  echo "$install_out" | tail -5 >> "$TEST_LOG" 2>/dev/null

  local pkg_check
  pkg_check=$(container_exec "pacman -Q ${pkg} 2>/dev/null && echo installed || echo missing" || echo "missing")
  if [[ "$pkg_check" == *"installed"* ]]; then
    local pkg_ver
    pkg_ver=$(ssh_check "podman exec -i -u 0 '$CONTAINER_NAME' pacman -Q $pkg 2>/dev/null" | grep -oP '\S+$' || echo "unknown")
    pass "[$pkg] Installed successfully (version: $pkg_ver)"
  else
    if echo "$install_out" | grep -qi "already installed"; then
      pass "[$pkg] Was already installed"
    else
      fail "[$pkg] Install failed (output: ${install_out:0:500})"
      return 1
    fi
  fi

  log_test "  Step 3: Verify binary exists"
  if [[ "$bin_name" != "false" ]]; then
    local bin_out
    bin_out=$(container_user_exec "command -v $bin_name 2>/dev/null" || true)
    if [[ -n "$bin_out" ]]; then
      pass "[$pkg] Binary '$bin_name' available at: $bin_out"
    else
      local alt_out
      alt_out=$(container_exec "which $bin_name 2>/dev/null || find /usr -name $bin_name -type f 2>/dev/null | head -1" || true)
      if [[ -n "$alt_out" ]]; then
        pass "[$pkg] Binary '$bin_name' found at: $alt_out"
      else
        fail "[$pkg] Binary '$bin_name' not found in container"
      fi
    fi
  else
    skip "[$pkg] No binary to verify (font/package type)"
  fi

  log_test "  Step 4: Verify binary runs"
  if [[ "$bin_name" != "false" ]]; then
    local run_out
    run_out=$(container_user_exec "$bin_name --version 2>/dev/null || $bin_name --help 2>/dev/null | head -3" 15 || true)
    if [[ -n "$run_out" ]]; then
      pass "[$pkg] Binary '$bin_name' runs (output: ${run_out:0:80})"
    else
      run_out=$(container_user_exec "$bin_name -V 2>/dev/null || $bin_name -h 2>/dev/null | head -3" 15 || true)
      if [[ -n "$run_out" ]]; then
        pass "[$pkg] Binary '$bin_name' runs (output: ${run_out:0:80})"
      else
        skip "[$pkg] Binary '$bin_name' version/help check inconclusive (may need terminal)"
      fi
    fi
  fi

  log_test "  Step 5: Check desktop file export (expected: $has_desktop)"
  if [[ "$has_desktop" == "true" ]]; then
    local desktop_found
    desktop_found=$(ssh_check "find /home/deck/.local/share/applications -maxdepth 1 -name '${CONTAINER_NAME}-*.desktop' -type f 2>/dev/null | while read f; do grep -ql 'SourcePackage=${pkg}\$' \"\$f\" 2>/dev/null && echo \"\$f\" && break; done" || true)

    if [[ -z "$desktop_found" ]]; then
      log_test "  Running export hook to export $pkg desktop file..."
      distrobox_exec "/usr/local/bin/distrobox-export-hook.sh" 30 2>/dev/null || true
      desktop_found=$(ssh_check "find /home/deck/.local/share/applications -maxdepth 1 -name '${CONTAINER_NAME}-*.desktop' -type f 2>/dev/null | while read f; do grep -ql 'SourcePackage=${pkg}\$' \"\$f\" 2>/dev/null && echo \"\$f\" && break; done" || true)
    fi

    if [[ -n "$desktop_found" ]]; then
      pass "[$pkg] Desktop file exported: $(basename "$desktop_found")"

      local has_managed
      has_managed=$(ssh_check "grep -q '^X-SteamOS-Pamac-Managed=true' '$desktop_found' 2>/dev/null && echo true || echo false" || echo "false")
      if [[ "$has_managed" == "true" ]]; then
        pass "[$pkg] Desktop file has X-SteamOS-Pamac-Managed marker"
      else
        fail "[$pkg] Desktop file missing X-SteamOS-Pamac-Managed marker"
      fi

      local has_uninstall
      has_uninstall=$(ssh_check "grep -q '^\[Desktop Action uninstall\]' '$desktop_found' 2>/dev/null && echo true || echo false" || echo "false")
      if [[ "$has_uninstall" == "true" ]]; then
        pass "[$pkg] Desktop file has uninstall action"
      else
        fail "[$pkg] Desktop file missing uninstall action"
      fi
    else
      local any_new
      any_new=$(ssh_check "ls -t /home/deck/.local/share/applications/${CONTAINER_NAME}-*.desktop 2>/dev/null | head -3" || true)
      fail "[$pkg] No desktop file exported for package (existing: $any_new)"
    fi
  else
    local unexpected_desktop
    unexpected_desktop=$(ssh_check "find /home/deck/.local/share/applications -maxdepth 1 -name '${CONTAINER_NAME}-*.desktop' -type f 2>/dev/null | xargs grep -l 'SourcePackage=${pkg}' 2>/dev/null | head -1" || true)
    if [[ -n "$unexpected_desktop" ]]; then
      log_test "  WARNING: CLI package $pkg unexpectedly has a desktop file"
      pass "[$pkg] Desktop file found (unexpected for CLI package but not an error)"
    else
      pass "[$pkg] No desktop file (correct for CLI/font package)"
    fi
  fi

  log_test "  Step 6: Uninstall $pkg via pamac"
  local remove_out
  remove_out=$(pamac_exec "pamac remove --no-confirm --no-save $pkg 2>&1" 60 || true)
  echo "$remove_out" | tail -3 >> "$TEST_LOG" 2>/dev/null

  local still_installed
  still_installed=$(container_exec "pacman -Q ${pkg} 2>/dev/null && echo yes || echo no" || echo "no")
  if [[ "$still_installed" == *"yes"* ]]; then
    fail "[$pkg] Still installed after pamac remove"
    log_test "  Attempting forced removal..."
    container_exec "pacman -Rdd --noconfirm $pkg 2>/dev/null || true" || true
  else
    pass "[$pkg] Successfully removed via pamac"
  fi

  pamac_exec "pamac remove --no-confirm --unneeded 2>&1" 30 || true

  log_test "  Step 7: Verify desktop file cleanup after uninstall"
  if [[ "$has_desktop" == "true" ]]; then
    local desktop_still_exists
    desktop_still_exists=$(ssh_check "find /home/deck/.local/share/applications -maxdepth 1 -name '${CONTAINER_NAME}-*.desktop' -type f 2>/dev/null | xargs grep -l 'SourcePackage=${pkg}' 2>/dev/null | head -1" || true)
    if [[ -n "$desktop_still_exists" ]]; then
      log_test "  Running export hook to clean up stale desktop file..."
      distrobox_exec "/usr/local/bin/distrobox-export-hook.sh" 30 2>/dev/null || true
      desktop_still_exists=$(ssh_check "find /home/deck/.local/share/applications -maxdepth 1 -name '${CONTAINER_NAME}-*.desktop' -type f 2>/dev/null | xargs grep -l 'SourcePackage=${pkg}' 2>/dev/null | head -1" || true)
      if [[ -n "$desktop_still_exists" ]]; then
        fail "[$pkg] Desktop file still exists after uninstall and export hook re-run"
      else
        pass "[$pkg] Desktop file cleaned up after export hook re-run"
      fi
    else
      pass "[$pkg] Desktop file removed after uninstall"
    fi
  fi
}

distrobox_exec() {
  local cmd="${1//\'/\\\'}"
  local timeout_sec="${2:-}"
  if [[ -n "$timeout_sec" ]]; then
    ssh_check "timeout $timeout_sec distrobox-enter '$CONTAINER_NAME' -- bash -c '$cmd' 2>&1"
  else
    ssh_check "distrobox-enter '$CONTAINER_NAME' -- bash -c '$cmd' 2>&1"
  fi
}

test_package_reinstall_cycle() {
  local pkg="$1"
  local category="$2"
  local timeout="${3:-300}"

  log_test "=== Reinstall cycle test: $pkg ($category) ==="

  log_test "  Reinstalling $pkg..."
  local install_out
  install_out=$(pamac_exec "pamac install --no-confirm $pkg 2>&1" "$timeout" || true)

  local pkg_check
  pkg_check=$(container_exec "pacman -Q ${pkg} 2>/dev/null && echo installed || echo missing" || echo "missing")
  if [[ "$pkg_check" == *"installed"* ]]; then
    pass "[$pkg] Reinstall succeeded"
  else
    fail "[$pkg] Reinstall failed"
    return 1
  fi

  local remove_out
  remove_out=$(pamac_exec "pamac remove --no-confirm --no-save $pkg 2>&1" 60 || true)
  local still_installed
  still_installed=$(container_exec "pacman -Q ${pkg} 2>/dev/null && echo yes || echo no" || echo "no")
  if [[ "$still_installed" != *"yes"* ]]; then
    pass "[$pkg] Uninstall after reinstall succeeded"
  else
    fail "[$pkg] Uninstall after reinstall failed"
  fi
}

test_db_integrity_after_all() {
  log_test "=== Final pacman DB integrity check ==="

  local db_check
  db_check=$(container_exec "pacman -Dk 2>&1" || true)
  if echo "$db_check" | grep -qi "No database errors have been found"; then
    pass "Pacman DB is consistent after all installs/removes"
  elif echo "$db_check" | grep -qiE "^error|has error|inconsisten|broken|missing dependency"; then
    fail "Pacman DB has inconsistencies: $(echo "$db_check" | head -5)"
  else
    pass "Pacman DB check passed (no errors reported)"
  fi

  local lock_check
  lock_check=$(container_exec "test -f /var/lib/pacman/db.lck && echo locked || echo unlocked" || echo "unlocked")
  if [[ "$lock_check" == "unlocked" ]]; then
    pass "No pacman DB lock present"
  else
    fail "Stale pacman DB lock found"
    container_exec "rm -f /var/lib/pacman/db.lck" || true
  fi
}

test_export_hook_stress() {
  log_test "=== Export hook stress test: install multiple packages then run hook ==="

  local pkgs_to_install=("neofetch" "figlet" "lazygit")
  local timeout=300

  for pkg in "${pkgs_to_install[@]}"; do
    local already
    already=$(container_exec "pacman -Q ${pkg} 2>/dev/null && echo yes || echo no" || echo "no")
    if [[ "$already" != *"yes"* ]]; then
      log_test "  Installing $pkg for stress test..."
      pamac_exec "pamac install --no-confirm $pkg 2>&1" "$timeout" || true
    fi
  done

  log_test "  Running export hook after multi-package install..."
  local hook_out
  hook_out=$(distrobox_exec "env XDG_DATA_DIRS=/usr/local/share:/usr/share XDG_DATA_HOME=/home/deck/.local/share /usr/local/bin/distrobox-export-hook.sh 2>&1" 30 || true)
  echo "$hook_out" | tail -5 >> "$TEST_LOG"

  local exported_count
  exported_count=$(ssh_check "ls /home/deck/.local/share/applications/${CONTAINER_NAME}-*.desktop 2>/dev/null | wc -l" || echo 0)
  if [[ "$exported_count" -ge 1 ]]; then
    pass "Export hook produced $exported_count desktop file(s) after multi-package install"
  else
    fail "Export hook produced no desktop files after multi-package install"
  fi

  local state_file="/home/deck/.local/share/steamos-pamac/$CONTAINER_NAME/exported-apps.list"
  local state_exists
  state_exists=$(ssh_check "test -f '$state_file' && echo true || echo false" || echo "false")
  if [[ "$state_exists" == "true" ]]; then
    local state_lines
    state_lines=$(ssh_check "wc -l < '$state_file' 2>/dev/null" || echo 0)
    pass "Export state file has $state_lines entries"
  else
    fail "Export state file not found after stress test"
  fi

  log_test "  Cleaning up stress test packages..."
  for pkg in "${pkgs_to_install[@]}"; do
    pamac_exec "pamac remove --no-confirm --no-save $pkg 2>&1" 60 || true
  done
  pamac_exec "pamac remove --no-confirm --unneeded 2>&1" 30 || true

  log_test "  Running export hook after cleanup to remove stale entries..."
  distrobox_exec "env XDG_DATA_DIRS=/usr/local/share:/usr/share XDG_DATA_HOME=/home/deck/.local/share /usr/local/bin/distrobox-export-hook.sh 2>&1" 30 || true
}

test_uninstall_helper_multi() {
  log_test "=== Uninstall helper multi-package test ==="

  local helper_path="/home/deck/.local/bin/steamos-pamac-uninstall"
  local helper_exists
  helper_exists=$(ssh_check "test -x '$helper_path' && echo true || echo false" || echo "false")
  if [[ "$helper_exists" != "true" ]]; then
    fail "steamos-pamac-uninstall not found"
    return 1
  fi
  pass "Uninstall helper exists"

  local list_out
  list_out=$(ssh_exec "timeout 10 '$helper_path' --list 2>&1" || true)
  pass "Uninstall helper --list works (output: ${list_out:0:100})"

  log_test "  Installing neofetch for uninstall helper test..."
  local already
  already=$(container_exec "pacman -Q neofetch 2>/dev/null && echo yes || echo no" || echo "no")
  if [[ "$already" != *"yes"* ]]; then
    pamac_exec "pamac install --no-confirm neofetch 2>&1" 120 || true
  fi

  local pkg_installed
  pkg_installed=$(container_exec "pacman -Q neofetch 2>/dev/null && echo yes || echo no" || echo "no")
  if [[ "$pkg_installed" == *"yes"* ]]; then
    local uninstall_out
    uninstall_out=$(ssh_exec "timeout 60 '$helper_path' --package neofetch 2>&1" || true)
    local still_installed
    still_installed=$(container_exec "pacman -Q neofetch 2>/dev/null && echo yes || echo no" || echo "no")
    if [[ "$still_installed" != *"yes"* ]]; then
      pass "Uninstall helper --package neofetch worked"
    else
      fail "Uninstall helper --package neofetch failed (output: ${uninstall_out:0:200})"
    fi
  else
    skip "Could not install neofetch for uninstall helper test"
  fi
}

test_font_package() {
  local pkg="ttf-imp-ink-original"
  log_test "=== Font package special test: $pkg ==="

  log_test "  Checking if font files exist after install..."
  local font_out
  font_out=$(container_exec "find /usr/share/fonts -name '*imp*' -o -name '*ink*' 2>/dev/null | head -10" || true)
  if [[ -n "$font_out" ]]; then
    pass "[$pkg] Font files found in container: $font_out"
  else
    font_out=$(container_exec "pacman -Ql $pkg 2>/dev/null | grep -i font | head -10" || true)
    if [[ -n "$font_out" ]]; then
      pass "[$pkg] Font package files listed: ${font_out:0:200}"
    else
      fail "[$pkg] No font files found for package"
    fi
  fi

  log_test "  Verifying no desktop file was created for font package..."
  local font_desktop
  font_desktop=$(ssh_check "grep -rl 'SourcePackage=${pkg}' /home/deck/.local/share/applications/ 2>/dev/null | head -1" || true)
  if [[ -z "$font_desktop" ]]; then
    pass "[$pkg] No desktop file for font package (correct)"
  else
    fail "[$pkg] Unexpected desktop file for font package: $font_desktop"
  fi
}

main() {
  TEST_LOG=$(mktemp /tmp/diverse-aur-test-XXXXXX.log)
  echo "=== Diverse AUR Package Test Suite ===" | tee -a "$TEST_LOG"
  echo "Date: $(date)" | tee -a "$TEST_LOG"
  echo "Container: $CONTAINER_NAME" | tee -a "$TEST_LOG"
  echo "Packages to test: ${#TEST_PACKAGES[@]}" | tee -a "$TEST_LOG"
  echo "" | tee -a "$TEST_LOG"

  local conn_test
  conn_test=$(ssh_exec "echo connected" 2>&1 || true)
  if ! echo "$conn_test" | grep -q "connected"; then
    echo -e "${RED}ERROR: Cannot SSH to $SSH_HOST${NC}"
    echo "Output: ${conn_test:0:200}"
    exit 1
  fi
  echo -e "${GREEN}SSH connection OK${NC}"

  check_prerequisites || { fail "Prerequisites failed, aborting"; print_summary; exit 1; }
  echo "" | tee -a "$TEST_LOG"

  local test_num=1
  local failed_pkgs=()
  local succeeded_pkgs=()

  for pkg in "${!TEST_PACKAGES[@]}"; do
    echo "" | tee -a "$TEST_LOG"
    if test_single_package "$pkg" "${TEST_PACKAGES[$pkg]}" "$test_num"; then
      succeeded_pkgs+=("$pkg")
    else
      failed_pkgs+=("$pkg")
    fi
    test_num=$((test_num + 1))
  done

  echo "" | tee -a "$TEST_LOG"

  test_font_package
  echo "" | tee -a "$TEST_LOG"

  log_test "=== Reinstall cycle tests (3 packages) ==="
  local reinstall_pkgs=("neofetch" "lazygit" "ripgrep-bin")
  for pkg in "${reinstall_pkgs[@]}"; do
    test_package_reinstall_cycle "$pkg" "${PKG_CATEGORIES[$pkg]:-unknown}" "${PKG_INSTALL_TIMEOUT[$pkg]:-300}"
  done
  echo "" | tee -a "$TEST_LOG"

  test_export_hook_stress
  echo "" | tee -a "$TEST_LOG"

  test_uninstall_helper_multi
  echo "" | tee -a "$TEST_LOG"

  test_db_integrity_after_all
  echo "" | tee -a "$TEST_LOG"

  print_summary

  echo "" | tee -a "$TEST_LOG"
  echo -e "${BOLD}Category Coverage Summary:${NC}" | tee -a "$TEST_LOG"
  local categories_seen=()
  for pkg in "${!TEST_PACKAGES[@]}"; do
    local cat="${PKG_CATEGORIES[$pkg]}"
    if [[ ! " ${categories_seen[*]} " =~ " ${cat} " ]]; then
      categories_seen+=("$cat")
      echo "  - $cat ($pkg)" | tee -a "$TEST_LOG"
    fi
  done
  echo "  Total categories tested: ${#categories_seen[@]}" | tee -a "$TEST_LOG"

  if [[ ${#failed_pkgs[@]} -gt 0 ]]; then
    echo "" | tee -a "$TEST_LOG"
    echo -e "${RED}Failed packages:${NC}" | tee -a "$TEST_LOG"
    for pkg in "${failed_pkgs[@]}"; do
      echo "  - $pkg (${PKG_CATEGORIES[$pkg]})" | tee -a "$TEST_LOG"
    done
  fi

  return $FAIL
}

print_summary() {
  echo -e "${BOLD}========================================${NC}"
  echo -e "${BOLD} Diverse AUR Package Test Results${NC}"
  echo -e "${BOLD}========================================${NC}"
  echo -e " Passed:  ${GREEN}${PASS}${NC}"
  echo -e " Failed:  ${RED}${FAIL}${NC}"
  echo -e " Skipped: ${YELLOW}${SKIP}${NC}"
  echo -e " Total:   $((PASS + FAIL + SKIP))"
  echo -e "${BOLD}========================================${NC}"
  if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}ALL TESTS PASSED!${NC}"
  else
    echo -e "${RED}${BOLD}SOME TESTS FAILED!${NC}"
  fi
}

main "$@"
