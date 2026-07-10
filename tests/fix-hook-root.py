#!/usr/bin/env python3
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = '''if [[ "$(id -u)" == "0" ]]; then
    exit 0
fi'''
new = '''if [[ "$(id -u)" == "0" ]]; then
    su -s /bin/bash deck -c "$0" 2>/dev/null || true
    exit 0
fi'''

if old in content:
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print('FIXED')
else:
    print('PATTERN_NOT_FOUND')
    print(content[:500])
