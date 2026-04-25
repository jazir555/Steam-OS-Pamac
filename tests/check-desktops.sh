#!/bin/bash
for desk in /usr/share/applications/*.desktop; do
  pkg=$(pacman -Qoq "$desk" 2>/dev/null)
  if [ -n "$pkg" ] && pacman -Qeq 2>/dev/null | grep -Fxq "$pkg"; then
    echo "$desk -> $pkg (explicit)"
  fi
done
