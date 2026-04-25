#!/bin/bash
set -euo pipefail

echo "step1"
A="hello"
if [[ "$A" == "hello" ]]; then echo "matched"; fi
echo "step2"
[[ "$A" == "hello" ]] && echo "matched2"
echo "step3"
[[ "$A" == "world" ]] && echo "should not show"
echo "step4: survived all"
