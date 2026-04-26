#!/bin/bash
set -uo pipefail

echo "=== Desktop files in /usr/share/applications ==="
for desktop in /usr/share/applications/*.desktop; do
  [[ -f "$desktop" ]] || continue
  app_name="$(basename "$desktop" .desktop)"
  owner_pkg="$(pacman -Qoq "$desktop" 2>/dev/null || true)"
  is_explicit="no"
  if [[ -n "$owner_pkg" ]]; then
    if pacman -Qeq 2>/dev/null | grep -Fxq "$owner_pkg"; then
      is_explicit="yes"
    fi
  fi
  no_display=""
  grep -qi '^NoDisplay=true' "$desktop" && no_display="NoDisplay"
  grep -qi '^Hidden=true' "$desktop" && no_display="$no_display Hidden"
  grep -qi '^TerminalOnly=true' "$desktop" && no_display="$no_display TerminalOnly"
  type_line="$(grep -i '^Type=' "$desktop" 2>/dev/null | head -1)"
  echo "$app_name | owner=$owner_pkg | explicit=$is_explicit | $no_display | $type_line"
done
echo "=== DONE ==="
