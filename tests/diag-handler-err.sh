#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Check handler logs ==="
echo "--- kickeraction handler log ---"
cat ~/.local/share/steamos-pamac/arch-pamac/kickeraction-handler.log 2>&1 | tail -20
echo ""
echo "--- appstream handler log ---"
cat ~/.local/share/steamos-pamac/arch-pamac/appstream-handler.log 2>&1 | tail -20
echo ""
echo "--- uninstall helper log ---"
cat ~/.local/share/steamos-pamac/arch-pamac/uninstall-helper.log 2>&1 | tail -20
echo ""
echo "--- kickeraction uninstall logs ---"
ls -la ~/.local/share/steamos-pamac/arch-pamac/kickeraction-uninstall-*.log 2>&1
for f in ~/.local/share/steamos-pamac/arch-pamac/kickeraction-uninstall-*.log; do
    [[ -f "$f" ]] && echo "--- $f ---" && tail -20 "$f"
done
echo ""
echo "=== Check handler permissions ==="
ls -la ~/.local/bin/steamos-pamac-kickeraction-handler 2>&1
ls -la ~/.local/bin/steamos-pamac-appstream-handler 2>&1
ls -la ~/.local/bin/steamos-pamac-uninstall 2>&1
echo ""
echo "=== Check if handlers are executable ==="
file ~/.local/bin/steamos-pamac-kickeraction-handler 2>&1
file ~/.local/bin/steamos-pamac-appstream-handler 2>&1
