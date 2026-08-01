#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
output="$(SANDBOX_SETUP_TEST_MODE=1 bash "$root/guest/ubuntu/setup.sh")"
[[ "$output" == *"no system changes made"* ]]
grep -q '^Exec=sh -c' "$root/guest/ubuntu/Install Sandbox Tools.desktop"
[[ -x "$root/guest/ubuntu/Install Sandbox Tools.desktop" ]]
grep -q 'Never put real passwords' "$root/guest/ubuntu/README.txt"
printf 'guest setup tests passed\n'
