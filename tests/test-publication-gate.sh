#!/usr/bin/env bash
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
checker="$root/tools/check_publication_gate.py"

fail() { echo "test-publication-gate.sh: $*" >&2; exit 1; }

python3 -B "$checker" --selftest || fail 'self-test failed'
outer=$(mktemp -d "${TMPDIR:-/tmp}/pubgate-outer.XXXXXX") || fail 'mktemp failed'
trap 'rm -rf "$outer"' EXIT
trap 'exit 130' HUP INT TERM
git -c init.defaultBranch=main init -q "$outer" || fail 'outer git init failed'
printf 'work/\n' > "$outer/.gitignore" || fail 'outer gitignore failed'
mkdir -p "$outer/work" || fail 'nested directory failed'
cp "$checker" "$outer/work/check_publication_gate.py" || fail 'checker copy failed'
TMPDIR="$outer/work" python3 -B "$outer/work/check_publication_gate.py" --selftest || fail 'nested self-test failed'
python3 -B "$checker" --root "$root" --account-slug shojikumaru || fail 'repository gate failed'

echo 'PASS: test-publication-gate'
