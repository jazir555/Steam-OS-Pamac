#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
echo "Testing command substitution with </dev/null..."
result=$(timeout 10 podman exec -u 0 arch-pamac pamac search neofetch </dev/null 2>/dev/null)
echo "Got ${#result} chars"
echo "First line: $(echo "$result" | head -1)"
echo "Testing without </dev/null..."
result2=$(timeout 10 podman exec -u 0 arch-pamac pamac search neofetch 2>/dev/null)
echo "Got ${#result2} chars"
echo "First line: $(echo "$result2" | head -1)"
echo "Testing with 0<&-..."
result3=$(timeout 10 podman exec -u 0 arch-pamac pamac search neofetch 0<&- 2>/dev/null)
echo "Got ${#result3} chars"
echo "First line: $(echo "$result3" | head -1)"
