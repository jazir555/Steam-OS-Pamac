#!/bin/bash
# End-to-end test for SteamOS-Pamac-Installer.sh
# Tests: install, desktop integration, AUR install, uninstall
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/../SteamOS-Pamac-Installer.sh"

if [[ ! -f "$INSTALLER" ]]; then
    echo "ERROR: Installer script not found at $INSTALLER"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
CONTAINER_NAME="arch-pamac"
TEST_LOG="/tmp/steamos-pamac-e2e-test.log"

log_test() { echo -e "${BOLD}[TEST]${NC} $*" | tee -a "$TEST_LOG"; }
pass() { echo -e "  ${GREEN}PASS${NC}: $*" | tee -a "$TEST_LOG"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $*" | tee -a "$TEST_LOG"; FAIL=$((FAIL + 1)); }

cleanup_test_env() {
    log_test "Cleaning up test environment..."
    chmod +x "$INSTALLER"
    bash "$INSTALLER" --uninstall 2>&1 | tee -a "$TEST_LOG" || true
    podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
    rm -rf "$HOME/.local/share/steamos-pamac/$CONTAINER_NAME" 2>/dev/null || true
    rm -rf "$HOME/.cache/yay-$CONTAINER_NAME" 2>/dev/null || true
    rm -f "$HOME/.local/bin/pamac-$CONTAINER_NAME" 2>/dev/null || true
    find "$HOME/.local/share/applications" -maxdepth 1 -type f -name "${CONTAINER_NAME}-*.desktop" -delete 2>/dev/null || true
    rm -f "$HOME/.local/share/applications/${CONTAINER_NAME}.desktop" 2>/dev/null || true
}

test_install() {
    log_test "=== TEST: Fresh installation ==="
    cleanup_test_env

    log_test "Running installer..."
    if bash "$INSTALLER" 2>&1 | tee -a "$TEST_LOG"; then
        pass "Installer completed successfully"
    else
        fail "Installer failed with exit code $?"
        return 1
    fi

    log_test "Verifying container exists..."
    if podman inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        pass "Container exists"
    else
        fail "Container not found"
        return 1
    fi

    log_test "Verifying container is running..."
    local status
    status=$(podman inspect "$CONTAINER_NAME" --format '{{.State.Running}}' 2>/dev/null)
    if [[ "$status" == "true" ]]; then
        pass "Container is running"
    else
        fail "Container not running (status: $status)"
    fi

    log_test "Verifying container is usable..."
    if podman exec -i -u 0 "$CONTAINER_NAME" bash -c "echo ready" 2>/dev/null | grep -q "ready"; then
        pass "Container exec works"
    else
        fail "Container exec failed"
        return 1
    fi

    log_test "Verifying pacman works inside container..."
    if podman exec -i -u 0 "$CONTAINER_NAME" pacman --version >/dev/null 2>&1; then
        pass "pacman functional"
    else
        fail "pacman not functional"
    fi

    log_test "Verifying yay is installed..."
    if podman exec -i -u mmeadow "$CONTAINER_NAME" bash -c "command -v yay" 2>/dev/null; then
        pass "yay installed"
    else
        fail "yay not found"
    fi

    log_test "Verifying pamac-manager is installed..."
    if podman exec -i -u mmeadow "$CONTAINER_NAME" bash -c "command -v pamac-manager" 2>/dev/null; then
        pass "pamac-manager installed"
    else
        fail "pamac-manager not found"
    fi

    log_test "Verifying pamac AUR config..."
    if podman exec -i -u 0 "$CONTAINER_NAME" grep -q "^EnableAUR" /etc/pamac.conf 2>/dev/null; then
        pass "AUR enabled in pamac config"
    else
        fail "AUR not enabled in pamac config"
    fi

    log_test "Verifying desktop file was created..."
    local desktop_file
    desktop_file=$(find "$HOME/.local/share/applications" -maxdepth 1 -type f -name "${CONTAINER_NAME}-*.desktop" 2>/dev/null | head -1)
    if [[ -n "$desktop_file" && -f "$desktop_file" ]]; then
        pass "Desktop file created: $desktop_file"
    else
        fail "Desktop file not found"
    fi

    log_test "Verifying desktop file has X-SteamOS-Pamac markers..."
    if [[ -n "$desktop_file" ]] && grep -q "X-SteamOS-Pamac-Managed=true" "$desktop_file" 2>/dev/null; then
        pass "Desktop file has X-SteamOS-Pamac-Managed marker"
    else
        fail "Desktop file missing X-SteamOS-Pamac-Managed marker"
    fi

    if [[ -n "$desktop_file" ]] && grep -q "X-SteamOS-Pamac-Container=${CONTAINER_NAME}" "$desktop_file" 2>/dev/null; then
        pass "Desktop file has X-SteamOS-Pamac-Container marker"
    else
        fail "Desktop file missing X-SteamOS-Pamac-Container marker"
    fi

    log_test "Verifying CLI wrapper..."
    if [[ -f "$HOME/.local/bin/pamac-$CONTAINER_NAME" ]]; then
        pass "CLI wrapper exists"
    else
        fail "CLI wrapper not found"
    fi

    log_test "Verifying export state directory..."
    if [[ -d "$HOME/.local/share/steamos-pamac/$CONTAINER_NAME" ]]; then
        pass "Export state directory exists"
    else
        fail "Export state directory not found"
    fi

    log_test "Verifying pacman hook was installed..."
    if podman exec -i -u 0 "$CONTAINER_NAME" test -f /usr/local/bin/distrobox-export-hook.sh 2>/dev/null; then
        pass "Export hook script installed"
    else
        fail "Export hook script not found"
    fi

    if podman exec -i -u 0 "$CONTAINER_NAME" test -f /etc/pacman.d/hooks/99-distrobox-export.hook 2>/dev/null; then
        pass "Pacman hook installed"
    else
        fail "Pacman hook not found"
    fi

    log_test "Verifying bootstrap script..."
    if podman exec -i -u 0 "$CONTAINER_NAME" test -x /usr/local/bin/pamac-session-bootstrap.sh 2>/dev/null; then
        pass "Bootstrap script exists and executable"
    else
        fail "Bootstrap script not found or not executable"
    fi

    log_test "Verifying sudo configuration..."
    if podman exec -i -u 0 "$CONTAINER_NAME" test -f /etc/sudoers.d/99-wheel-nopasswd 2>/dev/null; then
        pass "Passwordless sudo configured"
    else
        fail "Passwordless sudo not configured"
    fi
}

test_aur_install() {
    log_test "=== TEST: Installing an AUR package via yay ==="

    log_test "Installing neofetch via yay (should be quick)..."
    if podman exec -i -u 0 "$CONTAINER_NAME" bash -c "sudo -Hu mmeadow yay -S --noconfirm --needed --noprogressbar neofetch" 2>&1 | tee -a "$TEST_LOG"; then
        pass "neofetch installed successfully via yay"
    else
        fail "neofetch install via yay failed"
        return 1
    fi

    log_test "Verifying neofetch is installed..."
    if podman exec -i -u mmeadow "$CONTAINER_NAME" bash -c "command -v neofetch" 2>/dev/null; then
        pass "neofetch found in PATH"
    else
        fail "neofetch not found after install"
    fi
}

test_hook_export() {
    log_test "=== TEST: Pacman hook exports newly installed apps ==="

    log_test "Triggering export hook manually..."
    if podman exec -i -u 0 "$CONTAINER_NAME" bash /usr/local/bin/distrobox-export-hook.sh 2>&1 | tee -a "$TEST_LOG"; then
        pass "Export hook ran successfully"
    else
        fail "Export hook failed"
    fi

    log_test "Verifying export hook log..."
    if podman exec -i -u 0 "$CONTAINER_NAME" cat /home/mmeadow/.local/share/steamos-pamac/arch-pamac/export-hook.log 2>/dev/null | grep -q "Exported"; then
        pass "Hook log shows export activity"
    else
        log_test "(Hook may not have exported additional apps, which is OK)"
    fi

    log_test "Verifying desktop file was NOT deleted by hook..."
    local desktop_file
    desktop_file=$(find "$HOME/.local/share/applications" -maxdepth 1 -type f -name "${CONTAINER_NAME}-*.desktop" 2>/dev/null | head -1)
    if [[ -n "$desktop_file" && -f "$desktop_file" ]]; then
        pass "Desktop file preserved after hook run: $desktop_file"
    else
        fail "Desktop file was DELETED by hook!"
    fi
}

test_uninstall() {
    log_test "=== TEST: Uninstallation ==="

    log_test "Running uninstall..."
    if bash "$INSTALLER" --uninstall 2>&1 | tee -a "$TEST_LOG"; then
        pass "Uninstaller completed"
    else
        fail "Uninstaller reported errors (exit code $?)"
    fi

    log_test "Verifying container is removed..."
    if ! podman inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        pass "Container removed"
    else
        fail "Container still exists"
        podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
    fi

    log_test "Verifying desktop files cleaned..."
    local remaining
    remaining=$(find "$HOME/.local/share/applications" -maxdepth 1 -type f -name "${CONTAINER_NAME}-*.desktop" 2>/dev/null | wc -l)
    if [[ "$remaining" -eq 0 ]]; then
        pass "Desktop files cleaned ($remaining remaining)"
    else
        fail "Desktop files still present ($remaining remaining)"
    fi

    log_test "Verifying export state cleaned..."
    if [[ ! -d "$HOME/.local/share/steamos-pamac/$CONTAINER_NAME" ]]; then
        pass "Export state directory removed"
    else
        fail "Export state directory still exists"
    fi

    log_test "Verifying CLI wrapper removed..."
    if [[ ! -f "$HOME/.local/bin/pamac-$CONTAINER_NAME" ]]; then
        pass "CLI wrapper removed"
    else
        fail "CLI wrapper still exists"
    fi

    log_test "Verifying build cache cleaned..."
    if [[ ! -d "$HOME/.cache/yay-$CONTAINER_NAME" ]]; then
        pass "Build cache removed"
    else
        fail "Build cache still exists"
        rm -rf "$HOME/.cache/yay-$CONTAINER_NAME" 2>/dev/null || true
    fi
}

test_reinstall() {
    log_test "=== TEST: Reinstallation after uninstall ==="

    log_test "Running installer again..."
    if bash "$INSTALLER" 2>&1 | tee -a "$TEST_LOG"; then
        pass "Reinstaller completed successfully"
    else
        fail "Reinstaller failed"
        return 1
    fi

    log_test "Verifying container exists after reinstall..."
    if podman inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        pass "Container re-created"
    else
        fail "Container not found after reinstall"
        return 1
    fi

    log_test "Verifying container is usable after reinstall..."
    if podman exec -i -u 0 "$CONTAINER_NAME" bash -c "echo ready" 2>/dev/null | grep -q "ready"; then
        pass "Container usable after reinstall"
    else
        fail "Container not usable after reinstall"
    fi
}

print_summary() {
    echo
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}    End-to-End Test Results${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo -e "  Passed: ${GREEN}${PASS}${NC}"
    echo -e "  Failed: ${RED}${FAIL}${NC}"
    echo -e "  Total:  $((PASS + FAIL))"
    echo -e "${BOLD}========================================${NC}"
    echo
    if [[ $FAIL -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}ALL TESTS PASSED!${NC}"
        return 0
    else
        echo -e "${RED}${BOLD}SOME TESTS FAILED!${NC}"
        return 1
    fi
}

main() {
    echo -e "${BOLD}SteamOS-Pamac End-to-End Test${NC}"
    echo "Log: $TEST_LOG"
    echo

    > "$TEST_LOG"

    test_install      || true
    test_aur_install  || true
    test_hook_export  || true
    test_uninstall    || true
    test_reinstall    || true

    print_summary
}

main "$@"
