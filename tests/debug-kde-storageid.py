#!/usr/bin/env python3
import dbus
import os
import glob

try:
    bus = dbus.SessionBus()
    proxy = bus.get_object('org.kde.kded6', '/modules/ksycoca')
    ksycoca = dbus.Interface(proxy, 'org.kde.KSycoca')
    print("KSycoca via dbus not directly queryable this way")
except Exception as e:
    print(f"DBus approach failed: {e}")

app_dir = os.path.expanduser("~/.local/share/applications")
for f in sorted(glob.glob(os.path.join(app_dir, "arch-pamac-*.desktop"))):
    basename = os.path.basename(f)
    storage_id = basename
    if storage_id.endswith('.desktop'):
        storage_id = storage_id[:-8]
    
    desktop_entry_name = ""
    with open(f, 'r') as fh:
        for line in fh:
            if line.startswith('DesktopEntryName='):
                desktop_entry_name = line.strip().split('=', 1)[1]
                break
    
    name = ""
    with open(f, 'r') as fh:
        for line in fh:
            if line.startswith('Name='):
                name = line.strip().split('=', 1)[1]
                break

    print(f"File: {basename}")
    print(f"  storageId (no .desktop): {storage_id}")
    print(f"  desktopEntryName: {desktop_entry_name or '(not set - derived from filename)'}")
    print(f"  Name: {name}")
    print()

print("\n=== Checking kickeraction X-KDE-OnlyForAppIds ===")
kickeraction_file = os.path.expanduser("~/.local/share/plasma/kickeractions/steamos-pamac-uninstall.desktop")
if os.path.exists(kickeraction_file):
    with open(kickeraction_file, 'r') as fh:
        for line in fh:
            if line.startswith('X-KDE-OnlyForAppIds='):
                ids = line.strip().split('=', 1)[1].split(',')
                print(f"Configured IDs: {ids}")
                print()
                for app_file in sorted(glob.glob(os.path.join(app_dir, "arch-pamac-*.desktop"))):
                    app_basename = os.path.basename(app_file)
                    app_storage_id = app_basename[:-8] if app_basename.endswith('.desktop') else app_basename
                    if app_storage_id in ids:
                        print(f"  MATCH: {app_storage_id} -> {app_basename}")
                    else:
                        print(f"  NO MATCH: {app_storage_id} not in kickeraction IDs")
