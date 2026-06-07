#!/bin/bash
export HOME=/home/deck
export PATH=/home/deck/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin

echo "=== Testing endeavouros mirrors (using x86_64) ==="
for try_mirror in \
  "mirror.jingk.ai/endeavouros/repo" \
  "mirror.alpix.eu/endeavouros/repo" \
  "mirror.freedif.org/EndeavourOS/repo/endeavouros" \
  "ca.gate.endeavouros.com/endeavouros/repo"; do
  printf "Trying: %-55s " "$try_mirror"
  result=$(podman exec arch-pamac curl -sI --max-time 10 "https://${try_mirror}/x86_64/endeavouros.db" 2>/dev/null | head -1)
  echo "$result"
done

echo ""
echo "=== also try albony with http ==="
podman exec arch-pamac curl -sI --max-time 10 "http://mirror.albony.xyz/endeavouros/repo/x86_64/endeavouros.db" 2>/dev/null | head -3

echo ""
echo "DONE"