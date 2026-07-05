#!/bin/bash
set +e

echo "=== Deploying Bug #33 + UI Feedback Fixes to Deck ==="
echo "Date: $(date)"

SSH_HOST="deck@192.168.2.111"
SSH_CMD="sshpass -p 'a' ssh -o StrictHostKeyChecking=no"
SCP_CMD="sshpass -p 'a' scp -o StrictHostKeyChecking=no"
CONTAINER_NAME="arch-pamac"
REMOTE_ENV="export HOME=/home/deck; export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin"

LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)/tests"
DEPLOY_LOG="/tmp/deploy-fixes-$(date +%s).log"

remote_exec() {
    $SSH_CMD "$SSH_HOST" "$REMOTE_ENV; $*" 2>&1
}

remote_check() {
    $SSH_CMD "$SSH_HOST" "$REMOTE_ENV; $*" 2>/dev/null
}

echo ""
echo "=== Step 1: Verify SSH connectivity ==="
if remote_check "echo connected" | grep -q "connected"; then
    echo "  SSH OK"
else
    echo "  FAIL: Cannot SSH to Deck"
    exit 1
fi

echo ""
echo "=== Step 2: SCP fixed files to Deck ==="
$SCP_CMD "$LOCAL_DIR/distrobox-export-hook.sh" "$SSH_HOST:/tmp/distrobox-export-hook.sh" 2>&1
echo "  SCP distrobox-export-hook.sh: $?"

$SCP_CMD "$LOCAL_DIR/steamos-pamac-uninstall" "$SSH_HOST:/tmp/steamos-pamac-uninstall" 2>&1
echo "  SCP steamos-pamac-uninstall: $?"

$SCP_CMD "$LOCAL_DIR/steamos-pamac-appstream-handler" "$SSH_HOST:/tmp/steamos-pamac-appstream-handler" 2>&1
echo "  SCP steamos-pamac-appstream-handler: $?"

$SCP_CMD "$LOCAL_DIR/steamos-pamac-kickeraction-handler" "$SSH_HOST:/tmp/steamos-pamac-kickeraction-handler" 2>&1
echo "  SCP steamos-pamac-kickeraction-handler: $?"

echo ""
echo "=== Step 3: Copy files into container ==="
remote_exec "podman cp /tmp/distrobox-export-hook.sh $CONTAINER_NAME:/usr/local/bin/distrobox-export-hook.sh && echo 'export hook OK' || echo 'export hook FAILED'"
remote_exec "podman exec -u 0 $CONTAINER_NAME chmod +x /usr/local/bin/distrobox-export-hook.sh"

echo ""
echo "=== Step 4: Deploy host-side files ==="
remote_exec "cp /tmp/steamos-pamac-uninstall /home/deck/.local/bin/steamos-pamac-uninstall && chmod +x /home/deck/.local/bin/steamos-pamac-uninstall && echo 'uninstall helper OK'"
remote_exec "cp /tmp/steamos-pamac-appstream-handler /home/deck/.local/bin/steamos-pamac-appstream-handler && chmod +x /home/deck/.local/bin/steamos-pamac-appstream-handler && echo 'appstream handler OK'"
remote_exec "cp /tmp/steamos-pamac-kickeraction-handler /home/deck/.local/bin/steamos-pamac-kickeraction-handler && chmod +x /home/deck/.local/bin/steamos-pamac-kickeraction-handler && echo 'kickeraction handler OK'"

echo ""
echo "=== Step 5: Re-run export hook to fix desktop files ==="
remote_exec "podman exec -u 0 $CONTAINER_NAME /usr/local/bin/distrobox-export-hook.sh" 2>&1 | tail -5

echo ""
echo "=== Step 6: Verify fixed desktop files ==="
echo "--- Checking Actions= keys ---"
remote_exec "for f in /home/deck/.local/share/applications/arch-pamac-*.desktop; do
    echo \"--- \$(basename \"\$f\") ---\"
    grep '^Actions=' \"\$f\" 2>/dev/null | head -1
    desktop-file-validate \"\$f\" 2>&1 | head -3
done"

echo ""
echo "=== Step 7: Refresh KDE service cache ==="
remote_exec "DISPLAY=:0 kbuildsycoca6 --noincremental 2>&1 | tail -3"

echo ""
echo "=== Step 8: Verify KDE can find apps ==="
remote_check "kioclient exec 'applications:///' 2>/dev/null | head -5" || echo "kioclient not available, checking xdg query..."
remote_check "grep -l 'X-SteamOS-Pamac-Managed=true' /home/deck/.local/share/applications/arch-pamac-*.desktop 2>/dev/null | wc -l"
echo " desktop files with pamac markers"

echo ""
echo "=== Deploy Complete ==="
echo "Next: Run E2E test to verify everything works"
echo "  ssh -t deck@192.168.2.111 'bash /tmp/steam-deck-e2e-test.sh'"
