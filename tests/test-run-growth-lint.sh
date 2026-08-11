#!/usr/bin/env bash
# Regression tests for the scheduled growth-lint wrapper.
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
wrapper="$root/scripts/run-growth-lint.sh"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/run-growth-lint-test.XXXXXX")
failures=0
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

make_lint_stub() {
  stub=$1
  status=$2
  output=$3
  sed -e "s/@STATUS@/$status/" -e "s/@OUTPUT@/$output/" >"$stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SGL_TEST_LINT_CALLS"
printf '%s\n' '@OUTPUT@'
printf '%s\n' 'stub stderr' >&2
exit @STATUS@
EOF
  chmod +x "$stub"
}

heartbeat="$test_dir/heartbeat"
cat >"$heartbeat" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SGL_TEST_HEARTBEAT_CALLS"
EOF
chmod +x "$heartbeat"

# Success preserves status, captures output, and records an ok heartbeat.
success_dir="$test_dir/success"
mkdir -p "$success_dir/logs"
success_lint="$success_dir/lint"
make_lint_stub "$success_lint" 0 'success output'
SGL_TEST_LINT_CALLS="$success_dir/lint.calls" \
SGL_TEST_HEARTBEAT_CALLS="$success_dir/heartbeat.calls" \
SGL_VAULT="$success_dir/vault" SGL_SENSORS='mine,other' \
SGL_LINT="$success_lint" SGL_HEARTBEAT_TOOL="$heartbeat" SGL_LOG_DIR="$success_dir/logs" \
  /bin/bash "$wrapper" || fail 'success wrapper returned nonzero'
success_log=$(find "$success_dir/logs" -type f -name 'growth-lint-*.log' -print -quit)
[ -n "$success_log" ] || fail 'success log was not created'
if [ -n "$success_log" ]; then
  grep -Eq '^# run-growth-lint start [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z tz=[+-][0-9]{4}$' "$success_log" || fail 'run context was not logged'
  grep -Fq 'success output' "$success_log" || fail 'success output was not logged'
  grep -Fq 'stub stderr' "$success_log" || fail 'lint stderr was not logged'
fi
grep -Fq -- '--vault' "$success_dir/lint.calls" || fail 'vault argument was not passed to lint'
grep -Fq -- '--sensors mine,other' "$success_dir/lint.calls" || fail 'sensor argument was not passed to lint'
grep -Fq 'self-growth-lint ok' "$success_dir/heartbeat.calls" || fail 'ok heartbeat was not sent'
grep -Fq -- '--duration-ms' "$success_dir/heartbeat.calls" || fail 'heartbeat duration was not sent'

# Failure preserves the lint status and supplies a short heartbeat reason.
failure_dir="$test_dir/failure"
mkdir -p "$failure_dir/logs"
failure_lint="$failure_dir/lint"
make_lint_stub "$failure_lint" 2 'failure output'
SGL_TEST_LINT_CALLS="$failure_dir/lint.calls" \
SGL_TEST_HEARTBEAT_CALLS="$failure_dir/heartbeat.calls" \
SGL_LINT="$failure_lint" SGL_HEARTBEAT_TOOL="$heartbeat" SGL_LOG_DIR="$failure_dir/logs" \
  /bin/bash "$wrapper"
failure_status=$?
[ "$failure_status" -eq 2 ] || fail "failure wrapper returned $failure_status instead of 2"
grep -Fq 'self-growth-lint fail' "$failure_dir/heartbeat.calls" || fail 'fail heartbeat was not sent'
grep -Fq -- '--reason exit 2; see growth-lint-' "$failure_dir/heartbeat.calls" || fail 'failure heartbeat reason was not sent'

# Lock contention preserves exit 1 but records an ok heartbeat and skip note.
skip_dir="$test_dir/skip"
mkdir -p "$skip_dir/logs"
skip_lint="$skip_dir/lint"
make_lint_stub "$skip_lint" 1 'lock busy'
SGL_TEST_LINT_CALLS="$skip_dir/lint.calls" \
SGL_TEST_HEARTBEAT_CALLS="$skip_dir/heartbeat.calls" \
SGL_LINT="$skip_lint" SGL_HEARTBEAT_TOOL="$heartbeat" SGL_LOG_DIR="$skip_dir/logs" \
  /bin/bash "$wrapper" 2>"$skip_dir/stderr"
skip_status=$?
[ "$skip_status" -eq 1 ] || fail "skip wrapper returned $skip_status instead of 1"
grep -Fq 'self-growth-lint ok' "$skip_dir/heartbeat.calls" || fail 'skip did not send an ok heartbeat'
grep -Fq 'lock busy: skipped (heartbeat ok)' "$skip_dir/stderr" || fail 'skip note was not printed'

# A missing heartbeat tool warns but cannot alter the lint result.
missing_dir="$test_dir/missing"
mkdir -p "$missing_dir/logs"
missing_lint="$missing_dir/lint"
make_lint_stub "$missing_lint" 2 'missing heartbeat output'
SGL_TEST_LINT_CALLS="$missing_dir/lint.calls" \
SGL_LINT="$missing_lint" SGL_HEARTBEAT_TOOL="$missing_dir/not-there" SGL_LOG_DIR="$missing_dir/logs" \
  /bin/bash "$wrapper" 2>"$missing_dir/stderr"
missing_status=$?
[ "$missing_status" -eq 2 ] || fail "missing-heartbeat wrapper returned $missing_status instead of 2"
grep -Fq 'warning: heartbeat tool missing or not executable' "$missing_dir/stderr" || fail 'missing heartbeat warning was not printed'

# An executable heartbeat that fails also warns without changing lint success.
heartbeat_failure_dir="$test_dir/heartbeat-failure"
mkdir -p "$heartbeat_failure_dir/logs"
heartbeat_failure_lint="$heartbeat_failure_dir/lint"
make_lint_stub "$heartbeat_failure_lint" 0 'heartbeat failure output'
failing_heartbeat="$heartbeat_failure_dir/heartbeat"
cat >"$failing_heartbeat" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SGL_TEST_HEARTBEAT_CALLS"
exit 9
EOF
chmod +x "$failing_heartbeat"
SGL_TEST_LINT_CALLS="$heartbeat_failure_dir/lint.calls" \
SGL_TEST_HEARTBEAT_CALLS="$heartbeat_failure_dir/heartbeat.calls" \
SGL_LINT="$heartbeat_failure_lint" SGL_HEARTBEAT_TOOL="$failing_heartbeat" SGL_LOG_DIR="$heartbeat_failure_dir/logs" \
  /bin/bash "$wrapper" 2>"$heartbeat_failure_dir/stderr" || fail 'heartbeat failure altered lint success'
grep -Fq 'warning: heartbeat update failed' "$heartbeat_failure_dir/stderr" || fail 'heartbeat failure warning was not printed'

# Retention removes only matching old logs and keeps fresh and unrelated files.
retention_dir="$test_dir/retention"
mkdir -p "$retention_dir/logs"
retention_lint="$retention_dir/lint"
make_lint_stub "$retention_lint" 0 'retention output'
old_log="$retention_dir/logs/growth-lint-20000101-000000.log"
old_unrelated="$retention_dir/logs/unrelated.log"
nested_old_log="$retention_dir/logs/nested/growth-lint-20000101-000000.log"
mkdir -p "$retention_dir/logs/nested"
printf '%s\n' old >"$old_log"
printf '%s\n' old >"$old_unrelated"
printf '%s\n' old >"$nested_old_log"
touch -t 200001010000 "$old_log" "$old_unrelated" "$nested_old_log"
SGL_TEST_LINT_CALLS="$retention_dir/lint.calls" \
SGL_TEST_HEARTBEAT_CALLS="$retention_dir/heartbeat.calls" \
SGL_LINT="$retention_lint" SGL_HEARTBEAT_TOOL="$heartbeat" SGL_LOG_DIR="$retention_dir/logs" \
  /bin/bash "$wrapper" || fail 'retention wrapper returned nonzero'
[ ! -e "$old_log" ] || fail 'old growth-lint log was not removed'
[ -e "$old_unrelated" ] || fail 'retention removed an unrelated log'
[ -e "$nested_old_log" ] || fail 'retention removed a nested growth-lint log'
fresh_log=$(find "$retention_dir/logs" -type f -name 'growth-lint-*.log' -print -quit)
[ -n "$fresh_log" ] || fail 'fresh growth-lint log was removed'

# An unwritable logfile is an infrastructure failure and lint is not invoked.
log_setup_dir="$test_dir/log-setup"
mkdir -p "$log_setup_dir/logs"
log_setup_lint="$log_setup_dir/lint"
make_lint_stub "$log_setup_lint" 0 'must not run'
chmod 555 "$log_setup_dir/logs"
SGL_TEST_LINT_CALLS="$log_setup_dir/lint.calls" \
SGL_TEST_HEARTBEAT_CALLS="$log_setup_dir/heartbeat.calls" \
SGL_LINT="$log_setup_lint" SGL_HEARTBEAT_TOOL="$heartbeat" SGL_LOG_DIR="$log_setup_dir/logs" \
  /bin/bash "$wrapper" 2>"$log_setup_dir/stderr"
log_setup_status=$?
chmod 755 "$log_setup_dir/logs"
[ "$log_setup_status" -eq 2 ] || fail "log-setup wrapper returned $log_setup_status instead of 2"
grep -Fq 'self-growth-lint fail --reason log setup failed' "$log_setup_dir/heartbeat.calls" || fail 'log-setup fail heartbeat was not sent'
[ ! -e "$log_setup_dir/lint.calls" ] || fail 'lint ran after logfile setup failed'

# TERM is forwarded to the child process group, which is reaped before a fail heartbeat.
signal_dir="$test_dir/signal"
mkdir -p "$signal_dir/logs"
signal_lint="$signal_dir/lint"
cat >"$signal_lint" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' started >"$SGL_TEST_SIGNAL_MARKER"
sleep 3
printf '%s\n' finished >>"$SGL_TEST_SIGNAL_MARKER"
EOF
chmod +x "$signal_lint"
SGL_TEST_HEARTBEAT_CALLS="$signal_dir/heartbeat.calls" \
SGL_TEST_SIGNAL_MARKER="$signal_dir/marker" \
SGL_LINT="$signal_lint" SGL_HEARTBEAT_TOOL="$heartbeat" SGL_LOG_DIR="$signal_dir/logs" \
  /bin/bash "$wrapper" &
signal_wrapper_pid=$!
signal_attempt=0
while [ ! -e "$signal_dir/marker" ] && [ "$signal_attempt" -lt 50 ]; do
  sleep 0.1
  signal_attempt=$((signal_attempt + 1))
done
if [ ! -e "$signal_dir/marker" ]; then
  fail 'signal child did not start'
  kill -TERM "$signal_wrapper_pid" 2>/dev/null || :
else
  kill -TERM "$signal_wrapper_pid" 2>/dev/null || fail 'could not signal wrapper'
fi
wait "$signal_wrapper_pid"
signal_status=$?
[ "$signal_status" -eq 143 ] || fail "signal wrapper returned $signal_status instead of 143"
grep -Fq 'self-growth-lint fail' "$signal_dir/heartbeat.calls" || fail 'signal did not send a fail heartbeat'
grep -Fq -- '--reason signal TERM;' "$signal_dir/heartbeat.calls" || fail 'signal heartbeat reason was not sent'
grep -Fq 'finished' "$signal_dir/marker" && fail 'signal child was not terminated'

# HOME is mandatory even when paths are overridden; a clean environment works once HOME is supplied.
home_dir="$test_dir/home"
mkdir -p "$home_dir/logs" "$home_dir/home"
home_lint="$home_dir/lint"
make_lint_stub "$home_lint" 0 'home output'
env -i SGL_VAULT="$home_dir/vault" SGL_LINT="$home_lint" \
  SGL_HEARTBEAT_TOOL="$heartbeat" SGL_LOG_DIR="$home_dir/logs" \
  /bin/bash "$wrapper" 2>"$home_dir/missing-home.stderr"
missing_home_status=$?
[ "$missing_home_status" -eq 2 ] || fail "missing-HOME wrapper returned $missing_home_status instead of 2"
grep -Fq 'run-growth-lint.sh: HOME must be set' "$home_dir/missing-home.stderr" || fail 'missing-HOME message was not printed'

env -i HOME="$home_dir/home" SGL_TEST_LINT_CALLS="$home_dir/lint.calls" \
  SGL_TEST_HEARTBEAT_CALLS="$home_dir/heartbeat.calls" \
  SGL_VAULT="$home_dir/vault" SGL_LINT="$home_lint" \
  SGL_HEARTBEAT_TOOL="$heartbeat" SGL_LOG_DIR="$home_dir/logs" \
  /bin/bash "$wrapper"
home_status=$?
[ "$home_status" -eq 0 ] || fail "clean-environment wrapper returned $home_status instead of 0"
grep -Fq 'self-growth-lint ok' "$home_dir/heartbeat.calls" || fail 'clean-environment run did not send an ok heartbeat'

if [ "$failures" -ne 0 ]; then exit 1; fi
echo 'PASS: test-run-growth-lint'
