#!/usr/bin/env bash
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
enqueue="$root/scripts/trial-enqueue.sh"
poll="$root/scripts/trial-poll.sh"
engine_source=${SGL_ENGINE_SOURCE:-$HOME/claude-workspace/caty-agent-harness}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-trial-integration.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() { echo "test-trial-integration.sh: $*" >&2; exit 1; }

# The pin moved from fable-loop-harness v1.2.0 to caty-agent-harness v0.6.0;
# the fresh public history restarted tag numbering at v0.1.0.
expected_network_oid=b7e1be18c3fce32965c9c72ae07cacb5dea33d0b
local_tag_oid=$(git -C "$engine_source" rev-parse -q --verify 'refs/tags/v0.6.0^{commit}' 2>/dev/null) || local_tag_oid=''
engine=''
engine_origin=''

if [ -n "$local_tag_oid" ]; then
  local_engine="$tmp/engine-local-v0.6.0"
  if git clone --local --no-hardlinks "$engine_source" "$local_engine" >/dev/null 2>&1 &&
    git -C "$local_engine" checkout --detach "$local_tag_oid" >/dev/null 2>&1; then
    engine=$local_engine
    engine_origin=local
  else
    fail "local engine clone/checkout failed for pinned tag v0.6.0"
  fi
fi

if [ -z "$engine" ]; then
  network_engine="$tmp/engine-network-v0.6.0"
  if git clone --depth 1 --branch v0.6.0 https://github.com/caty-ai/caty-agent-harness.git "$network_engine" >/dev/null 2>&1; then
    engine=$network_engine
    engine_origin=network
  else
    echo "SKIP: engine source unavailable (local checkout missing, network clone failed)"
    exit 3
  fi
fi

tag_oid=$(git -C "$engine" rev-parse -q --verify 'refs/tags/v0.6.0^{commit}') \
  || fail "$engine_origin engine clone is missing pinned tag v0.6.0"
[ -n "$tag_oid" ] \
  || fail "$engine_origin engine clone is missing pinned tag v0.6.0"
[ "$(git -C "$engine" rev-parse HEAD)" = "$tag_oid" ] \
  || fail "engine clone HEAD does not equal its v0.6.0 tag OID"
if [ "$engine_origin" = local ]; then
  [ "$tag_oid" = "$local_tag_oid" ] \
    || fail "local engine clone tag OID changed during clone"
else
  [ "$tag_oid" = "$expected_network_oid" ] \
    || fail "network engine tag OID $tag_oid does not equal expected $expected_network_oid"
fi
echo "test-trial-integration.sh: verified v0.6.0 tag OID $tag_oid ($engine_origin source)"

vault="$tmp/vault"
workspace="$tmp/workspace"
ledger="$vault/45_ai-systems/self-growth/proposals"
mkdir -p "$ledger" "$workspace"
"$engine/scripts/loop-init" --workspace "$workspace" >/dev/null 2>&1 \
  || fail "could not initialize the trial workspace with pinned engine v0.6.0"

write_record() {
  topic=$1
  state=$2
  task_id=${3-}
  executor=''
  model=''
  bundle=''
  event='- 2026-07-20T00:00:00Z alpha PROPOSED — integration fixture'
  if [ "$state" = TRIALING ]; then
    executor=alpha
    model=test-model
    bundle="loop/artifacts/$task_id/"
    event="- 2026-07-20T00:00:00Z alpha PROPOSED→TRIALING — task $task_id enqueued"
  fi
  cat >"$ledger/$topic.md" <<EOF
---
topic_key: $topic
title: "Integration trial $topic"
state: $state
state_entered_at: 2026-07-20T00:00:00Z
risk_tier: T0
identity_critical: false
tiebreak: T0
proposer: mine
executor_agent: "$executor"
executor_model: "$model"
created: 2026-07-20
updated: 2026-07-20
cooldown_until: ""
retry_count: 0
source_items: []
links:
  trial_bundle: "$bundle"
  council_verdicts: ""
  adoption_entry: ""
backup_ref: ""
effect_metric: ""
report_due: ""
reversibility: "rollback = remove temp workspace, <10 min, no data loss"
---

## Judgement

Pinned-engine integration fixture.

## Events (append-only)

$event
EOF
}

write_record integration__vendor PROPOSED

spawn_step="$tmp/spawn-success.sh"
cat >"$spawn_step" <<'EOF'
#!/usr/bin/env bash
set -u
: "$1" "$2" "$4"
attempt_dir=$3
artifact_dir=$(CDPATH='' cd -- "$attempt_dir/../.." && pwd)
bundle="$artifact_dir/out/bundle"
mkdir -p "$bundle"
for name in run.log env-manifest.txt config-diff.txt permissions.md cost.txt attempts.md repro.md rollback-test.md; do
  printf 'integration artifact: %s\n' "$name" >"$bundle/$name"
done
printf '{"delivered":true}\n' >"$artifact_dir/out/delivery-receipt.json"
printf '{"step_complete":true,"error_class":"none","files_created":[]}\n' \
  >"$attempt_dir/step-result.json"
EOF
chmod +x "$spawn_step"

"$enqueue" \
  --vault "$vault" \
  --topic integration__vendor \
  --executor-agent alpha \
  --executor-model test-model \
  --workspace "$workspace" \
  --engine "$engine" \
  --now 2026-07-21T12:00:00Z \
  >"$tmp/enqueue.out" || fail "real pinned tr-enqueue rejected the rendered task"

task_id=sgl-trial-integration__vendor-20260721t120000
TR_SPAWN_STEP="$spawn_step" "$engine/scripts/task-runner.sh" "$workspace" \
  >"$tmp/runner.out" 2>"$tmp/runner.err" || fail "real pinned task-runner failed"
[ -d "$workspace/loop/tasks/delivered/$task_id" ] \
  || fail "real runner did not deliver the trial task"
[ -f "$workspace/loop/artifacts/$task_id/attempts/001/donecheck.log" ] \
  || fail "real runner did not execute donecheck"

"$poll" --vault "$vault" --workspace "$workspace" --now 2026-07-21T12:05:00Z \
  >"$tmp/poll-delivered.out" || fail "poll failed after real delivery"
ruby -ryaml -e 'abort unless (YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]))["state"] == "COUNCIL"' \
  "$ledger/integration__vendor.md" || fail "delivered integration trial did not advance to COUNCIL"
grep -q "TRIALING→COUNCIL — task $task_id delivered" "$ledger/integration__vendor.md" \
  || fail "delivered integration event is missing the task token"

# Polling only reads terminal directories, so a manually placed DLQ task is a fair
# integration fixture and keeps this test below two minutes; delivery above still
# exercises the real pinned runner end to end.
dlq_task_id=sgl-trial-integration-dlq__vendor-20260721t121000
write_record integration-dlq__vendor TRIALING "$dlq_task_id"
mkdir -p "$workspace/loop/tasks/dlq/$dlq_task_id"
: >"$workspace/loop/tasks/dlq/$dlq_task_id/$dlq_task_id.task.md"
mkdir -p "$workspace/loop/artifacts/$dlq_task_id"
printf '{"status":"dlq"}\n' >"$workspace/loop/artifacts/$dlq_task_id/state.json"
"$poll" --vault "$vault" --workspace "$workspace" --now 2026-07-21T12:10:00Z \
  >"$tmp/poll-dlq.out" || fail "poll failed for simulated terminal DLQ"
ruby -ryaml -e 'abort unless (YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]))["state"] == "DLQ"' \
  "$ledger/integration-dlq__vendor.md" || fail "terminal DLQ task did not advance the record"
grep -q "TRIALING→DLQ — task $dlq_task_id abandoned to engine DLQ" \
  "$ledger/integration-dlq__vendor.md" || fail "DLQ integration event is missing the task token"

missing_state_task_id=sgl-trial-integration-missing__vendor-20260721t121500
write_record integration-missing__vendor TRIALING "$missing_state_task_id"
mkdir -p "$workspace/loop/tasks/delivered/$missing_state_task_id"
set +e
"$poll" --vault "$vault" --workspace "$workspace" --now 2026-07-21T12:15:00Z \
  >"$tmp/poll-missing.out" 2>"$tmp/poll-missing.err"
missing_status=$?
set -e
[ "$missing_status" -ne 0 ] || fail "poll accepted an empty delivered directory"
ruby -ryaml -e 'abort unless (YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]))["state"] == "TRIALING"' \
  "$ledger/integration-missing__vendor.md" || fail "empty delivered directory advanced the record"
grep -q "DAMAGED_EVIDENCE integration-missing__vendor: missing artifact state.json" "$tmp/poll-missing.err" \
  || fail "missing empty-delivered evidence diagnostic"

echo "test-trial-integration.sh: PASS"
