#!/bin/bash
set +e
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus

echo "=== Checking what handleAppstreamActions does for pamac apps ==="
echo "Per source code, it looks up the app in AppStream pool via desktopEntryName."
echo "If not found, it returns false and does nothing."

echo ""
echo "=== Celluloid desktop entry name ==="
grep DesktopEntryName ~/.local/share/applications/arch-pamac-io.github.celluloid_player.Celluloid.desktop 2>/dev/null || \
    echo "No DesktopEntryName found"
# The desktopEntryName is derived from the filename without .desktop
echo "desktopEntryName would be: arch-pamac-io.github.celluloid_player.Celluloid"
echo "But KDE adds '.desktop' suffix when looking up in AppStream pool"
echo "AppStream lookup: componentsByLaunchable(KindDesktopId, 'arch-pamac-io.github.celluloid_player.Celluloid.desktop')"

echo ""
echo "=== Check if Celluloid is in the host AppStream pool ==="
python3 << 'PYEOF'
try:
    import gi
    gi.require_version('AppStream', '1.0')
    from gi.repository import AppStream
    pool = AppStream.Pool()
    pool.load()
    # Search by desktop ID
    results = pool.get_components_by_id("io.github.celluloid_player.Celluloid.desktop")
    if results:
        for c in results:
            print(f"Found in AppStream pool: {c.get_id()} - {c.get_name()}")
    else:
        print("NOT found in AppStream pool - handleAppstreamActions will return false (no-op)")
    
    # Also try with the arch-pamac prefix
    results2 = pool.get_components_by_id("arch-pamac-io.github.celluloid_player.Celluloid.desktop")
    if results2:
        for c in results2:
            print(f"Found (prefixed): {c.get_id()} - {c.get_name()}")
    else:
        print("NOT found (prefixed) - confirming no-op")
except Exception as e:
    print(f"AppStream check failed: {e}")
PYEOF

echo ""
echo "=== Also check pamac-manager ==="
python3 << 'PYEOF2'
try:
    import gi
    gi.require_version('AppStream', '1.0')
    from gi.repository import AppStream
    pool = AppStream.Pool()
    pool.load()
    results = pool.get_components_by_id("org.manjaro.pamac.manager.desktop")
    if results:
        for c in results:
            print(f"Found: {c.get_id()} - {c.get_name()}")
    else:
        print("NOT found in AppStream pool - no-op")
except Exception as e:
    print(f"AppStream check failed: {e}")
PYEOF2
