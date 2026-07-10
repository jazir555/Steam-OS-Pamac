#!/usr/bin/env python3
import os, re

desktop_dir = "/home/deck/.local/share/applications"

for fname in os.listdir(desktop_dir):
    if not fname.startswith("arch-pamac-") or not fname.endswith(".desktop"):
        continue
    fpath = os.path.join(desktop_dir, fname)
    with open(fpath) as fh:
        content = fh.read()
    
    pkg_name = fname.replace("arch-pamac-", "").replace(".desktop", "")
    
    old_pattern = r"Exec=[^\n]*steamos-pamac-uninstall[^\n]*"
    new_exec = (
        "Exec=bash -c 'podman exec -u 0 arch-pamac pacman -R --noconfirm " + pkg_name + " 2>/dev/null && "
        "rm -f " + fpath + " && "
        "notify-send -i edit-delete \"Uninstalled\" \"" + pkg_name + " removed\" 2>/dev/null'"
    )
    
    if re.search(old_pattern, content):
        content = re.sub(old_pattern, new_exec, content)
        with open(fpath, "w") as fh:
            fh.write(content)
        print(f"OPTIMIZED: {fname}")
    else:
        print(f"SKIPPED: {fname}")
