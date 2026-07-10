#!/usr/bin/env python3
import os, shutil, re

src = "/usr/share/applications/blender.desktop"
dst = "/home/deck/.local/share/applications/arch-pamac-blender.desktop"

if not os.path.exists(src):
    print("NO_SRC: blender not installed")
    exit(1)

shutil.copy2(src, dst)
with open(dst) as fh:
    c = fh.read()

c = re.sub(r"^Exec=.*", "Exec=distrobox-enter -n arch-pamac -- blender %f", c, count=1, flags=re.MULTILINE)

pkg = "blender"
markers = (
    "Actions=uninstall;\n"
    "X-SteamOS-Pamac-Managed=true\n"
    "X-SteamOS-Pamac-Container=arch-pamac\n"
    "X-SteamOS-Pamac-SourceDesktop=blender.desktop\n"
    f"X-SteamOS-Pamac-SourcePackage={pkg}\n"
    "\n"
    "[Desktop Action uninstall]\n"
    "Name=Remove Blender\n"
    f"Exec=bash -c 'podman exec -u 0 arch-pamac pacman -R --noconfirm {pkg} 2>/dev/null && rm -f {dst} && notify-send -i edit-delete Uninstalled \"{pkg} removed\" 2>/dev/null'\n"
    "Icon=edit-delete\n"
)

c = c.rstrip() + "\n" + markers
with open(dst, "w") as fh:
    fh.write(c)
os.chmod(dst, 0o644)
print("EXPORTED with fast uninstall")
