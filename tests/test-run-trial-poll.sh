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

echo "test-run-trial-poll.sh: PASS"
