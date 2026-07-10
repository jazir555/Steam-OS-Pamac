#!/usr/bin/env python3
"""Patch alpm_utils.vala with debug logging in trans_prepare_real."""
import sys
import os

VALA_FILE = sys.argv[1]

with open(VALA_FILE, 'r') as f:
    content = f.read()

lines = content.split('\n')

# Patch 1: In trans_prepare_real, after "Alpm.Errno err_no = alpm_handle.errno ();"
# Add debug logging that writes to /tmp/pamac-debug-trans.log
# and also iterates syncdbs to log their names and siglevels
debug_block_after_errno = """				// === PAMAC DEBUG PATCH ===
				try {
					var dbg_f = GLib.File.new_for_path("/tmp/pamac-debug-trans.log");
					var dbg_ios = dbg_f.append_to(GLib.FileCreateFlags.NONE);
					var dbg_out = new GLib.DataOutputStream(dbg_ios);
					dbg_out.put_string("=== trans_prepare_real FAILED ===\\n");
					dbg_out.put_string("err_no = %d (%s)\\n".printf((int) err_no, Alpm.strerror(err_no)));
					dbg_out.put_string("defaultsiglevel = %d\\n".printf((int) alpm_handle.defaultsiglevel));
					dbg_out.put_string("localfilesiglevel = %d\\n".printf((int) alpm_handle.localfilesiglevel));
					dbg_out.put_string("remotefilesiglevel = %d\\n".printf((int) alpm_handle.remotefilesiglevel));
					dbg_out.put_string("Registered syncdbs:\\n");
					unowned Alpm.List<unowned Alpm.DB> dbs = alpm_handle.syncdbs;
					int db_idx = 0;
					while (dbs != null) {
						unowned Alpm.DB db = dbs.data;
						dbg_out.put_string("  [%d] name=%s, siglevel=%d\\n".printf(db_idx, db.name, (int) db.siglevel));
						db_idx++;
						dbs.next();
					}
					dbg_out.put_string("=== END DEBUG ===\\n");
				} catch (Error e) {
					stderr.printf("PAMAC_DEBUG_LOG_ERROR: %s\\n", e.message);
				}"""

# Patch 2: In trans_check_prepare, before "bool success = trans_prepare(tmp_handle, aur_db);"
# Add debug logging about the tmp_handle syncdbs
debug_block_before_check = """			// === PAMAC DEBUG PATCH ===
			try {
				var dbg_f2 = GLib.File.new_for_path("/tmp/pamac-debug-trans.log");
				var dbg_ios2 = dbg_f2.append_to(GLib.FileCreateFlags.NONE);
				var dbg_out2 = new GLib.DataOutputStream(dbg_ios2);
				dbg_out2.put_string("=== trans_check_prepare BEFORE trans_prepare ===\\n");
				dbg_out2.put_string("tmp_handle.defaultsiglevel = %d\\n".printf((int) tmp_handle.defaultsiglevel));
				dbg_out2.put_string("tmp_handle.localfilesiglevel = %d\\n".printf((int) tmp_handle.localfilesiglevel));
				dbg_out2.put_string("tmp_handle.remotefilesiglevel = %d\\n".printf((int) tmp_handle.remotefilesiglevel));
				dbg_out2.put_string("tmp_handle dbs:\\n");
				unowned Alpm.List<unowned Alpm.DB> dbs2 = tmp_handle.syncdbs;
				int db_idx2 = 0;
				while (dbs2 != null) {
					unowned Alpm.DB db2 = dbs2.data;
					dbg_out2.put_string("  [%d] name=%s, siglevel=%d\\n".printf(db_idx2, db2.name, (int) db2.siglevel));
					db_idx2++;
					dbs2.next();
				}
				dbg_out2.put_string("to_install: ");
				foreach (unowned string n in to_install) {
					dbg_out2.put_string("%s ".printf(n));
				}
				dbg_out2.put_string("\\nto_remove: ");
				foreach (unowned string n in to_remove) {
					dbg_out2.put_string("%s ".printf(n));
				}
				dbg_out2.put_string("\\nto_build: ");
				foreach (unowned string n in to_build) {
					dbg_out2.put_string("%s ".printf(n));
				}
				dbg_out2.put_string("\\nremote_paths: ");
				foreach (unowned string n in remote_paths) {
					dbg_out2.put_string("%s ".printf(n));
				}
				dbg_out2.put_string("\\nlocal_paths: ");
				foreach (unowned string n in local_paths) {
					dbg_out2.put_string("%s ".printf(n));
				}
				dbg_out2.put_string("\\n=== END DEBUG ===\\n");
			} catch (Error e) {
				stderr.printf("PAMAC_DEBUG_LOG_ERROR: %s\\n", e.message);
			}"""

# Patch 3: In trans_run, before "bool success = trans_prepare_real(alpm_handle);"
# Add debug logging for the daemon's real handle

patched = 0
new_lines = []
for i, line in enumerate(lines):
    new_lines.append(line)

# Apply patches
output = '\n'.join(new_lines)

# Patch 1: Add debug block after "Alpm.Errno err_no = alpm_handle.errno ();" in trans_prepare_real
old1 = "\t\t\t\tAlpm.Errno err_no = alpm_handle.errno ();\n\t\t\t\tswitch (err_no) {"
new1 = "\t\t\t\tAlpm.Errno err_no = alpm_handle.errno ();\n" + debug_block_after_errno + "\n\t\t\t\tswitch (err_no) {"
if old1 in output:
    output = output.replace(old1, new1, 1)
    patched += 1
    print("Patch 1 applied: debug logging after err_no in trans_prepare_real")
else:
    print("WARNING: Patch 1 target not found!")

# Patch 2: Add debug block before "bool success = trans_prepare (tmp_handle, aur_db);" in trans_check_prepare
old2 = "\t\tbool success = trans_prepare (tmp_handle, aur_db);"
new2 = debug_block_before_check + "\n\t\tbool success = trans_prepare (tmp_handle, aur_db);"
# Find this specific occurrence in trans_check_prepare context
if old2 in output:
    output = output.replace(old2, new2, 1)
    patched += 1
    print("Patch 2 applied: debug logging before trans_prepare in trans_check_prepare")
else:
    print("WARNING: Patch 2 target not found!")

with open(VALA_FILE, 'w') as f:
    f.write(output)

print(f"\nTotal patches applied: {patched}")
print(f"File: {VALA_FILE}")
