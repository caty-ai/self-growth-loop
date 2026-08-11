#!/usr/bin/env bash
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
poll="$root/scripts/trial-poll.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-trial-poll.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() { echo "test-trial-poll.sh: $*" >&2; exit 1; }

vault="$tmp/vault"
workspace="$tmp/workspace"
ledger="$vault/45_ai-systems/self-growth/proposals"
mkdir -p "$ledger" "$workspace/loop/tasks/delivered" "$workspace/loop/tasks/dlq"

write_trialing() {
  topic=$1
  task_id=$2
  cat >"$ledger/$topic.md" <<EOF
---
topic_key: $topic
title: "Trial $topic"
state: TRIALING
state_entered_at: 2026-07-20T00:00:00Z
risk_tier: T0
identity_critical: false
tiebreak: T0
proposer: mine
executor_agent: alpha
executor_model: test-model
created: 2026-07-20
updated: 2026-07-20
cooldown_until: ""
retry_count: 0
source_items: []
links:
  trial_bundle: "loop/artifacts/$task_id/"
  council_verdicts: ""
  adoption_entry: ""
backup_ref: ""
effect_metric: ""
report_due: ""
reversibility: "rollback = remove scratch directory, <10 min, no data loss"
---

## Judgement

Test fixture.

## Events (append-only)

- 2026-07-20T00:00:00Z alpha PROPOSED→TRIALING — task $task_id enqueued
EOF
}

delivered_id=sgl-trial-delivered__vendor-20260720t120000
dlq_id=sgl-trial-dlq__vendor-20260720t120000
waiting_id=sgl-trial-waiting__vendor-20260720t120000
damaged_id=sgl-trial-damaged__vendor-20260720t120000
write_trialing delivered__vendor "$delivered_id"
write_trialing dlq__vendor "$dlq_id"
write_trialing waiting__vendor "$waiting_id"
write_trialing damaged__vendor "$damaged_id"

mkdir -p "$workspace/loop/tasks/delivered/$delivered_id"
: >"$workspace/loop/tasks/delivered/$delivered_id/$delivered_id.task.md"
mkdir -p "$workspace/loop/tasks/dlq/$dlq_id"
: >"$workspace/loop/tasks/dlq/$dlq_id/$dlq_id.task.md"
mkdir -p "$workspace/loop/artifacts/$delivered_id" "$workspace/loop/artifacts/$dlq_id"
printf '{"status":"delivered"}\n' >"$workspace/loop/artifacts/$delivered_id/state.json"
printf '{"status":"dlq"}\n' >"$workspace/loop/artifacts/$dlq_id/state.json"
# A terminal directory without artifact state is damaged evidence and must not advance.
mkdir -p "$workspace/loop/tasks/delivered/$damaged_id"
waiting_before=$(shasum "$ledger/waiting__vendor.md")

set +e
"$poll" --vault "$vault" --workspace "$workspace" --now 2026-07-21T12:00:00Z >"$tmp/poll.out" 2>"$tmp/poll.err"
poll_status=$?
set -e
[ "$poll_status" -ne 0 ] || fail "poll accepted damaged terminal evidence"

ruby -ryaml -e 'abort unless YAML.load_file(ARGV[0])["state"] == "COUNCIL"' \
  "$ledger/delivered__vendor.md" || fail "delivered task did not advance to COUNCIL"
ruby -ryaml -e 'abort unless YAML.load_file(ARGV[0])["state"] == "DLQ"' \
  "$ledger/dlq__vendor.md" || fail "dlq task did not advance to DLQ"
ruby -ryaml -e 'abort unless YAML.load_file(ARGV[0])["state"] == "TRIALING"' \
  "$ledger/waiting__vendor.md" || fail "unmatched task changed state"
ruby -ryaml -e 'abort unless YAML.load_file(ARGV[0])["state"] == "TRIALING"' \
  "$ledger/damaged__vendor.md" || fail "damaged terminal evidence changed state"

grep -q "TRIALING→COUNCIL — task $delivered_id delivered; trial bundle at" \
  "$ledger/delivered__vendor.md" || fail "COUNCIL event is missing the task token"
grep -q "TRIALING→DLQ — task $dlq_id abandoned to engine DLQ" \
  "$ledger/dlq__vendor.md" || fail "DLQ event is missing the task token"
[ "$waiting_before" = "$(shasum "$ledger/waiting__vendor.md")" ] || fail "unmatched record was rewritten"
grep -q "DAMAGED_EVIDENCE damaged__vendor: missing artifact state.json" "$tmp/poll.err" \
  || fail "missing damaged-evidence diagnostic"

ruby -ryaml -e 'ARGV.each { |path| abort unless YAML.load_file(path).is_a?(Hash) }' \
  "$ledger/delivered__vendor.md" "$ledger/dlq__vendor.md" "$ledger/waiting__vendor.md" "$ledger/damaged__vendor.md" \
  || fail "poll produced invalid YAML"

echo "test-trial-poll.sh: PASS"
