#!/usr/bin/env bash
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
runner="$root/scripts/run-trial-poll.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-run-trial-poll.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() { echo "test-run-trial-poll.sh: $*" >&2; exit 1; }

recorder="$tmp/record-poll-argv.sh"
cat >"$recorder" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" >"$RECORDER_OUTPUT"
exit "${POLL_STATUS:-0}"
EOF
chmod +x "$recorder"

assert_workspace() {
  recorded=$1
  expected=$2

  [ -s "$recorded" ] || fail "poll recorder was not called"
  workspace_count=$(grep -c '^--workspace$' "$recorded")
  [ "$workspace_count" -eq 1 ] || fail "expected one --workspace argument, got $workspace_count"
  actual=$(awk '$0 == "--workspace" { getline; print; found=1; exit } END { if (!found) exit 1 }' "$recorded") ||
    fail "--workspace value was not recorded"
  [ "$actual" = "$expected" ] || fail "expected workspace $expected, got $actual"
}

default_case="$tmp/default"
mkdir -p "$default_case/home" "$default_case/vault" "$default_case/logs"
(
  unset SGL_ENGINE_WORKSPACE
  HOME="$default_case/home" \
    SGL_TRIAL_POLL="$recorder" \
    RECORDER_OUTPUT="$default_case/argv" \
    SGL_LOG_DIR="$default_case/logs" \
    SGL_HEARTBEAT_TOOL=/nonexistent \
    SGL_VAULT="$default_case/vault" \
    "$runner"
) || fail "default workspace invocation failed"
assert_workspace "$default_case/argv" "$default_case/home/claude-workspace/sgl-engine-workspace"

override_case="$tmp/override"
mkdir -p "$override_case/home" "$override_case/vault" "$override_case/logs"
HOME="$override_case/home" \
  SGL_ENGINE_WORKSPACE=/tmp/some-override \
  SGL_TRIAL_POLL="$recorder" \
  RECORDER_OUTPUT="$override_case/argv" \
  SGL_LOG_DIR="$override_case/logs" \
  SGL_HEARTBEAT_TOOL=/nonexistent \
  SGL_VAULT="$override_case/vault" \
  "$runner" || fail "override workspace invocation failed"
assert_workspace "$override_case/argv" /tmp/some-override

# File heartbeats are available even without an external tool.
grep -Eq '^status=ok at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z exit=0 duration_ms=[0-9]+ reason=-$' "$default_case/logs/trial-poll.heartbeat" || fail 'default file heartbeat invalid'
heartbeat="$tmp/heartbeat"
cat >"$heartbeat" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HEARTBEAT_CALLS"
EOF
chmod +x "$heartbeat"
for code in 0 1 3; do
  case_dir="$tmp/status-$code"; mkdir -p "$case_dir"
  actual=0
  POLL_STATUS="$code" SGL_TRIAL_POLL="$recorder" RECORDER_OUTPUT="$case_dir/poll.calls" \
    SGL_HEARTBEAT_TOOL="$heartbeat" HEARTBEAT_CALLS="$case_dir/heartbeat.calls" SGL_LOG_DIR="$case_dir/logs" \
    "$runner" || actual=$?
  [ "$actual" -eq "$code" ] || fail "exit $code became $actual"
  expected=fail; [ "$code" -ne 0 ] || expected=ok
  grep -Fq "self-growth-trial-poll $expected" "$case_dir/heartbeat.calls" || fail "tool heartbeat wrong for $code"
  grep -Eq "^status=$expected at=[^ ]+ exit=$code duration_ms=[0-9]+ reason=" "$case_dir/logs/trial-poll.heartbeat" || fail "file heartbeat wrong for $code"
done
for missing_tool in '' sgl-missing-heartbeat "$tmp/not-executable" "$tmp/not-there"; do
  printf '#!/bin/sh\n' >"$tmp/not-executable"
  required_dir="$tmp/required"; mkdir -p "$required_dir"
  actual=0
  SGL_REQUIRE_HEARTBEAT=1 SGL_HEARTBEAT_TOOL="$missing_tool" SGL_TRIAL_POLL="$recorder" \
    RECORDER_OUTPUT="$required_dir/poll.calls" SGL_LOG_DIR="$required_dir/logs" \
    "$runner" 2>"$required_dir/stderr" || actual=$?
  [ "$actual" -eq 2 ] || fail "required missing tool returned $actual"
  [ ! -e "$required_dir/poll.calls" ] || fail 'poll called without required tool'
  [ ! -e "$required_dir/logs" ] || fail 'logging started before required-tool preflight'
  grep -Fq "run-trial-poll.sh: heartbeat tool required but missing: $missing_tool" "$required_dir/stderr" || fail 'required-tool diagnostic absent'
done
SGL_REQUIRE_HEARTBEAT=1 SGL_HEARTBEAT_TOOL="$heartbeat" HEARTBEAT_CALLS="$required_dir/heartbeat.calls" \
  SGL_TRIAL_POLL="$recorder" RECORDER_OUTPUT="$required_dir/poll.calls" SGL_LOG_DIR="$required_dir/logs" \
  SGL_HEARTBEAT_FILE="$required_dir/custom.heartbeat" "$runner" || fail 'required present tool blocked poll'
[ -s "$required_dir/poll.calls" ] || fail 'required present tool did not run poll'
grep -Eq '^status=ok .* exit=0 ' "$required_dir/custom.heartbeat" || fail 'custom heartbeat path ignored'
actual=0
POLL_STATUS=3 SGL_HEARTBEAT_TOOL=/nonexistent SGL_TRIAL_POLL="$recorder" \
  RECORDER_OUTPUT="$required_dir/poll.calls" SGL_LOG_DIR="$required_dir/logs" \
  "$runner" 2>"$required_dir/stderr" || actual=$?
[ "$actual" -eq 3 ] || fail 'missing tool masked poll failure'
grep -Eq '^status=fail .* exit=3 ' "$required_dir/logs/trial-poll.heartbeat" || fail 'missing tool lost failure heartbeat'
actual=0
POLL_STATUS=3 SGL_HEARTBEAT_TOOL="$heartbeat" HEARTBEAT_CALLS="$required_dir/heartbeat.calls" \
  SGL_TRIAL_POLL="$recorder" RECORDER_OUTPUT="$required_dir/poll.calls" SGL_LOG_DIR="$required_dir/logs" \
  SGL_HEARTBEAT_FILE="$required_dir" "$runner" 2>"$required_dir/stderr" || actual=$?
[ "$actual" -eq 3 ] || fail 'file heartbeat failure masked poll status'
grep -Fq 'warning: heartbeat file update failed' "$required_dir/stderr" || fail 'file heartbeat warning absent'
[ -z "$(find "$tmp" -name '*.heartbeat.tmp.*' -print)" ] || fail 'heartbeat temp file leaked'

# Resolve a bare required heartbeat from the configured PATH.
cp "$heartbeat" "$tmp/job-heartbeat"
SGL_REQUIRE_HEARTBEAT=1 SGL_PATH="$tmp:/usr/bin:/bin" SGL_HEARTBEAT_TOOL=job-heartbeat \
  SGL_TRIAL_POLL="$recorder" RECORDER_OUTPUT="$tmp/bare-poll.calls" \
  HEARTBEAT_CALLS="$tmp/bare-heartbeat.calls" SGL_LOG_DIR="$tmp/bare-logs" \
  /bin/bash "$runner" || fail 'required bare heartbeat blocked poll'
[ -s "$tmp/bare-poll.calls" ] || fail 'bare tool preflight did not run poll'
grep -Fq 'self-growth-trial-poll ok' "$tmp/bare-heartbeat.calls" || fail 'bare heartbeat was not invoked'

# Both wrappers use the same reason shape for trapped signals.
cat >"$tmp/signal-poll" <<'EOF'
#!/bin/bash
printf started >"$RECORDER_OUTPUT"
sleep 3
printf finished >>"$RECORDER_OUTPUT"
EOF
chmod +x "$tmp/signal-poll"
SGL_TRIAL_POLL="$tmp/signal-poll" RECORDER_OUTPUT="$tmp/signal-marker" \
  SGL_HEARTBEAT_TOOL="$heartbeat" HEARTBEAT_CALLS="$tmp/signal-heartbeat.calls" \
  SGL_LOG_DIR="$tmp/signal-logs" /bin/bash "$runner" &
signal_pid=$!
attempt=0
while [ ! -e "$tmp/signal-marker" ] && [ "$attempt" -lt 50 ]; do
  sleep 0.1
  attempt=$((attempt + 1))
done
kill -TERM "$signal_pid" || fail 'could not signal wrapper'
actual=0
wait "$signal_pid" || actual=$?
[ "$actual" -eq 143 ] || fail "signal returned $actual"
grep -Fq -- '--reason signal TERM (exit 143); see trial-poll-' "$tmp/signal-heartbeat.calls" || fail 'signal reason mismatch'
grep -Fq 'reason=signal TERM (exit 143);' "$tmp/signal-logs/trial-poll.heartbeat" || fail 'file signal reason mismatch'
! grep -Fq finished "$tmp/signal-marker" || fail 'signal child survived'

echo "test-run-trial-poll.sh: PASS"
