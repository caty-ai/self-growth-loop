#!/usr/bin/env bash
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
poll="$root/scripts/trial-poll.sh"
lint="$root/scripts/growth-lint.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-stale-lock-mtime.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() { echo "test-stale-lock-mtime.sh: $*" >&2; exit 1; }

real_ruby=$(command -v ruby) || fail 'ruby not found'
shim_bin="$tmp/bin"
mkdir -p "$shim_bin" || fail 'could not create shim directory'

cat >"$shim_bin/ruby" <<'EOF'
#!/bin/sh
if [ "$#" -ge 2 ] && [ "$1" = '-e' ] && [ "$2" = 'print File.mtime(ARGV.fetch(0)).to_i' ]; then
  printf '%s\n' "${TEST_FILE_MTIME_MODE:-delegate}" >>"${TEST_FILE_MTIME_CALLS:?}"
  case "${TEST_FILE_MTIME_MODE:-delegate}" in
    fail) exit 1 ;;
    empty) exit 0 ;;
    nonnumeric) printf '%s\n' 'not-an-epoch'; exit 0 ;;
  esac
fi
exec "${REAL_RUBY:?}" "$@"
EOF
cat >"$shim_bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$shim_bin/ruby" "$shim_bin/sleep" || fail 'could not make shims executable'

assert_no_stale_break() {
  lock=$1
  stdout=$2
  stderr=$3
  [ -d "$lock" ] || fail "uncomputable mtime removed lock: $lock"
  if grep -Fq 'STALE_LOCK_BROKEN' "$stdout" || grep -Fq 'STALE_LOCK_BROKEN' "$stderr"; then
    fail "uncomputable mtime reported a stale break: $lock"
  fi
  if ls "$lock".stale.* >/dev/null 2>&1 || ls "$lock".quarantine.* >/dev/null 2>&1; then
    fail "uncomputable mtime left a stale-lock quarantine: $lock"
  fi
}

assert_mtime_retry_count() {
  calls=$1
  expected=$2
  [ -f "$calls" ] || fail "file_mtime shim was not invoked: $calls"
  actual=$(wc -l <"$calls" | tr -d ' ')
  [ "$actual" -eq "$expected" ] || fail "file_mtime shim ran $actual times instead of $expected"
}

run_poll_uncomputable() {
  mode=$1
  case_root="$tmp/poll-$mode"
  vault="$case_root/vault"
  workspace="$case_root/workspace"
  lock="$vault/45_ai-systems/self-growth/proposals/.lock"
  calls="$case_root/mtime.calls"
  stdout="$case_root/stdout"
  stderr="$case_root/stderr"
  mkdir -p "$lock" "$workspace" || fail "could not create poll $mode fixture"
  touch -t 202001010000 "$lock" || fail "could not age poll $mode lock"

  status=0
  if env PATH="$shim_bin:$PATH" REAL_RUBY="$real_ruby" \
    TEST_FILE_MTIME_MODE="$mode" TEST_FILE_MTIME_CALLS="$calls" \
    "$poll" --vault "$vault" --workspace "$workspace" >"$stdout" 2>"$stderr"; then
    fail "trial-poll unexpectedly acquired a lock with $mode mtime"
  else
    status=$?
  fi

  [ "$status" -eq 2 ] || fail "trial-poll $mode mtime exited $status instead of 2"
  grep -Fq "trial-poll.sh: lock busy after 10 retries: $lock" "$stderr" || \
    fail "trial-poll $mode mtime missed retry-exhaustion diagnostic"
  assert_no_stale_break "$lock" "$stdout" "$stderr"
  assert_mtime_retry_count "$calls" 10
}

run_lint_uncomputable() {
  mode=$1
  case_root="$tmp/lib-adopt-$mode"
  vault="$case_root/vault"
  lock="$vault/45_ai-systems/self-growth/proposals/.lock"
  calls="$case_root/mtime.calls"
  stdout="$case_root/stdout"
  stderr="$case_root/stderr"
  mkdir -p "$lock" || fail "could not create lib-adopt $mode fixture"
  touch -t 202001010000 "$lock" || fail "could not age lib-adopt $mode lock"

  status=0
  if env PATH="$shim_bin:$PATH" REAL_RUBY="$real_ruby" \
    TEST_FILE_MTIME_MODE="$mode" TEST_FILE_MTIME_CALLS="$calls" \
    "$lint" --vault "$vault" --now 2026-08-01T00:00:00Z >"$stdout" 2>"$stderr"; then
    fail "lib-adopt unexpectedly acquired a lock with $mode mtime"
  else
    status=$?
  fi

  [ "$status" -eq 1 ] || fail "lib-adopt $mode mtime exited $status instead of 1"
  grep -Fq "growth-lint.sh: lock busy; skipped without writes: $lock" "$stderr" || \
    fail "lib-adopt $mode mtime missed busy diagnostic"
  assert_no_stale_break "$lock" "$stdout" "$stderr"
  assert_mtime_retry_count "$calls" 10
}

for mode in fail empty nonnumeric; do
  run_poll_uncomputable "$mode"
  run_lint_uncomputable "$mode"
done

# A real numeric mtime still permits the existing ownerless stale-lock recovery.
poll_case="$tmp/poll-stale"
poll_vault="$poll_case/vault"
poll_workspace="$poll_case/workspace"
poll_lock="$poll_vault/45_ai-systems/self-growth/proposals/.lock"
mkdir -p "$poll_lock" "$poll_workspace" || fail 'could not create stale poll fixture'
touch -t 202001010000 "$poll_lock" || fail 'could not age stale poll lock'
env PATH="$shim_bin:$PATH" REAL_RUBY="$real_ruby" \
  TEST_FILE_MTIME_MODE=delegate TEST_FILE_MTIME_CALLS="$poll_case/mtime.calls" \
  "$poll" --vault "$poll_vault" --workspace "$poll_workspace" \
  >"$poll_case/stdout" 2>"$poll_case/stderr" || fail 'trial-poll did not recover a numeric stale lock'
grep -Fq "STALE_LOCK_BROKEN $poll_lock" "$poll_case/stdout" || fail 'trial-poll stale-break output changed'
[ ! -e "$poll_lock" ] || fail 'trial-poll numeric stale lock remained'
assert_mtime_retry_count "$poll_case/mtime.calls" 1

lint_case="$tmp/lib-adopt-stale"
lint_vault="$lint_case/vault"
lint_lock="$lint_vault/45_ai-systems/self-growth/proposals/.lock"
mkdir -p "$lint_lock" || fail 'could not create stale lib-adopt fixture'
touch -t 202001010000 "$lint_lock" || fail 'could not age stale lib-adopt lock'
env PATH="$shim_bin:$PATH" REAL_RUBY="$real_ruby" \
  TEST_FILE_MTIME_MODE=delegate TEST_FILE_MTIME_CALLS="$lint_case/mtime.calls" \
  "$lint" --vault "$lint_vault" --now 2026-08-01T00:00:00Z \
  >"$lint_case/stdout" 2>"$lint_case/stderr" || fail 'lib-adopt did not recover a numeric stale lock'
grep -Fq "STALE_LOCK_BROKEN (ownerless) $lint_lock" "$lint_case/stdout" || fail 'lib-adopt stale-break output changed'
[ ! -e "$lint_lock" ] || fail 'lib-adopt numeric stale lock remained'
assert_mtime_retry_count "$lint_case/mtime.calls" 1

echo 'test-stale-lock-mtime.sh: PASS'
