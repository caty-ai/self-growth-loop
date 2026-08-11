#!/usr/bin/env bash
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-adopt.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fail() { echo "test-adopt.sh: $*" >&2; exit 1; }

future_due_utc() {
  ruby -e 'now = Time.now.utc; print(Time.utc(now.year + 1, now.month, now.day, now.hour, now.min, now.sec).strftime("%Y-%m-%dT%H:%M:%SZ"))'
}

report_due=$(future_due_utc) || fail "could not derive future report_due fixture"

approve="$root/scripts/adopt-approve.sh"
reject="$root/scripts/adopt-reject.sh"
watch="$root/scripts/adopt-watch.sh"
complete="$root/scripts/adopt-complete.sh"
abort_cmd="$root/scripts/adopt-abort.sh"
rollback_cmd="$root/scripts/adopt-rollback-done.sh"
for entrypoint in "$approve" "$reject" "$watch" "$complete" "$abort_cmd" "$rollback_cmd"; do
  [ -x "$entrypoint" ] || fail "entrypoint is not executable: $entrypoint"
done

write_owner() {
  mkdir -p "$vault/45_ai-systems/self-growth/config"
  printf '%s\n' \
    'schema: sgl-owner-config/v1' \
    'principal: sho' \
    'repository_id: caty-ai/self-growth-loop' \
    'default_assurance: standard' \
    >"$vault/45_ai-systems/self-growth/config/owner.yaml"
}

write_pending_t0() {
  topic=$1
  task="sgl-trial-$topic-20260720t000000"
  record="$vault/45_ai-systems/self-growth/proposals/$topic.md"
  mkdir -p "$(dirname "$record")" "$vault/45_ai-systems/self-growth/council/$topic"
  cat >"$record" <<EOF
---
schema: sgl-proposal/v2
topic_key: $topic
title: Adopt $topic
state: PENDING_SHO
state_entered_at: 2026-07-20T00:00:00Z
risk_tier: T0
identity_critical: false
tiebreak: T0
proposer: mine
executor_agent: alpha
executor_model: gpt-5
created: 2026-07-20
updated: 2026-07-20
cooldown_until: ""
retry_count: 0
proposal_attempt: 1
owner_confirmation:
  status: pending
  assurance: standard
  reference: ""
  proposal_digest: ""
  decision: ""
  principal: ""
  verified_at: ""
source_items: []
links:
  trial_bundle: "loop/artifacts/$task/"
  council_verdicts: ""
  adoption_entry: ""
backup_ref: ""
effect_metric: ""
report_due: ""
reversibility: "git revert one commit"
---

## Judgement

This reversible fixture is ready for an exact owner disposition.

## Events (append-only)

EOF
  cat >"$vault/45_ai-systems/self-growth/council/$topic/$task.t0-skip.md" <<EOF
sgl-t0-skip/v1
sealed: true
topic-key: $topic
task-id: $task
trial-reference: loop/artifacts/$task/
packet-sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bundle-map-sha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
marker: auto-adopt path (T0), council skipped
EOF
}

new_case() {
  vault="$tmp/$1/vault"
  mkdir -p "$vault"
  write_owner
}

issue_artifact() {
  decision=$1 backup=${2-} metric=${3-} due=${4-} reason=${5-} age=${6:-10}
  ruby - "$root" "$vault" "$topic" "$decision" "$backup" "$metric" "$due" "$reason" "$age" <<'RUBY'
repo, vault, topic, decision, backup, metric, due, reason, age = ARGV
require "fileutils"
require File.join(repo, "scripts/lib-owner-confirmation")
record_path = File.join(vault, "45_ai-systems/self-growth/proposals", "#{topic}.md")
record = OwnerConfirmation.load_proposal_record(path: record_path)
owner = OwnerConfirmation.load_owner_config(vault_root: vault)
evidence = OwnerConfirmation.derive_t0_evidence(vault_root: vault, workspace_root: nil, record: record)
inputs = decision == "GO" ? {"backup_ref" => backup, "effect_metric" => metric, "report_due" => due} : {"reason" => reason}
bytes = OwnerConfirmation.build_owner_confirmation_artifact(
  record: record, owner_config: owner, decision: decision,
  issued_at: Time.now.utc - age.to_i, issued_inputs: inputs, evidence: evidence
)
relative = OwnerConfirmation.owner_confirmation_relative_path(topic_key: topic, proposal_attempt: 1)
path = File.join(vault, relative)
FileUtils.mkdir_p(File.dirname(path))
File.binwrite(path, bytes)
puts OwnerConfirmation.build_owner_confirmation_reference(topic_key: topic, proposal_attempt: 1, bytes: bytes)
RUBY
}

assert_verified() {
  expected_decision=$1 expected_state=$2
  ruby -ryaml -e '
    d = YAML.load_file(ARGV[0])
    owner = d["owner_confirmation"]
    abort unless d["state"] == ARGV[1]
    abort unless owner.keys == %w[status assurance reference proposal_digest decision principal verified_at]
    abort unless owner["status"] == "verified" && owner["assurance"] == "standard"
    abort unless owner["decision"] == ARGV[2] && owner["principal"] == "sho"
    abort unless owner["reference"].match?(/\A45_ai-systems\/self-growth\/confirmations\//)
    abort unless owner["proposal_digest"].match?(/\Asha256:[0-9a-f]{64}\z/)
    abort unless owner["verified_at"].match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T/)
  ' "$record" "$expected_state" "$expected_decision" || fail "$expected_decision verified mapping invalid"
}

expect_usage_error() {
  label=$1
  tracked_record=$2
  expected_message=$3
  shift 3
  cp "$tracked_record" "$tmp/$label.before"
  status=0
  "$@" >"$tmp/$label.out" 2>"$tmp/$label.err" || status=$?
  [ "$status" -eq 2 ] || fail "$label exit code was $status"
  grep -q -- "$expected_message" "$tmp/$label.err" || fail "$label message missing"
  cmp -s "$tracked_record" "$tmp/$label.before" || fail "$label changed proposal"
}

extract_owner_confirmation_block() {
  ruby -e '
    text = File.binread(ARGV[0])
    start = text.index("owner_confirmation:\n")
    finish = text.index("source_items:", start)
    abort unless start && finish && finish > start
    print text.byteslice(start, finish - start)
  ' "$1"
}

state_time_offset() {
  ruby -ryaml -rtime -e '
    t = Time.iso8601(YAML.load_file(ARGV[0]).fetch("state_entered_at"))
    print (t + ARGV[1].to_i).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  ' "$1" "$2"
}

set_record_field() {
  FIELD=$2 VALUE=$3 ruby -e '
    path = ARGV[0]
    field = ENV.fetch("FIELD")
    value = ENV.fetch("VALUE")
    lines = File.readlines(path)
    stop = lines[1..-1].index("---\n")
    abort unless stop
    stop += 1
    lines.map!.with_index do |line, index|
      index < stop && line.start_with?("#{field}:") ? "#{field}: #{value}\n" : line
    end
    File.write(path, lines.join)
  ' "$1"
}

# Every disposition consumes exactly once and an identical retry is a no-op.
for decision in GO REJECT WATCH; do
  case_name=$(printf '%s' "$decision" | tr '[:upper:]' '[:lower:]')
  new_case "$case_name"; topic="${case_name}__tool"; write_pending_t0 "$topic"
  case "$decision" in
    GO)
      backup="backup; literal=1"; metric="latency p95 -20%"; due=$report_due
      reference=$(issue_artifact GO "$backup" "$metric" "$due" "")
      "$approve" --vault "$vault" --topic "$topic" --authorization-ref "$reference" \
        --backup-ref "$backup" --effect-metric "$metric" --report-due "$due" \
        >/dev/null || fail "GO initial consume failed"
      target=ADOPTING
      consume=( "$approve" --vault "$vault" --topic "$topic" --authorization-ref "$reference" --backup-ref "$backup" --effect-metric "$metric" --report-due "$due" )
      ;;
    REJECT)
      reason="unsafe; keep literal"
      reference=$(issue_artifact REJECT "" "" "" "$reason")
      "$reject" --vault "$vault" --topic "$topic" --authorization-ref "$reference" --reason "$reason" >/dev/null || fail "REJECT initial consume failed"
      target=REJECTED
      consume=( "$reject" --vault "$vault" --topic "$topic" --authorization-ref "$reference" --reason "$reason" )
      ;;
    WATCH)
      reason="wait; observe literal"
      reference=$(issue_artifact WATCH "" "" "" "$reason")
      "$watch" --vault "$vault" --topic "$topic" --authorization-ref "$reference" --reason "$reason" >/dev/null || fail "WATCH initial consume failed"
      target=WATCH
      consume=( "$watch" --vault "$vault" --topic "$topic" --authorization-ref "$reference" --reason "$reason" )
      ;;
  esac
  assert_verified "$decision" "$target"
  cp "$record" "$tmp/$case_name.after"
  "${consume[@]}" >/dev/null || fail "$decision identical retry failed"
  cmp -s "$record" "$tmp/$case_name.after" || fail "$decision retry changed proposal bytes"
  [ "$(grep -c "Sho $decision;" "$record")" -eq 1 ] || fail "$decision event was not exactly-once"
done

# Stale digest takes precedence over retry ordering; missing is distinct.
vault="$tmp/go/vault"; topic=go__tool; record="$vault/45_ai-systems/self-growth/proposals/$topic.md"
reference=$(ruby -ryaml -e 'print YAML.load_file(ARGV[0]).dig("owner_confirmation","reference")' "$record")
zeros=$(printf '%064d' 0)
stale_reference="${reference%sha256:*}sha256:$zeros"
cp "$record" "$tmp/go.before-errors"
if "$approve" --vault "$vault" --topic "$topic" --authorization-ref "$stale_reference" \
  --backup-ref "backup; literal=1" --effect-metric "latency p95 -20%" --report-due "$report_due" \
  >"$tmp/stale.out" 2>"$tmp/stale.err"; then
  fail "stale reference accepted"
fi
grep -q 'authorization-reference-stale' "$tmp/stale.err" || fail "stale reference token missing"
cmp -s "$record" "$tmp/go.before-errors" || fail "stale reference changed proposal"
artifact="$vault/${reference%%#sha256:*}"
cp "$artifact" "$tmp/go.artifact"
rm "$artifact"
if "$approve" --vault "$vault" --topic "$topic" --authorization-ref "$reference" \
  --backup-ref "backup; literal=1" --effect-metric "latency p95 -20%" --report-due "$report_due" \
  >"$tmp/missing.out" 2>"$tmp/missing.err"; then
  fail "missing retry artifact accepted"
fi
grep -q 'authorization-artifact-missing' "$tmp/missing.err" || fail "missing artifact token missing"
cmp -s "$record" "$tmp/go.before-errors" || fail "missing artifact changed proposal"
cp "$tmp/go.artifact" "$artifact"

# A valid but expired initial artifact cannot be consumed.
new_case expired; topic=expired__tool; write_pending_t0 "$topic"
reference=$(issue_artifact WATCH "" "" "" "wait" 172800)
cp "$record" "$tmp/expired.before"
if "$watch" --vault "$vault" --topic "$topic" --authorization-ref "$reference" --reason wait \
  >"$tmp/expired.out" 2>"$tmp/expired.err"; then
  fail "expired artifact accepted"
fi
grep -q 'authorization-artifact-expired' "$tmp/expired.err" || fail "expiry token missing"
cmp -s "$record" "$tmp/expired.before" || fail "expired artifact changed proposal"

# A downstream target-state change is not an idempotent retry.
vault="$tmp/go/vault"; topic=go__tool; record="$vault/45_ai-systems/self-growth/proposals/$topic.md"
reference=$(ruby -ryaml -e 'print YAML.load_file(ARGV[0]).dig("owner_confirmation","reference")' "$record")
sed -i '' 's/^state: ADOPTING$/state: ADOPTED/' "$record"
cp "$record" "$tmp/target.before"
if "$approve" --vault "$vault" --topic "$topic" --authorization-ref "$reference" \
  --backup-ref "backup; literal=1" --effect-metric "latency p95 -20%" --report-due "$report_due" \
  >"$tmp/target.out" 2>"$tmp/target.err"; then
  fail "changed target state accepted as retry"
fi
grep -q 'authorization-target-state-changed' "$tmp/target.err" || fail "target-state token missing"
cmp -s "$record" "$tmp/target.before" || fail "target-state refusal changed proposal"
sed -i '' 's/^state: ADOPTED$/state: ADOPTING/' "$record"

# Closed parent-shell parsing rejects duplicates, irrelevant flags, and missing
# decision inputs before any lock/write work.
new_case parse; topic=parse__tool; write_pending_t0 "$topic"
expect_usage_error approve-duplicate-topic "$record" 'duplicate option: --topic' \
  "$approve" --vault "$vault" --topic "$topic" --topic "$topic" --authorization-ref ref \
  --backup-ref backup --effect-metric metric --report-due "$report_due"
expect_usage_error approve-irrelevant-reason "$record" '--reason is irrelevant to GO' \
  "$approve" --vault "$vault" --topic "$topic" --authorization-ref ref --backup-ref backup \
  --effect-metric metric --report-due "$report_due" --reason nope
expect_usage_error approve-empty-irrelevant-reason "$record" '--reason is irrelevant to GO' \
  "$approve" --vault "$vault" --topic "$topic" --authorization-ref ref --backup-ref backup \
  --effect-metric metric --report-due "$report_due" --reason ''
expect_usage_error approve-missing-auth "$record" 'Usage: adopt-approve.sh' \
  "$approve" --vault "$vault" --topic "$topic" --backup-ref backup --effect-metric metric \
  --report-due "$report_due"
expect_usage_error reject-duplicate-auth "$record" 'duplicate option: --authorization-ref' \
  "$reject" --vault "$vault" --topic "$topic" --authorization-ref ref-a --authorization-ref ref-b \
  --reason nope
expect_usage_error reject-irrelevant-backup "$record" '--backup-ref is irrelevant to non-GO decisions' \
  "$reject" --vault "$vault" --topic "$topic" --authorization-ref ref --reason nope --backup-ref backup
expect_usage_error reject-empty-irrelevant-backup "$record" '--backup-ref is irrelevant to non-GO decisions' \
  "$reject" --vault "$vault" --topic "$topic" --authorization-ref ref --reason nope --backup-ref ''
expect_usage_error reject-empty-irrelevant-effect-metric "$record" '--effect-metric is irrelevant to non-GO decisions' \
  "$reject" --vault "$vault" --topic "$topic" --authorization-ref ref --reason nope --effect-metric ''
expect_usage_error reject-empty-irrelevant-report-due "$record" '--report-due is irrelevant to non-GO decisions' \
  "$reject" --vault "$vault" --topic "$topic" --authorization-ref ref --reason nope --report-due ''
expect_usage_error reject-missing-reason "$record" 'Usage: adopt-reject.sh' \
  "$reject" --vault "$vault" --topic "$topic" --authorization-ref ref
expect_usage_error watch-duplicate-now "$record" 'duplicate option: --now' \
  "$watch" --vault "$vault" --topic "$topic" --authorization-ref ref --reason nope \
  --now 2026-07-25T00:00:00Z --now 2026-07-25T00:00:01Z
expect_usage_error watch-irrelevant-report-due "$record" '--report-due is irrelevant to non-GO decisions' \
  "$watch" --vault "$vault" --topic "$topic" --authorization-ref ref --reason nope \
  --report-due "$report_due"
expect_usage_error watch-empty-irrelevant-backup "$record" '--backup-ref is irrelevant to non-GO decisions' \
  "$watch" --vault "$vault" --topic "$topic" --authorization-ref ref --reason nope --backup-ref ''
expect_usage_error watch-empty-irrelevant-effect-metric "$record" '--effect-metric is irrelevant to non-GO decisions' \
  "$watch" --vault "$vault" --topic "$topic" --authorization-ref ref --reason nope --effect-metric ''
expect_usage_error watch-empty-irrelevant-report-due "$record" '--report-due is irrelevant to non-GO decisions' \
  "$watch" --vault "$vault" --topic "$topic" --authorization-ref ref --reason nope --report-due ''
expect_usage_error watch-missing-auth "$record" 'Usage: adopt-watch.sh' \
  "$watch" --vault "$vault" --topic "$topic" --reason nope

# Abort/rollback on v2 records keeps the verified owner_confirmation block byte-identical.
new_case abort; topic=abort__tool; write_pending_t0 "$topic"
backup="backup-rollback"; metric="smoke rollback"; due=$report_due
reference=$(issue_artifact GO "$backup" "$metric" "$due" "")
"$approve" --vault "$vault" --topic "$topic" --authorization-ref "$reference" \
  --backup-ref "$backup" --effect-metric "$metric" --report-due "$due" >/dev/null || fail "abort fixture approve failed"
extract_owner_confirmation_block "$record" >"$tmp/abort.owner.before"
abort_now=$(state_time_offset "$record" 86400)
"$abort_cmd" --vault "$vault" --topic "$topic" --reason 'smoke regression' --now "$abort_now" >/dev/null || fail "v2 abort failed"
assert_verified GO DLQ
grep -q '^state: DLQ$' "$record" || fail "v2 abort state missing"
grep -q 'rollback_required: git revert one commit; reason=smoke regression' "$record" || fail "v2 abort event missing"
extract_owner_confirmation_block "$record" >"$tmp/abort.owner.after"
cmp -s "$tmp/abort.owner.before" "$tmp/abort.owner.after" || fail "abort rewrote owner_confirmation bytes"
printf ok >"$tmp/rollback-proof.md"
rollback_now=$(state_time_offset "$record" 86400)
"$rollback_cmd" --vault "$vault" --topic "$topic" --evidence "$tmp/rollback-proof.md" --now "$rollback_now" >/dev/null || fail "v2 rollback failed"
assert_verified GO REJECTED
grep -q '^state: REJECTED$' "$record" || fail "v2 rollback state missing"
grep -q 'rollback verified' "$record" || fail "v2 rollback event missing"
extract_owner_confirmation_block "$record" >"$tmp/rollback.owner.after"
cmp -s "$tmp/abort.owner.before" "$tmp/rollback.owner.after" || fail "rollback rewrote owner_confirmation bytes"
expected_cooldown=$(ruby -rtime -e 'print (Time.iso8601(ARGV[0]) + (30 * 86400)).utc.strftime("%Y-%m-%d")' "$rollback_now")
ruby -ryaml -e 'exit(YAML.load_file(ARGV[0])["cooldown_until"].to_s.start_with?(ARGV[1]) ? 0 : 1)' "$record" "$expected_cooldown" >/dev/null || fail "v2 rollback cooldown missing"

# Completion regressions from the legacy path remain protected for v2 records.
new_case window; topic=window__tool; write_pending_t0 "$topic"
reference=$(issue_artifact GO "backup-window" "window metric" "$report_due" "")
"$approve" --vault "$vault" --topic "$topic" --authorization-ref "$reference" \
  --backup-ref "backup-window" --effect-metric "window metric" --report-due "$report_due" >/dev/null || fail "window approve failed"
cp "$record" "$tmp/window.before"
too_early=$(state_time_offset "$record" $((6 * 86400)))
if "$complete" --vault "$vault" --topic "$topic" --smoke-result "$tmp/rollback-proof.md" --now "$too_early" \
  >"$tmp/window.out" 2>"$tmp/window.err"; then
  fail "completion inside observation window accepted"
fi
grep -q 'record-damaged' "$tmp/window.err" || fail "observation window refusal missing"
cmp -s "$record" "$tmp/window.before" || fail "observation window refusal changed proposal"

new_case actor; topic=actor__tool; write_pending_t0 "$topic"
reference=$(issue_artifact GO "backup-actor" "actor metric" "$report_due" "")
"$approve" --vault "$vault" --topic "$topic" --authorization-ref "$reference" \
  --backup-ref "backup-actor" --effect-metric "actor metric" --report-due "$report_due" >/dev/null || fail "actor approve failed"
cp "$record" "$tmp/actor.before"
actor_now=$(state_time_offset "$record" $((8 * 86400)))
if "$complete" --vault "$vault" --topic "$topic" --smoke-result "$tmp/rollback-proof.md" --actor 'BAD SLUG' --now "$actor_now" \
  >"$tmp/actor.out" 2>"$tmp/actor.err"; then
  fail "invalid actor accepted"
fi
grep -q 'record-damaged' "$tmp/actor.err" || fail "invalid actor refusal missing"
cmp -s "$record" "$tmp/actor.before" || fail "invalid actor refusal changed proposal"

new_case conflict; topic=conflict__tool; write_pending_t0 "$topic"
reference=$(issue_artifact GO "backup-conflict" "conflict metric" "$report_due" "")
"$approve" --vault "$vault" --topic "$topic" --authorization-ref "$reference" \
  --backup-ref "backup-conflict" --effect-metric "conflict metric" --report-due "$report_due" >/dev/null || fail "conflict approve failed"
complete_now=$(state_time_offset "$record" $((8 * 86400)))
conflict_entry="$vault/30_decisions/${complete_now%%T*}-adoption-$topic.md"
mkdir -p "$(dirname "$conflict_entry")"
printf 'different content\n' >"$conflict_entry"
cp "$record" "$tmp/conflict.before"
if "$complete" --vault "$vault" --topic "$topic" --smoke-result "$tmp/rollback-proof.md" --now "$complete_now" \
  >"$tmp/conflict.out" 2>"$tmp/conflict.err"; then
  fail "different existing adoption record accepted"
fi
grep -q 'record-damaged' "$tmp/conflict.err" || fail "different existing adoption record refusal missing"
cmp -s "$record" "$tmp/conflict.before" || fail "different existing adoption record changed proposal"
grep -Fxq 'different content' "$conflict_entry" || fail "different existing adoption record was overwritten"

# Rollback completion is reserved for the most recent ADOPTING rollback DLQ.
new_case rollback-origin; topic=trial-origin__tool; write_pending_t0 "$topic"
reference=$(issue_artifact GO "backup-origin" "origin metric" "$report_due" "")
"$approve" --vault "$vault" --topic "$topic" --authorization-ref "$reference" \
  --backup-ref "backup-origin" --effect-metric "origin metric" --report-due "$report_due" >/dev/null || fail "origin approve failed"
set_record_field "$record" state DLQ
set_record_field "$record" state_entered_at 2026-07-22T00:00:00Z
set_record_field "$record" updated 2026-07-22
printf '%s\n' '- 2026-07-22T00:00:00Z alpha TRIALING→DLQ — non-adoption failure' >>"$record"
if "$rollback_cmd" --vault "$vault" --topic "$topic" --evidence "$tmp/rollback-proof.md" --now 2026-07-23T00:00:00Z \
  >"$tmp/trial-origin.out" 2>"$tmp/trial-origin.err"; then
  fail "rollback from TRIALING DLQ accepted"
fi
grep -q 'record-damaged' "$tmp/trial-origin.err" || fail "trial-origin refusal missing"

new_case rollback-origin-council; topic=council-origin__tool; write_pending_t0 "$topic"
reference=$(issue_artifact GO "backup-origin" "origin metric" "$report_due" "")
"$approve" --vault "$vault" --topic "$topic" --authorization-ref "$reference" \
  --backup-ref "backup-origin" --effect-metric "origin metric" --report-due "$report_due" >/dev/null || fail "council origin approve failed"
set_record_field "$record" state DLQ
set_record_field "$record" state_entered_at 2026-07-22T00:00:00Z
set_record_field "$record" updated 2026-07-22
printf '%s\n' '- 2026-07-22T00:00:00Z alpha COUNCIL→DLQ — non-adoption failure' >>"$record"
if "$rollback_cmd" --vault "$vault" --topic "$topic" --evidence "$tmp/rollback-proof.md" --now 2026-07-23T00:00:00Z \
  >"$tmp/council-origin.out" 2>"$tmp/council-origin.err"; then
  fail "rollback from COUNCIL DLQ accepted"
fi
grep -q 'record-damaged' "$tmp/council-origin.err" || fail "council-origin refusal missing"

new_case rollback-origin-history; topic=historical__tool; write_pending_t0 "$topic"
reference=$(issue_artifact GO "backup-history" "history metric" "$report_due" "")
"$approve" --vault "$vault" --topic "$topic" --authorization-ref "$reference" \
  --backup-ref "backup-history" --effect-metric "history metric" --report-due "$report_due" >/dev/null || fail "historical approve failed"
set_record_field "$record" state DLQ
set_record_field "$record" state_entered_at 2026-07-22T00:00:00Z
set_record_field "$record" updated 2026-07-22
printf '%s\n' \
  '- 2026-07-18T00:00:00Z alpha ADOPTING→DLQ — rollback_required: revert' \
  '- 2026-07-19T00:00:00Z alpha DLQ→TRIALING — retry approved' \
  '- 2026-07-20T00:00:00Z alpha TRIALING→DLQ — trial failed' \
  >>"$record"
if "$rollback_cmd" --vault "$vault" --topic "$topic" --evidence "$tmp/rollback-proof.md" --now 2026-07-23T00:00:00Z \
  >"$tmp/history-origin.out" 2>"$tmp/history-origin.err"; then
  fail "historical rollback bypass accepted"
fi
grep -q 'record-damaged' "$tmp/history-origin.err" || fail "historical-origin refusal missing"

# Completion adds the exact owner block between the baseline headings and is
# byte-identical on retry.
vault="$tmp/go/vault"; topic=go__tool; record="$vault/45_ai-systems/self-growth/proposals/$topic.md"
# The hardened consume worker verifies authorization against receipt time, so
# freeze the scenario's observation-window fixture independently of wall clock.
set_record_field "$record" state_entered_at 2026-07-21T00:00:00Z
printf smoke >"$tmp/smoke.md"
external_decisions="$tmp/external-decisions"
mkdir "$external_decisions"
ln -s "$external_decisions" "$vault/30_decisions"
cp "$record" "$tmp/symlink-parent.before"
if "$complete" --vault "$vault" --topic "$topic" --smoke-result "$tmp/smoke.md" \
  --where "alpha runtime" --now 2026-08-10T00:00:00Z >"$tmp/symlink-parent.out" 2>"$tmp/symlink-parent.err"; then
  fail "symlinked adoption-record parent accepted"
fi
cmp -s "$record" "$tmp/symlink-parent.before" || fail "symlinked adoption-record parent changed proposal"
[ -z "$(find "$external_decisions" -mindepth 1 -print -quit)" ] || fail "symlink target was modified"
ruby -ryaml -e 'abort unless YAML.load_file(ARGV[0]).dig("links","adoption_entry").to_s.empty?' "$record" || fail "symlink refusal persisted adoption entry"
[ -L "$vault/30_decisions" ] || fail "symlink parent was replaced or removed"
rm "$vault/30_decisions"

"$complete" --vault "$vault" --topic "$topic" --smoke-result "$tmp/smoke.md" \
  --where "alpha runtime" --now 2026-08-10T00:00:00Z >/dev/null || fail "completion failed"
entry="$vault/30_decisions/2026-08-10-adoption-$topic.md"
[ -s "$entry" ] || fail "adoption record missing"
ruby - "$entry" "$record" <<'RUBY' || fail "owner confirmation adoption block invalid"
entry, proposal = ARGV
text = File.binread(entry)
abort unless text.scan(/^## Decision basis\n/).length == 1
abort unless text.scan(/^## Owner confirmation\n/).length == 1
abort unless text.scan(/^## Observation contract\n/).length == 1
a = text.index("## Decision basis\n")
b = text.index("## Owner confirmation\n")
c = text.index("## Observation contract\n")
abort unless a < b && b < c
section = text.byteslice(b, c - b)
abort unless /\A## Owner confirmation\n\n- Status: verified\n- Assurance: standard\n- Reference: .+\n- Proposal digest: sha256:[0-9a-f]{64}\n- Decision: GO\n- Principal: sho\n- Verified at: [0-9TZ:-]+\n\n\z/.match?(section)
RUBY
cp "$entry" "$tmp/entry.before"
cp "$record" "$tmp/complete.before"
"$complete" --vault "$vault" --topic "$topic" --smoke-result "$tmp/smoke.md" \
  --where "alpha runtime" --now 2026-08-10T00:00:00Z >/dev/null || fail "completion retry failed"
cmp -s "$entry" "$tmp/entry.before" || fail "completion retry changed adoption record"
cmp -s "$record" "$tmp/complete.before" || fail "completion retry changed proposal"

# The removed owner-label bypass remains a usage error with no write.
if "$complete" --vault "$vault" --topic "$topic" --smoke-result "$tmp/smoke.md" \
  --early-authorized-by sho --now 2026-08-10T00:00:00Z >/dev/null 2>"$tmp/early.err"; then
  fail "removed early authorization option accepted"
fi
grep -q 'no longer supported' "$tmp/early.err" || fail "early authorization refusal missing"

echo "test-adopt.sh: PASS"
