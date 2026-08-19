#!/usr/bin/env bash
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-ruby-preflight.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() { echo "test-ruby-preflight.sh: $*" >&2; exit 1; }

rubyless_bin="$tmp/bin"
mkdir -p "$rubyless_bin" || fail 'could not create ruby-less bin directory'

# Resolve the few tools needed to recreate the old council failure dynamically.
# This keeps Ruby absent without assuming platform-specific installation paths.
for tool in bash sh dirname grep; do
  tool_path=$(command -v "$tool") || fail "$tool not found on the normal PATH"
  ln -s "$tool_path" "$rubyless_bin/$tool" || fail "could not link $tool"
done

run_missing_ruby_case() {
  name=$1
  script=$2
  shift 2
  stdout="$tmp/$name.out"
  stderr="$tmp/$name.err"
  status=0
  if env PATH="$rubyless_bin" bash "$script" "$@" >"$stdout" 2>"$stderr"; then
    fail "$name unexpectedly succeeded without ruby"
  else
    status=$?
  fi
  [ "$status" -eq 127 ] || fail "$name exited $status instead of 127"
  grep -Fq 'ruby not found' "$stderr" || fail "$name did not report the missing ruby dependency"
}

run_missing_ruby_case adopt "$root/scripts/adopt-watch.sh" --help
run_missing_ruby_case council "$root/scripts/council-quorum.sh" \
  --vault "$tmp/vault" --topic tool__vendor --workspace "$tmp" --now 2026-07-21T12:00:00Z
run_missing_ruby_case trial "$root/scripts/trial-enqueue.sh" --help

if grep -Fq -- '--now must be ISO8601Z' "$tmp/council.err"; then
  fail 'council-quorum retained the old misleading timestamp error'
fi

echo "test-ruby-preflight.sh: PASS"
