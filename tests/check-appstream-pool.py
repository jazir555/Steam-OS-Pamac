#!/usr/bin/env python3
import gi
gi.require_version('AppStream', '1.0')
from gi.repository import AppStream

pool = AppStream.Pool()
pool.load()

# ComponentBox has a fetch method or we need to convert it
# Try using the length and index
for search_term in ['celluloid', 'pamac', 'io.github.celluloid_player', 'org.manjaro.pamac']:
    results = pool.get_components_by_launchable(AppStream.LaunchableKind.DESKTOP_ID, search_term)
    # ComponentBox is not iterable, try dir() to find methods
    if not hasattr(results, '__len__'):
        # Try tolist or similar
        try:
            rlist = results.tolist()
        except:
            rlist = []
    else:
        count = len(results)
        rlist = [results[i] for i in range(count)]
    
    if rlist:
        for c in rlist:
            print(f"Launchable match for '{search_term}': id={c.get_id()} name={c.get_name()}")
    else:
        print(f"No launchable match for '{search_term}'")
