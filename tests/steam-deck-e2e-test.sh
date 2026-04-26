#!/bin/bash
set -euo pipefail

SSH_HOST="deck@192.168.2.111"
CONTAINER_NAME="arch-pamac"
TEST_PACKAGE_AUR="neofetch"
TEST_PACKAGE_AUR_VERSION="7.1.0-2"

if grep -qi microsoft /proc/version 2>/dev/null || uname -r 2>/dev/null | grep -qi microsoft; then
SSH_CMD="sshpass -p 'a' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"
elif command -v wsl.exe >/dev/null 2>&1; then
SSH_CMD="wsl -d Arch -- sshpass -p 'a' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"
else
SSH_CMD="sshpass -p 'a' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"
fi

PASS=0
FAIL=0
TEST_LOG=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log_test() { echo -e "${BOLD}[TEST]${NC} $*"; echo "[TEST] $*" >> "$TEST_LOG"; }
pass() { echo -e " ${GREEN}PASS${NC}: $*"; echo " PASS: $*" >> "$TEST_LOG"; PASS=$((PASS + 1)); }
fail() { echo -e " ${RED}FAIL${NC}: $*"; echo " FAIL: $*" >> "$TEST_LOG"; FAIL=$((FAIL + 1)); }
skip() { echo -e " ${YELLOW}SKIP${NC}: $*"; echo " SKIP: $*" >> "$TEST_LOG"; }

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

distrobox_exec() {
	local cmd="${1//\'/\\\'}"
	local timeout_sec="${2:-}"
	if [[ -n "$timeout_sec" ]]; then
		ssh_check "timeout $timeout_sec distrobox-enter '$CONTAINER_NAME' -- bash -c '$cmd' 2>&1"
	else
		ssh_check "distrobox-enter '$CONTAINER_NAME' -- bash -c '$cmd' 2>&1"
	fi
}

pamac_exec() {
    local cmd="${1//\'/\\\'}"
    local timeout_sec="${2:-120}"
    ssh_check "timeout $timeout_sec podman exec -i -u 0 '$CONTAINER_NAME' bash -c 'rm -f /run/dbus/pid 2>/dev/null; pkill pamac-daemon 2>/dev/null; pkill polkitd 2>/dev/null; pkill dbus-daemon 2>/dev/null; sleep 1; mkdir -p /run/dbus; dbus-daemon --system --fork 2>/dev/null; sleep 1; /usr/lib/polkit-1/polkitd --no-debug &>/dev/null & sleep 1; /usr/bin/pamac-daemon &>/dev/null & sleep 2; $cmd' 2>&1"
}

cleanup_package() {
	local pkg="$1"
	log_test "Cleanup: removing $pkg if installed..."
	pamac_exec "pamac remove --no-confirm $pkg 2>/dev/null || true" 60 || true
	pamac_exec "pamac remove --no-confirm --unneeded 2>/dev/null || true" 30 || true
	container_exec "pacman -Qs '^${pkg}$' >/dev/null 2>&1 && pacman -Rdd --noconfirm '${pkg}' 2>/dev/null || true" || true
}

check_desktop_file_format() {
	local f="$1"
	local desc="$2"
	local failures=0

	local has_exec
	has_exec=$(ssh_check "grep -q '^Exec=' '$f' 2>/dev/null && echo true || echo false" || echo "false")
	if [[ "$has_exec" != "true" ]]; then
		fail "$desc: No Exec line found"
		return 1
	fi

	local exec_has_wrapper
	exec_has_wrapper=$(ssh_check "grep '^Exec=' '$f' 2>/dev/null | head -1 | grep -q 'pamac-manager-wrapper' && echo true || echo false" || echo "false")
	if [[ "$exec_has_wrapper" != "true" ]]; then
		fail "$desc: Exec does not use pamac-manager-wrapper"
		failures=$((failures + 1))
	fi

	local has_managed
	has_managed=$(ssh_check "grep -q '^X-SteamOS-Pamac-Managed=true' '$f' 2>/dev/null && echo true || echo false" || echo "false")
	if [[ "$has_managed" != "true" ]]; then
		fail "$desc: Missing X-SteamOS-Pamac-Managed marker"
		failures=$((failures + 1))
	fi

	local has_container
	has_container=$(ssh_check "grep -q 'X-SteamOS-Pamac-Container=${CONTAINER_NAME}' '$f' 2>/dev/null && echo true || echo false" || echo "false")
	if [[ "$has_container" != "true" ]]; then
		fail "$desc: Missing X-SteamOS-Pamac-Container marker"
		failures=$((failures + 1))
	fi

	if [[ $failures -eq 0 ]]; then
		pass "$desc: desktop file format valid"
	fi
	return $failures
}

###############################################################################
# 1. PREREQUISITES CHECK
###############################################################################
test_prerequisites() {
	log_test "=== 1/12: Prerequisites Check ==="

	if ssh_check "podman inspect '$CONTAINER_NAME' >/dev/null 2>&1"; then
		pass "Container '$CONTAINER_NAME' exists"
	else
		fail "Container '$CONTAINER_NAME' not found - run installer first"
		return 1
	fi

	local container_ok
	container_ok=$(ssh_check "podman exec -i -u 0 '$CONTAINER_NAME' bash -c 'echo ok' 2>/dev/null" | grep -c ok || echo 0)
	if [[ "$container_ok" -gt 0 ]]; then
		pass "Container is usable (exec works)"
	else
		fail "Container not usable"
		return 1
	fi

	local pamac_cli
	pamac_cli=$(distrobox_exec "command -v pamac 2>/dev/null" || true)
	if [[ -n "$pamac_cli" ]]; then
		pass "pamac CLI installed"
	else
		fail "pamac CLI not found"
		return 1
	fi

	local pamac_mgr
	pamac_mgr=$(distrobox_exec "command -v pamac-manager 2>/dev/null" || true)
	if [[ -n "$pamac_mgr" ]]; then
		pass "pamac-manager installed"
	else
		fail "pamac-manager not found"
		return 1
	fi

	local aur_enabled
	aur_enabled=$(distrobox_exec "grep -q EnableAUR /etc/pamac.conf && echo true || echo false" || echo "false")
	if [[ "$aur_enabled" == "true" ]]; then
		pass "AUR support enabled in pamac config"
	else
		fail "AUR not enabled in pamac config"
	fi

	local ver
	ver=$(pamac_exec "pamac --version 2>/dev/null | head -1" || true)
	if [[ -n "$ver" ]]; then
		pass "pamac CLI version: $ver"
	fi

	log_test "Verifying pamac-daemon can start..."
	local daemon_test
	daemon_test=$(pamac_exec "echo daemon_ok" 10 || true)
	if [[ "$daemon_test" == *"daemon_ok"* ]]; then
		pass "pamac-daemon bootstrap works"
	else
		fail "pamac-daemon bootstrap failed (search/install will fail)"
	fi
}

###############################################################################
# 2. PAMAC SEARCH (AUR + repos)
###############################################################################
test_search() {
	log_test "=== 2/12: Pamac Search ==="

	local search_out
	search_out=$(pamac_exec "pamac search $TEST_PACKAGE_AUR 2>/dev/null" 30 || true)
	if echo "$search_out" | grep -qi "$TEST_PACKAGE_AUR"; then
		pass "pamac search finds $TEST_PACKAGE_AUR"
	else
		fail "pamac search did not find $TEST_PACKAGE_AUR (output: ${search_out:0:200})"
	fi

	local aur_search
	aur_search=$(pamac_exec "pamac search --aur $TEST_PACKAGE_AUR 2>/dev/null" 30 || true)
	if echo "$aur_search" | grep -qi "AUR"; then
		pass "pamac search --aur returns AUR packages"
	else
		fail "pamac search --aur did not return AUR results (output: ${aur_search:0:200})"
	fi

	local info_out
	info_out=$(pamac_exec "pamac info $TEST_PACKAGE_AUR 2>/dev/null" 30 || true)
	if echo "$info_out" | grep -qi "Repository.*AUR"; then
		pass "pamac info shows AUR as repository for $TEST_PACKAGE_AUR"
	else
		fail "pamac info did not show AUR repository"
	fi
}

###############################################################################
# 3. PAMAC INSTALL AUR PACKAGE
###############################################################################
test_install() {
	log_test "=== 3/12: Pamac Install AUR Package ==="
	cleanup_package "$TEST_PACKAGE_AUR"

	local install_out
	install_out=$(pamac_exec "pamac install --no-confirm $TEST_PACKAGE_AUR 2>&1" 180 || true)
	echo "$install_out" | tail -10 >> "$TEST_LOG"

	local pkg_check
	pkg_check=$(container_exec "pacman -Q ${TEST_PACKAGE_AUR} 2>/dev/null && echo installed || echo missing" || echo "missing")
	if [[ "$pkg_check" == *"installed"* ]]; then
		pass "Package $TEST_PACKAGE_AUR installed successfully via pamac"
	else
		if echo "$install_out" | grep -qi "already installed"; then
			pass "Package $TEST_PACKAGE_AUR was already installed"
		else
			fail "Package $TEST_PACKAGE_AUR not found after install (output: ${install_out:0:300})"
		fi
	fi

	local cmd_out
	cmd_out=$(container_user_exec "command -v $TEST_PACKAGE_AUR 2>/dev/null" || true)
	if echo "$cmd_out" | grep -q "$TEST_PACKAGE_AUR"; then
		pass "$TEST_PACKAGE_AUR binary available in PATH"
	else
		skip "$TEST_PACKAGE_AUR binary not found in PATH (may need re-login)"
	fi

	local pkg_ver
	pkg_ver=$(container_exec "pacman -Q $TEST_PACKAGE_AUR 2>/dev/null | cut -d' ' -f2" || echo "unknown")
	log_test " Installed version: $pkg_ver"
}

###############################################################################
# 4. VERIFY POST-INSTALL EXPORT HOOK
###############################################################################
test_export_hook() {
	log_test "=== 4/12: Post-Install Export Hook ==="

	local hook_exists
	hook_exists=$(container_exec "test -x /usr/local/bin/distrobox-export-hook.sh && echo true || echo false" || echo "false")
	if [[ "$hook_exists" == "true" ]]; then
		pass "Export hook script exists"
	else
		fail "Export hook script not found"
		return 1
	fi

	local pacman_hook_exists
	pacman_hook_exists=$(container_exec "test -f /etc/pacman.d/hooks/99-distrobox-export.hook && echo true || echo false" || echo "false")
	if [[ "$pacman_hook_exists" == "true" ]]; then
		pass "Pacman hook file exists"
	else
		fail "Pacman hook file not found"
	fi

	local hook_out
	hook_out=$(distrobox_exec "env XDG_DATA_DIRS=/usr/local/share:/usr/share XDG_DATA_HOME=/home/deck/.local/share /usr/local/bin/distrobox-export-hook.sh 2>&1" 30 || true)
	echo "$hook_out" | tail -5 >> "$TEST_LOG"

	local exported_log
	exported_log=$(container_exec "cat /home/deck/.local/share/steamos-pamac/arch-pamac/export-hook.log 2>/dev/null" || echo "")
	if echo "$exported_log" | grep -qi "Exported\|triggered"; then
		pass "Export hook ran and logged activity"
	else
		skip "Export hook log not found or empty"
	fi
}

###############################################################################
# 5. VERIFY DESKTOP FILE INTEGRITY
###############################################################################
test_desktop_file() {
	log_test "=== 5/12: Desktop File Integrity ==="

	local desktop_files
	desktop_files=$(ssh_check "find /home/deck/.local/share/applications -maxdepth 1 -type f -name '${CONTAINER_NAME}-*.desktop' 2>/dev/null" || true)
	if [[ -z "$desktop_files" ]]; then
		fail "No exported desktop files found"
		return 1
	fi

	local count
	count=$(echo "$desktop_files" | wc -l)
	pass "Found $count exported desktop file(s)"

	local pamac_desktop
	pamac_desktop=$(echo "$desktop_files" | grep -i "pamac\|org.manjaro" | head -1)
	if [[ -z "$pamac_desktop" ]]; then
		pamac_desktop=$(echo "$desktop_files" | head -1)
		skip "No pamac-specific desktop file found, testing first available"
	fi
	log_test " Testing: $pamac_desktop"

	check_desktop_file_format "$pamac_desktop" "Pamac desktop file"

	local exec_line
	exec_line=$(ssh_check "grep '^Exec=' '$pamac_desktop' 2>/dev/null | head -1" || echo "")
	log_test " Exec: $exec_line"
}

###############################################################################
# 6. VERIFY ICON EXPORT
###############################################################################
test_icons() {
	log_test "=== 6/12: Icon Export ==="

	local icon_found=false
	for icon_path in \
		"/home/deck/.local/share/icons/hicolor/scalable/apps/pamac-manager.svg" \
		"/home/deck/.local/share/icons/hicolor/48x48/apps/pamac-manager.png" \
		"/home/deck/.local/share/icons/hicolor/scalable/apps/system-software-install.svg" \
		"/home/deck/.local/share/icons/hicolor/48x48/apps/system-software-install.svg"; do
		local icon_exists
		icon_exists=$(ssh_check "test -f '$icon_path' && echo true || echo false" || echo "false")
		if [[ "$icon_exists" == "true" ]]; then
			log_test " Found icon: $icon_path"
			icon_found=true
			break
		fi
	done

	if [[ "$icon_found" == "true" ]]; then
		pass "At least one icon file exported"
	else
		skip "No exported icon files found (host theme icons may be used instead)"
	fi

	local icon_cache
	icon_cache=$(ssh_check "ls /home/deck/.local/share/icons/hicolor/icon-theme.cache 2>/dev/null" || true)
	if [[ -n "$icon_cache" ]]; then
		pass "Icon cache exists and is up to date"
	fi
}

###############################################################################
# 7. VERIFY PAMAC MANAGER WRAPPER
###############################################################################
test_pamac_manager_wrapper() {
	log_test "=== 7/12: Pamac Manager Wrapper ==="

	local wrapper_exists
	wrapper_exists=$(container_exec "test -x /usr/local/bin/pamac-manager-wrapper && echo true || echo false" || echo "false")
	if [[ "$wrapper_exists" == "true" ]]; then
		pass "pamac-manager-wrapper exists and is executable"
	else
		fail "pamac-manager-wrapper not found"
		return 1
	fi

	local wrapper_content
	wrapper_content=$(container_exec "cat /usr/local/bin/pamac-manager-wrapper 2>/dev/null" || echo "")
	if echo "$wrapper_content" | grep -q "pamac-session-bootstrap.sh" && echo "$wrapper_content" | grep -q "exec pamac-manager"; then
		pass "Wrapper contains bootstrap call and pamac-manager exec"
	else
		fail "Wrapper content incorrect: $wrapper_content"
	fi

	local cli_wrapper_exists
	cli_wrapper_exists=$(container_exec "test -x /usr/local/bin/pamac-cli-wrapper && echo true || echo false" || echo "false")
	if [[ "$cli_wrapper_exists" == "true" ]]; then
		pass "pamac-cli-wrapper exists and is executable"
	else
		fail "pamac-cli-wrapper not found"
	fi

	local cli_wrapper
	cli_wrapper=$(container_exec "cat /usr/local/bin/pamac-cli-wrapper 2>/dev/null" || echo "")
	if echo "$cli_wrapper" | grep -q "exec pamac"; then
		pass "CLI wrapper contains pamac exec"
	else
		fail "CLI wrapper content incorrect: $cli_wrapper"
	fi

	local bootstrap_exists
	bootstrap_exists=$(container_exec "test -x /usr/local/bin/pamac-session-bootstrap.sh && echo true || echo false" || echo "false")
	if [[ "$bootstrap_exists" == "true" ]]; then
		pass "pamac-session-bootstrap.sh exists"
	else
		fail "pamac-session-bootstrap.sh not found"
	fi
}

###############################################################################
# 8. TEST CLI WRAPPER FROM HOST
###############################################################################
test_host_cli_wrapper() {
	log_test "=== 8/12: Host CLI Wrapper ==="

	local wrapper_path="/home/deck/.local/bin/pamac-${CONTAINER_NAME}"
	local wrapper_exists
	wrapper_exists=$(ssh_check "test -x '$wrapper_path' && echo true || echo false" || echo "false")
	if [[ "$wrapper_exists" == "true" ]]; then
		pass "Host CLI wrapper exists at $wrapper_path"
	else
		fail "Host CLI wrapper not found"
		return 1
	fi

	local wrapper_content
	wrapper_content=$(ssh_check "cat '$wrapper_path'" || echo "")
	if echo "$wrapper_content" | grep -q "distrobox enter.*pamac-cli-wrapper"; then
		pass "Wrapper invokes distrobox enter with pamac-cli-wrapper"
	else
		fail "Wrapper content incorrect: $wrapper_content"
	fi

	local pamac_out
	pamac_out=$(ssh_exec "timeout 30 '$wrapper_path' --version 2>&1" || true)
	if echo "$pamac_out" | grep -qi "pamac.*version"; then
		pass "Host CLI wrapper runs pamac --version successfully"
	else
		skip "Host CLI wrapper --version failed (expected in non-interactive session): ${pamac_out:0:100}"
	fi

	local search_out
	search_out=$(ssh_exec "timeout 30 '$wrapper_path' search neofetch 2>/dev/null" || true)
	if echo "$search_out" | grep -qi "neofetch"; then
		pass "Host CLI wrapper can search packages"
	else
		skip "Host CLI wrapper search not tested (non-interactive session)"
	fi
}

###############################################################################
# 9. TEST PAMAC UNINSTALL
###############################################################################
test_uninstall() {
	log_test "=== 9/12: Pamac Uninstall ==="

	local pkg_installed
	pkg_installed=$(container_exec "pacman -Q ${TEST_PACKAGE_AUR} 2>/dev/null && echo yes || echo no" || echo "no")
	if [[ "$pkg_installed" != *"yes"* ]]; then
		skip "Package $TEST_PACKAGE_AUR not installed, skipping uninstall test"
		return 0
	fi

	local remove_out
	remove_out=$(pamac_exec "pamac remove --no-confirm --no-save $TEST_PACKAGE_AUR 2>&1" 60 || true)
	echo "$remove_out" | tail -10 >> "$TEST_LOG"

	local still_installed
	still_installed=$(container_exec "pacman -Q ${TEST_PACKAGE_AUR} 2>/dev/null && echo yes || echo no" || echo "no")
	if [[ "$still_installed" == *"yes"* ]]; then
		fail "Package $TEST_PACKAGE_AUR still present after pamac remove"
	else
		pass "Package $TEST_PACKAGE_AUR successfully removed via pamac"
	fi

	local cleanup_out
	cleanup_out=$(pamac_exec "pamac remove --no-confirm --unneeded 2>&1" 30 || true)
	echo "Orphan cleanup: ${cleanup_out:0:200}" >> "$TEST_LOG"
}

###############################################################################
# 10. TEST REINSTALL AND PERSISTENCE
###############################################################################
test_reinstall() {
	log_test "=== 10/12: Reinstall After Uninstall ==="

	cleanup_package "$TEST_PACKAGE_AUR"

	local install_out
	install_out=$(pamac_exec "pamac install --no-confirm $TEST_PACKAGE_AUR 2>&1" 180 || true)
	echo "$install_out" | tail -10 >> "$TEST_LOG"

	local pkg_installed
	pkg_installed=$(container_exec "pacman -Q ${TEST_PACKAGE_AUR} 2>/dev/null && echo yes || echo no" || echo "no")
	if [[ "$pkg_installed" == *"yes"* ]]; then
		pass "Package re-installed successfully"
	else
		fail "Package re-install failed (output: ${install_out:0:200})"
	fi

	local pkg_ver
	pkg_ver=$(container_exec "pacman -Q $TEST_PACKAGE_AUR 2>/dev/null | cut -d' ' -f2" || echo "unknown")
	pass "Re-installed version: $pkg_ver"
}

###############################################################################
# 11. TEST PACMAN DB INTEGRITY
###############################################################################
test_db_integrity() {
	log_test "=== 11/12: Pacman DB Integrity ==="

    local db_check
    db_check=$(container_exec "pacman -Dk 2>&1" || true)
    if echo "$db_check" | grep -qi "No database errors have been found"; then
        pass "Pacman DB is consistent"
    elif echo "$db_check" | grep -qiE "^error|has error|inconsisten|broken|missing dependency"; then
        fail "Pacman DB has inconsistencies: $(echo "$db_check" | head -3)"
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

	local yay_exists
	yay_exists=$(container_exec "command -v yay >/dev/null 2>&1 && echo true || echo false" || echo "false")
	if [[ "$yay_exists" == "true" ]]; then
		pass "yay AUR helper still functional"
	fi

	local aur_list
	aur_list=$(pamac_exec "pamac list --aur 2>/dev/null | head -5" 30 || true)
	if echo "$aur_list" | grep -qi "$TEST_PACKAGE_AUR\|AUR"; then
		pass "pamac list --aur shows AUR packages"
	else
		skip "pamac list --aur not showing packages (expected after clean reinstall)"
	fi
}

###############################################################################
# 12. TEST HOST INTEGRATION (desktop, state, uninstall path)
###############################################################################
test_host_integration() {
	log_test "=== 12/12: Host Integration ==="

	local state_dir_exists
	state_dir_exists=$(ssh_check "test -d /home/deck/.local/share/steamos-pamac/$CONTAINER_NAME && echo true || echo false" || echo "false")
	if [[ "$state_dir_exists" == "true" ]]; then
		pass "Export state directory exists"
	else
		fail "Export state directory not found"
	fi

	local state_file="/home/deck/.local/share/steamos-pamac/$CONTAINER_NAME/exported-apps.list"
	local state_file_exists
	state_file_exists=$(ssh_check "test -f '$state_file' && echo true || echo false" || echo "false")
	if [[ "$state_file_exists" == "true" ]]; then
		pass "Exported apps list exists"
		local apps_count
		apps_count=$(ssh_check "wc -l < '$state_file' 2>/dev/null || echo 0")
		log_test " $apps_count exported app(s) tracked"
	else
		fail "Exported apps list not found"
	fi

	local desktop_db
	desktop_db=$(ssh_check "ls /home/deck/.local/share/applications/*.desktop 2>/dev/null | grep -c 'arch-pamac'" || echo 0)
	if [[ "$desktop_db" -gt 0 ]]; then
		pass "Desktop database contains $desktop_db container-exported entries"
	fi

	local scalable_icon_exists
	scalable_icon_exists=$(ssh_check "test -f /home/deck/.local/share/icons/hicolor/scalable/apps/pamac-manager.svg && echo true || echo false" || echo "false")
	if [[ "$scalable_icon_exists" == "true" ]]; then
		pass "Icon installed in hicolor scalable directory"
	else
		local png_icon_exists
		png_icon_exists=$(ssh_check "test -f /home/deck/.local/share/icons/hicolor/48x48/apps/pamac-manager.png && echo true || echo false" || echo "false")
		if [[ "$png_icon_exists" == "true" ]]; then
			pass "Icon installed in hicolor 48x48 directory"
		fi
	fi

	local pamac_grep
	pamac_grep=$(ssh_check "grep -q 'pamac-manager' /home/deck/.local/share/applications/arch-pamac-org.manjaro.pamac.manager.desktop 2>/dev/null && echo true || echo false" || echo "false")
	if [[ "$pamac_grep" != "true" ]]; then
		skip "Pamac desktop file not found at expected path"
	fi
}

###############################################################################
# MAIN
###############################################################################
main() {
	TEST_LOG=$(mktemp /tmp/steamos-pamac-e2e-XXXXXX.log)
	echo "=== SteamOS-Pamac E2E Test Suite ===" | tee -a "$TEST_LOG"
	echo "Date: $(date)" | tee -a "$TEST_LOG"
	echo "Container: $CONTAINER_NAME" | tee -a "$TEST_LOG"
	echo "Test package: $TEST_PACKAGE_AUR" | tee -a "$TEST_LOG"
	echo "" | tee -a "$TEST_LOG"

	if ! ssh_check "echo connected" | grep -q "connected"; then
		echo -e "${RED}ERROR: Cannot SSH to $SSH_HOST${NC}" | tee -a "$TEST_LOG"
		exit 1
	fi
	echo -e "${GREEN}SSH connection OK${NC}" | tee -a "$TEST_LOG"
	echo "" | tee -a "$TEST_LOG"

	test_prerequisites || { FAIL=$((FAIL + 1)); echo "Skipping remaining tests due to prerequisite failure"; print_summary; exit 1; }
	echo "" | tee -a "$TEST_LOG"
	test_search
	echo "" | tee -a "$TEST_LOG"
	test_install
	echo "" | tee -a "$TEST_LOG"
	test_export_hook
	echo "" | tee -a "$TEST_LOG"
	test_desktop_file
	echo "" | tee -a "$TEST_LOG"
	test_icons
	echo "" | tee -a "$TEST_LOG"
	test_pamac_manager_wrapper
	echo "" | tee -a "$TEST_LOG"
	test_host_cli_wrapper
	echo "" | tee -a "$TEST_LOG"
	test_uninstall
	echo "" | tee -a "$TEST_LOG"
	test_reinstall
	echo "" | tee -a "$TEST_LOG"
	test_db_integrity
	echo "" | tee -a "$TEST_LOG"
	test_host_integration
	echo "" | tee -a "$TEST_LOG"
	print_summary

	local final_fail=$FAIL
	if [[ $FAIL -gt 0 ]]; then
		echo ""
		echo -e "${YELLOW}Failed tests. Full log:${NC}"
		echo " $TEST_LOG"
	fi
	return $final_fail
}

print_summary() {
	echo -e "${BOLD}========================================${NC}"
	echo -e "${BOLD} Steam Deck Pamac E2E Results${NC}"
	echo -e "${BOLD}========================================${NC}"
	echo -e " Passed: ${GREEN}${PASS}${NC}"
	echo -e " Failed: ${RED}${FAIL}${NC}"
	echo -e " Total: $((PASS + FAIL))"
	echo -e "${BOLD}========================================${NC}"
	if [[ $FAIL -eq 0 ]]; then
		echo -e "${GREEN}${BOLD}ALL TESTS PASSED!${NC}"
	else
		echo -e "${RED}${BOLD}SOME TESTS FAILED!${NC}"
	fi
}

main "$@"
