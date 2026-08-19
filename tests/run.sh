#!/usr/bin/env bash

set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-run.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
passed=0
failed=0
skipped=0
declared=0

# Includes the council protocol suites: convene, record, quorum, and retry.
for test_file in "$root"/tests/test-*.sh; do
  [ -f "$test_file" ] || continue
  declared=$((declared + 1))
  output="$tmp/output"
  status=0
  bash "$test_file" >"$output" 2>&1 || status=$?
  cat "$output"

  if [ "$status" -eq 3 ]; then
    skipped=$((skipped + 1))
  elif [ "$status" -ne 0 ]; then
    # A real failure wins over incidental SKIP-looking diagnostic text.
    failed=$((failed + 1))
  elif grep -q '^SKIP:' "$output"; then
    skipped=$((skipped + 1))
  else
    passed=$((passed + 1))
  fi
done

executed=$((passed + failed))
echo "Summary: $passed passed, $failed failed, $skipped skipped"
echo "declared=$declared executed=$executed skipped=$skipped"
[ "$failed" -eq 0 ]
