#!/usr/bin/env bash
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
enqueue="$root/scripts/trial-enqueue.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-trial-enqueue.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() { echo "test-trial-enqueue.sh: $*" >&2; exit 1; }

write_engine() {
  engine=$1
  mkdir -p "$engine/templates" "$engine/scripts"
  cat >"$engine/templates/TASK.tmpl.md" <<'EOF'
---
id: {{TASK_ID}}
title: {{TITLE}}
issued_by: sho-alpha
created: {{CREATED_UTC}}
attempts_budget: 8
time_budget_min: 30
escalate_to: sho
verify: mechanical
parent_id: null
---

## Goal

{{GOAL}}

## Done-when

```donecheck
test -s "$ARTIFACT_DIR/out/delivery-receipt.json" || exit 1
```

## Step plan

1. {{STEP_1}}
2. deliver + capture receipt in "$ARTIFACT_DIR/out/delivery-receipt.json"

## Resources

- {{RESOURCE_PATH_OR_ENV_NAME}}

## Non-goals

- {{NON_GOAL}}
EOF
  cat >"$engine/scripts/tr-enqueue" <<'EOF'
#!/usr/bin/env bash
set -u
task_file=$1
workspace=$2
task_id=$(awk '$1 == "id:" { print $2; exit }' "$task_file")
mkdir -p "$workspace/loop/tasks/queue" "$workspace/loop/tasks/delivered" \
  "$workspace/loop/tasks/dlq" "$workspace/loop/artifacts/$task_id"
cp "$task_file" "$workspace/loop/tasks/queue/$task_id.task.md"
EOF
  chmod +x "$engine/scripts/tr-enqueue"
}

make_engine_fail_enqueue() {
  cat >"$case_engine/scripts/tr-enqueue" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$case_engine/scripts/tr-enqueue"
}

write_record() {
  path=$1
  topic=$2
  state=$3
  executor=$4
  risk=$5
  identity=$6
  events=${7-}
  cat >"$path" <<EOF
---
topic_key: $topic
title: "Trial $topic"
state: $state
state_entered_at: 2026-07-20T00:00:00Z
risk_tier: $risk
identity_critical: $identity
tiebreak: T0
proposer: mine
executor_agent: "$executor"
executor_model: ""
created: 2026-07-20
updated: 2026-07-20
cooldown_until: ""
retry_count: 0
source_items: []
links:
  trial_bundle: ""
  council_verdicts: ""
  adoption_entry: ""
backup_ref: ""
effect_metric: ""
report_due: ""
reversibility: "rollback = git revert 1 commit, <10 min, no data loss"
---

## Judgement

Test fixture.

## Events (append-only)

$events
EOF
}

new_case() {
  name=$1
  case_root="$tmp/$name"
  case_vault="$case_root/vault"
  case_workspace="$case_root/workspace"
  case_engine="$case_root/engine"
  case_ledger="$case_vault/45_ai-systems/self-growth/proposals"
  mkdir -p "$case_ledger" "$case_workspace"
  write_engine "$case_engine"
}

run_policy_refusal() {
  output_file=$1
  shift
  if invoke_enqueue "$@" >"$output_file.out" 2>"$output_file.err"; then
    fail "expected policy refusal"
  else
    status=$?
  fi
  [ "$status" -eq 3 ] || fail "expected exit 3, got $status"
}

invoke_enqueue() {
  "$enqueue" \
    --vault "$case_vault" \
    --topic tool__vendor \
    --executor-agent alpha \
    --executor-model test-model \
    --workspace "$case_workspace" \
    --engine "$case_engine" \
    --now 2026-07-21T12:00:00Z \
    "$@"
}

new_case concurrent
write_record "$case_ledger/tool__vendor.md" tool__vendor PROPOSED '' T0 false
write_record "$case_ledger/other__vendor.md" other__vendor TRIALING alpha T0 false
run_policy_refusal "$tmp/concurrent"
grep -q 'already has a TRIALING record' "$tmp/concurrent.err" || fail "missing concurrent-quota message"
grep -q '^state: PROPOSED$' "$case_ledger/tool__vendor.md" || fail "concurrent refusal changed target"

new_case weekly
write_record "$case_ledger/tool__vendor.md" tool__vendor PROPOSED '' T0 false
write_record "$case_ledger/one__vendor.md" one__vendor COUNCIL beta T0 false '- 2026-07-20T01:00:00Z alpha PROPOSED→TRIALING — task one'
write_record "$case_ledger/two__vendor.md" two__vendor COUNCIL gamma T0 false '- 2026-07-19T01:00:00Z alpha PROPOSED→TRIALING — task two'
write_record "$case_ledger/three__vendor.md" three__vendor DLQ delta T0 false '- 2026-07-18T01:00:00Z alpha COUNCIL→TRIALING — task three'
run_policy_refusal "$tmp/weekly"
grep -q '3 TRIALING-entry events' "$tmp/weekly.err" || fail "missing weekly-quota message"
grep -q '^state: PROPOSED$' "$case_ledger/tool__vendor.md" || fail "weekly refusal changed target"

new_case t2
write_record "$case_ledger/tool__vendor.md" tool__vendor PROPOSED '' T2 false
run_policy_refusal "$tmp/t2"
grep -q 'requires --sho-approved' "$tmp/t2.err" || fail "missing T2 approval message"

new_case identity-invalid
write_record "$case_ledger/tool__vendor.md" tool__vendor PROPOSED '' T0 true
if invoke_enqueue --sho-approved >"$tmp/identity-invalid.out" 2>"$tmp/identity-invalid.err"; then
  fail "invalid identity-critical record was accepted"
fi
grep -q 'invalid record per spec §2' "$tmp/identity-invalid.err" || fail "missing invalid identity-critical message"
grep -q '^state: PROPOSED$' "$case_ledger/tool__vendor.md" || fail "invalid identity-critical record changed state"

new_case identity-t2
write_record "$case_ledger/tool__vendor.md" tool__vendor PROPOSED '' T2 true
run_policy_refusal "$tmp/identity-t2"
grep -q 'requires --sho-approved' "$tmp/identity-t2.err" || fail "missing identity-critical approval message"
invoke_enqueue --sho-approved >"$tmp/identity-t2-approved.out" || fail "approved identity-critical enqueue failed"
ruby -ryaml -e 'abort unless (YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]))["risk_tier"] == "T2"' \
  "$case_ledger/tool__vendor.md" || fail "identity-critical trial lost T2 tier"
identity_packet=$(find "$case_vault/45_ai-systems/self-growth/trial-packets" -type f -name '*.md')
grep -q 'T2: collection-controls prerequisite closed' "$identity_packet" || fail "identity-critical packet lacks T2 isolation"

new_case backdated
write_record "$case_ledger/tool__vendor.md" tool__vendor PROPOSED '' T0 false
write_record "$case_ledger/other__vendor.md" other__vendor COUNCIL beta T0 false \
  '- 2026-07-21T13:00:00Z alpha PROPOSED→TRIALING — newer peer trial entry'
if invoke_enqueue >"$tmp/backdated.out" 2>"$tmp/backdated.err"; then
  fail "backdated --now was accepted"
fi
grep -q -- '--now must not backdate the ledger' "$tmp/backdated.err" || fail "missing backdated-now message"
grep -q '^state: PROPOSED$' "$case_ledger/tool__vendor.md" || fail "backdated refusal changed state"

new_case dry
write_record "$case_ledger/tool__vendor.md" tool__vendor PROPOSED '' T0 false
before=$(find "$case_vault" "$case_workspace" -print | sort; find "$case_vault" "$case_workspace" -type f -exec shasum {} \; | sort)
dry_task=$(invoke_enqueue --dry-run) || fail "dry-run failed"
after=$(find "$case_vault" "$case_workspace" -print | sort; find "$case_vault" "$case_workspace" -type f -exec shasum {} \; | sort)
[ "$before" = "$after" ] || fail "dry-run touched vault or workspace"
[ -s "$dry_task" ] || fail "dry-run did not leave rendered task at printed path"
rm -rf "$(dirname -- "$dry_task")"

new_case success
write_record "$case_ledger/tool__vendor.md" tool__vendor PROPOSED '' T0 false
invoke_enqueue >"$tmp/success.out" || fail "successful enqueue failed"
task_id=sgl-trial-tool__vendor-20260721t120000
record="$case_ledger/tool__vendor.md"
task="$case_workspace/loop/tasks/queue/$task_id.task.md"
packet="$case_vault/45_ai-systems/self-growth/trial-packets/$task_id.md"
[ -s "$task" ] || fail "engine task was not enqueued"
[ -s "$packet" ] || fail "trial packet was not installed"
grep -Eq '\{\{[A-Z0-9_]+\}\}' "$task" "$packet" && fail "rendered output contains unresolved placeholders"
ruby -ryaml -e 'data = YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]); abort unless data.is_a?(Hash)' "$record" || fail "updated record is not valid YAML"
ruby -ryaml -e '
  data = YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0])
  abort unless data["state"] == "TRIALING"
  abort unless data["executor_agent"] == "alpha"
  abort unless data["executor_model"] == "test-model"
  abort unless data.dig("links", "trial_bundle") == "loop/artifacts/sgl-trial-tool__vendor-20260721t120000/"
' "$record" || fail "updated record fields are wrong"
grep -q "PROPOSED→TRIALING — task $task_id enqueued" "$record" || fail "transition event is missing task token"
for bundle_file in run.log env-manifest.txt config-diff.txt permissions.md cost.txt attempts.md repro.md rollback-test.md; do
  grep -q "out/bundle/$bundle_file" "$task" || fail "task donecheck missing $bundle_file"
done
grep -q 'out/delivery-receipt.json' "$task" || fail "task lost delivery receipt assertion"

new_case locale
write_record "$case_ledger/tool__vendor.md" tool__vendor PROPOSED '' T0 false
LC_ALL=C LANG=C invoke_enqueue >"$tmp/locale.out" || fail "LC_ALL=C trial-enqueue failed"
[ -s "$case_workspace/loop/tasks/queue/sgl-trial-tool__vendor-20260721t120000.task.md" ] || fail "locale enqueue missing task"

new_case enqueue-failure
write_record "$case_ledger/tool__vendor.md" tool__vendor PROPOSED '' T0 false
make_engine_fail_enqueue
if invoke_enqueue >"$tmp/enqueue-failure.out" 2>"$tmp/enqueue-failure.err"; then
  fail "failing engine enqueue was accepted"
fi
grep -q '^state: PROPOSED$' "$case_ledger/tool__vendor.md" || fail "failed engine enqueue did not revert state"
grep -q 'TRIALING→PROPOSED — compensating transition' "$case_ledger/tool__vendor.md" || fail "failed engine enqueue lacks compensating event"
ruby -ryaml -e '
  data = YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0])
  abort unless data["state_entered_at"].to_s == "2026-07-20 00:00:00 UTC"
  abort unless data.dig("links", "trial_bundle") == ""
' "$case_ledger/tool__vendor.md" || fail "failed engine enqueue did not restore pre-transition metadata"

echo "test-trial-enqueue.sh: PASS"
