#!/bin/bash
grep -n "desktop" /usr/sbin/distrobox-export 2>/dev/null | head -30
