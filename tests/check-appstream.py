#!/usr/bin/env python3
import gi
gi.require_version('AppStream', '1.0')
from gi.repository import AppStream

pool = AppStream.Pool()
pool.load()

# Check for celluloid and pamac
for name in ["io.github.celluloid_player.Celluloid.desktop", 
             "arch-pamac-io.github.celluloid_player.Celluloid.desktop",
             "org.manjaro.pamac.manager.desktop"]:
    results = pool.get_components_by_id(name)
    count = results.get_size() if hasattr(results, 'get_size') else len(list(results)) if hasattr(results, '__iter__') else -1
    print(f"{name}: count={count}")

# List all components to see what's available
print("\nTotal components in pool:")
all_c = pool.get_components()
print(f"Total: {all_c.get_size() if hasattr(all_c, 'get_size') else 'unknown'}")

# Try the launchable-based lookup (what KDE actually uses)
print("\nTesting launchable lookup:")
pool2 = AppStream.Pool()
pool2.load()
for desktop_id in ["io.github.celluloid_player.Celluloid.desktop",
                    "arch-pamac-io.github.celluloid_player.Celluloid.desktop"]:
    try:
        results = pool2.get_components_by_launchable(AppStream.LaunchableKind.DESKTOP_ID, desktop_id)
        count = results.get_size() if hasattr(results, 'get_size') else 0
        print(f"  launchable({desktop_id}): {count} results")
    except Exception as e:
        print(f"  launchable({desktop_id}): error - {e}")
