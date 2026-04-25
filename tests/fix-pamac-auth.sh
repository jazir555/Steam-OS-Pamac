#!/bin/bash
set -x

# Fix polkit policy to allow non-interactive auth
sed -i 's|<allow_any>auth_admin_keep</allow_any>|<allow_any>yes</allow_any>|' /usr/share/polkit-1/actions/org.manjaro.pamac.policy
sed -i 's|<allow_inactive>auth_admin_keep</allow_inactive>|<allow_inactive>yes</allow_inactive>|' /usr/share/polkit-1/actions/org.manjaro.pamac.policy
sed -i 's|<allow_active>auth_admin_keep</allow_active>|<allow_active>yes</allow_active>|' /usr/share/polkit-1/actions/org.manjaro.pamac.policy

echo "Patched polkit policy:"
grep -E 'allow_(any|inactive|active)' /usr/share/polkit-1/actions/org.manjaro.pamac.policy

# Fix pamac-session-bootstrap.sh to use full path for pamac-daemon
sed -i 's|sudo pamac-daemon|/usr/bin/pamac-daemon|g' /usr/local/bin/pamac-session-bootstrap.sh
sed -i 's|run_root pamac-daemon|/usr/bin/pamac-daemon|g' /usr/local/bin/pamac-session-bootstrap.sh

echo "Patched bootstrap script:"
grep -n 'pamac-daemon' /usr/local/bin/pamac-session-bootstrap.sh
