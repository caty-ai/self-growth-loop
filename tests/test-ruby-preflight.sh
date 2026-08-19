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

# Every non-wrapper shell entrypoint must fail uniformly before argument parsing.
entry_scripts='adopt-abort.sh
adopt-approve.sh
adopt-complete.sh
adopt-confirm.sh
adopt-reconcile.sh
adopt-reject.sh
adopt-rollback-done.sh
adopt-watch.sh
council-convene.sh
council-quorum.sh
council-record.sh
growth-lint.sh
propose.sh
trial-enqueue.sh
trial-poll.sh'
for script_name in $entry_scripts; do
  case_name=${script_name%.sh}
  run_missing_ruby_case "$case_name" "$root/scripts/$script_name" --help
done

# Keep the richer council invocation that originally reproduced a misleading
# argument error before the dependency failure.
run_missing_ruby_case council-args "$root/scripts/council-quorum.sh" \
  --vault "$tmp/vault" --topic tool__vendor --workspace "$tmp" --now 2026-07-21T12:00:00Z
if grep -Fq -- '--now must be ISO8601Z' "$tmp/council-args.err"; then
  fail 'council-quorum retained the old misleading timestamp error'
fi

# The wrapper intentionally provisions launchd's PATH before checking for Ruby.
provisioned_path=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin
wrapper_dir="$tmp/run-growth-lint"
wrapper_home="$wrapper_dir/home"
wrapper_logs="$wrapper_dir/logs"
wrapper_lint="$wrapper_dir/lint"
wrapper_heartbeat="$wrapper_dir/heartbeat"
wrapper_calls="$wrapper_dir/lint.calls"
mkdir -p "$wrapper_home" "$wrapper_logs" || fail 'could not create wrapper test directories'

sed "s|@CALLS@|$wrapper_calls|" >"$wrapper_lint" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> '@CALLS@'
exit 0
EOF
chmod +x "$wrapper_lint" || fail 'could not make lint stub executable'

sed "s|@CALLS@|$wrapper_dir/heartbeat.calls|" >"$wrapper_heartbeat" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> '@CALLS@'
exit 0
EOF
chmod +x "$wrapper_heartbeat" || fail 'could not make heartbeat stub executable'

wrapper_stdout="$wrapper_dir/stdout"
wrapper_stderr="$wrapper_dir/stderr"
wrapper_status=0
if env PATH="$rubyless_bin" HOME="$wrapper_home" \
  SGL_LINT="$wrapper_lint" SGL_LOG_DIR="$wrapper_logs" \
  SGL_VAULT="$wrapper_dir/vault" SGL_HEARTBEAT_TOOL="$wrapper_heartbeat" \
  bash "$root/scripts/run-growth-lint.sh" >"$wrapper_stdout" 2>"$wrapper_stderr"; then
  wrapper_status=0
else
  wrapper_status=$?
fi

if PATH="$provisioned_path" command -v ruby >/dev/null 2>&1; then
  # Ruby is on the wrapper's provisioned PATH: a ruby-less incoming PATH must proceed.
  [ "$wrapper_status" -ne 127 ] || fail 'wrapper used the incoming PATH and exited 127'
  if grep -Fq 'run-growth-lint.sh: ruby not found' "$wrapper_stderr"; then
    fail 'wrapper reported its own missing-ruby error despite provisioned Ruby'
  fi
  [ -e "$wrapper_calls" ] || fail 'wrapper did not run the stub child with provisioned Ruby'
else
  # Ruby is absent even after provisioning: exit 127 and the named error are honest.
  [ "$wrapper_status" -eq 127 ] || fail "wrapper exited $wrapper_status instead of 127 without provisioned Ruby"
  grep -Fq 'run-growth-lint.sh: ruby not found' "$wrapper_stderr" || \
    fail 'wrapper did not report its named missing-ruby error'
  [ ! -e "$wrapper_calls" ] || fail 'wrapper ran the stub child without provisioned Ruby'
fi

echo "test-ruby-preflight.sh: PASS"
