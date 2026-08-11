#!/usr/bin/env bash

set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
passed=0
failed=0

# Includes the council protocol suites: convene, record, quorum, and retry.
for test_file in "$root"/tests/test-*.sh; do
  [ -f "$test_file" ] || continue
  if bash "$test_file"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi
done

echo "Summary: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
