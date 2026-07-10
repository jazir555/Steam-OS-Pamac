#!/usr/bin/env python3
import os, sys

desktop_dir = "/home/deck/.local/share/applications"

for fname in os.listdir(desktop_dir):
    if not fname.startswith("arch-pamac-") or not fname.endswith(".desktop"):
        continue
    fpath = os.path.join(desktop_dir, fname)
    with open(fpath) as fh:
        content = fh.read()
    
    # Find the package name from the filename
    pkg_name = fname.replace("arch-pamac-", "").replace(".desktop", "")
    
    # Replace the uninstall Exec with a fast direct command
    # Pattern: Exec=...steamos-pamac-uninstall...
    import re
    old_pattern = r'Exec=[^\n]*steamos-pamac-uninstall[^\n]*'
    new_exec = (
        f"Exec=bash -c 'podman exec -u 0 arch-pamac bash -c \"'
        f'rm -f /var/lib/pacman/db.lck; pacman -R --noconfirm {pkg_name}\" 2>/dev/null '
        f'&& rm -f {fpath} '
        f'&& notify-send -i edit-delete \"Uninstalled\" \"{pkg_name} has been removed\" 2>/dev/null "
        f'|| notify-send -i dialog-error "Failed" "Could not remove {pkg_name}" 2>/dev/null\''
    )
    
    if re.search(old_pattern, content):
        content = re.sub(old_pattern, new_exec, content)
        with open(fpath, "w") as fh:
            fh.write(content)
        print(f"OPTIMIZED: {fname}")
    else:
        print(f"SKIPPED (no uninstall exec): {fname}")
