#!/usr/bin/env bash
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
enqueue="$root/scripts/trial-enqueue.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-council-retry.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fail() { echo "test-council-retry.sh: $*" >&2; exit 1; }

write_engine() {
  engine=$1
  mkdir -p "$engine/templates" "$engine/scripts"
  cat >"$engine/templates/TASK.tmpl.md" <<'EOF'
---
id: {{TASK_ID}}
title: {{TITLE}}
created: {{CREATED_UTC}}
---
## Goal
{{GOAL}}
```donecheck
test -s "$ARTIFACT_DIR/out/delivery-receipt.json"
```
EOF
  cat >"$engine/scripts/tr-enqueue" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(awk '$1 == "id:" { print $2; exit }' "$1")
mkdir -p "$2/loop/tasks/queue" "$2/loop/artifacts/$id"
cp "$1" "$2/loop/tasks/queue/$id.task.md"
EOF
  chmod +x "$engine/scripts/tr-enqueue"
}

new_case() {
  name=$1; topic=${2-tool__vendor}; prior="sgl-trial-$topic-20260720t120000"
  case_root="$tmp/$name"; vault="$case_root/vault"; workspace="$case_root/workspace"; engine="$case_root/engine"
  ledger="$vault/45_ai-systems/self-growth/proposals"; council="$vault/45_ai-systems/self-growth/council/$topic"
  mkdir -p "$ledger" "$council" "$workspace"; write_engine "$engine"
  write_record "$ledger/$topic.md" "$topic" COUNCIL 0
  write_retry_evidence "$council" "$prior" RETRY true
}

write_record() {
  local path=$1 record_topic=$2 state=$3 retries=$4
  cat >"$path" <<EOF
---
topic_key: $record_topic
title: "Trial $record_topic"
state: $state
state_entered_at: 2026-07-20T00:00:00Z
risk_tier: T1
identity_critical: false
tiebreak: T0
proposer: mine
executor_agent: alpha
executor_model: test-model
created: 2026-07-20
updated: 2026-07-20
cooldown_until: ""
retry_count: $retries
source_items: []
links:
  trial_bundle: "loop/artifacts/$prior/"
  council_verdicts: "council/$record_topic/"
  adoption_entry: ""
backup_ref: ""
effect_metric: ""
report_due: ""
reversibility: "rollback = remove scratch directory, <10 min, no data loss"
---

## Events (append-only)

EOF
}

write_retry_evidence() {
  local dir=$1 id=$2 decision=$3 sealed=$4
  cat >"$dir/$id.convene.yaml" <<EOF
schema: sgl-council-convene/v1
topic_key: $topic
task_id: $id
sealed: $sealed
decision: $decision
EOF
  cat >"$dir/$id.quorum.md" <<EOF
---
schema: sgl-council-quorum/v1
task_id: $id
decision: $decision
decision_at: 2026-07-20T12:00:00Z
sealed: $sealed
---

# Council quorum
EOF
  printf '%s\n' '- Change input: bounded fixture' >"$dir/$id.retry-plan.md"
}

invoke() {
  "$enqueue" --vault "$vault" --topic "$topic" --executor-agent alpha --executor-model test-model \
    --workspace "$workspace" --engine "$engine" --retry-from "$prior" --now 2026-07-21T12:00:00Z "$@"
}

expect_refusal() {
  code=$1 needle=$2; shift 2
  if invoke "$@" >"$case_root/out" 2>"$case_root/err"; then
    fail "expected refusal: $needle"
  else
    status=$?
  fi
  [ "$status" -eq "$code" ] || fail "expected exit $code for $needle, got $status"
  grep -q "$needle" "$case_root/err" || fail "missing $needle"
}

new_case happy
invoke >"$case_root/out" || fail "retry enqueue failed"
new_id="sgl-trial-$topic-20260721t120000"
packet="$vault/45_ai-systems/self-growth/trial-packets/$new_id.md"
[ -s "$workspace/loop/tasks/queue/$new_id.task.md" ] || fail "engine queue file missing"
grep -q -- "- Parent task: $prior" "$packet" || fail "packet parent missing"
grep -q -- '- Retry: 1 of 2' "$packet" || fail "packet retry count missing"
grep -q '## Retry plan' "$packet" || fail "packet retry plan missing"
grep -q "council/$topic/$prior.retry-plan.md" "$packet" || fail "packet provenance missing"
ruby -ryaml -e 'd=YAML.load_file(ARGV[0]); abort unless d["state"] == "TRIALING" && d["retry_count"] == 1' "$ledger/$topic.md" || fail "retry transition wrong"
grep -q "(retry 1/2, parent $prior)" "$ledger/$topic.md" || fail "retry event missing"

new_case limit
write_record "$ledger/$topic.md" "$topic" COUNCIL 2
expect_refusal 3 RETRY_LIMIT

new_case no-plan
rm "$council/$prior.retry-plan.md"
expect_refusal 3 RETRY_PLAN_MISSING

new_case not-ordered
write_retry_evidence "$council" "$prior" GO true
expect_refusal 3 RETRY_NOT_ORDERED

new_case unsealed
write_retry_evidence "$council" "$prior" RETRY false
expect_refusal 3 RETRY_NOT_ORDERED

new_case wrong-state
write_record "$ledger/$topic.md" "$topic" PROPOSED 0
expect_refusal 3 RETRY_NOT_ORDERED

# F2: an old RETRY report cannot authorize a retry once the record points at a newer round.
new_case old-round
newer="sgl-trial-$topic-20260721t110000"
ruby -e 'p=ARGV[0]; s=File.read(p); File.write(p, s.sub(ARGV[1], ARGV[2]))' "$ledger/$topic.md" "$prior" "$newer"
expect_refusal 3 RETRY_NOT_ORDERED

# The weekly counter excludes retry-tagged events; three such events do not block.
new_case retry-events
for n in one two three; do write_record "$ledger/${n}__vendor.md" "${n}__vendor" COUNCIL 0; printf '%s\n' "- 2026-07-20T01:00:00Z alpha COUNCIL→TRIALING — task $n (retry 1/2, parent x)" >>"$ledger/${n}__vendor.md"; done
invoke >"$case_root/out" || fail "retry-tagged events incorrectly counted"

# F14: retry mode bypasses the weekly cap.  A title/rationale containing
# "(retry " is still a first-entry event and must not change that exemption.
new_case first-events
for n in one two three; do write_record "$ledger/${n}__vendor.md" "${n}__vendor" COUNCIL 0; printf '%s\n' "- 2026-07-20T01:00:00Z alpha PROPOSED→TRIALING — task $n (retry mention in ordinary title)" >>"$ledger/${n}__vendor.md"; done
invoke >"$case_root/out" || fail "weekly first-entry events blocked retry"
grep -q '^state: TRIALING$' "$ledger/$topic.md" || fail "retry did not transition despite exemption"

# The same free-text token must not make a first-entry event disappear from a
# normal enqueue's cap calculation.
new_case title-spoof
write_record "$ledger/$topic.md" "$topic" PROPOSED 0
for n in one two three; do write_record "$ledger/${n}__vendor.md" "${n}__vendor" COUNCIL 0; printf '%s\n' "- 2026-07-20T01:00:00Z alpha PROPOSED→TRIALING — task $n (retry mention in ordinary title)" >>"$ledger/${n}__vendor.md"; done
if "$enqueue" --vault "$vault" --topic "$topic" --executor-agent alpha --executor-model test-model --workspace "$workspace" --engine "$engine" --now 2026-07-21T12:00:00Z >"$case_root/out" 2>"$case_root/err"; then fail "title-spoof bypassed weekly cap"; fi
grep -q '3 TRIALING-entry events' "$case_root/err" || fail "title-spoof was not counted as first-entry"

new_case enqueue-failure
cat >"$engine/scripts/tr-enqueue" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$engine/scripts/tr-enqueue"
if invoke >"$case_root/out" 2>"$case_root/err"; then fail "failed engine accepted"; fi
ruby -ryaml -e 'd=YAML.load_file(ARGV[0]); abort unless d["state"] == "COUNCIL" && d["retry_count"] == 0' "$ledger/$topic.md" || fail "engine failure did not revert retry state"
grep -q 'TRIALING→COUNCIL — compensating transition' "$ledger/$topic.md" || fail "missing retry compensating event"

echo "test-council-retry.sh: PASS"
