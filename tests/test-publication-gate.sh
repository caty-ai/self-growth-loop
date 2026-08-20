#!/usr/bin/env bash
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
checker="$root/tools/check_publication_gate.py"

fail() { echo "test-publication-gate.sh: $*" >&2; exit 1; }

python3 -B "$checker" --selftest || fail 'self-test failed'
python3 -B "$checker" --root "$root" --account-slug shojikumaru || fail 'repository gate failed'

echo 'PASS: test-publication-gate'
