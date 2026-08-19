#!/usr/bin/env bash
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-adopt-integration.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fail() { echo "test-adopt-integration.sh: $*" >&2; exit 1; }

future_due_utc() {
  ruby -e 'now = Time.now.utc; print(Time.utc(now.year + 1, now.month, now.day, now.hour, now.min, now.sec).strftime("%Y-%m-%dT%H:%M:%SZ"))'
}

report_due=$(future_due_utc) || fail "could not derive future report_due fixture"

vault="$tmp/vault"
ledger="$vault/45_ai-systems/self-growth/proposals"
topic=t0__tool
task=sgl-trial-t0__tool-20260720t000000
mkdir -p "$ledger" "$vault/45_ai-systems/self-growth/config" "$vault/45_ai-systems/self-growth/council/$topic"
printf '%s\n' \
  'schema: sgl-owner-config/v1' \
  'principal: sho' \
  'repository_id: caty-ai/self-growth-loop' \
  'default_assurance: standard' \
  >"$vault/45_ai-systems/self-growth/config/owner.yaml"
cat >"$ledger/$topic.md" <<EOF
---
schema: sgl-proposal/v2
topic_key: $topic
title: T0 サンプル採用
state: PENDING_OWNER
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
reversibility: "git revert one commit, <10 min, データ損失なし"
---

## Judgement

この試行は可逆な単一ランタイム変更でキューを改善します。

## Events (append-only)

- 2026-07-20T00:00:00Z alpha COUNCIL→PENDING_OWNER — auto-adopt path (T0), council skipped
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
printf '%s\n' '2026-07-21T00:00:00Z mine OK fixture' >"$vault/45_ai-systems/self-growth/sense-status.log"

bash "$root/scripts/growth-lint.sh" --vault "$vault" --now 2026-07-21T00:00:00Z >/dev/null || fail "initial lint failed"
queue="$vault/25_review-pending/self-growth-queue.md"
grep -Fq 'council skipped — T0 fast path' "$queue" || fail "T0 card missing"
grep -Fq 'git revert one commit, <10 min, データ損失なし' "$queue" || fail "rollback missing"
for decision in GO REJECT WATCH; do
  grep -Fq "$decision (NON-EXECUTABLE TEMPLATE): scripts/adopt-confirm.sh" "$queue" || fail "$decision confirmation template missing"
done

backup="snapshot O'Brien"
metric="queue review time"
due=$report_due
prompt=$(ruby - "$root" "$vault" "$topic" "$backup" "$metric" "$due" <<'RUBY'
repo, vault, topic, backup, metric, due = ARGV
require File.join(repo, "scripts/lib-owner-confirmation")
record = OwnerConfirmation.load_proposal_record(path: File.join(vault, "45_ai-systems/self-growth/proposals", "#{topic}.md"))
owner = OwnerConfirmation.load_owner_config(vault_root: vault)
evidence = OwnerConfirmation.derive_t0_evidence(vault_root: vault, workspace_root: nil, record: record)
snapshot = OwnerConfirmation.build_decision_snapshot(
  record: record, owner_config: owner, decision: "GO",
  issued_inputs: {"backup_ref" => backup, "effect_metric" => metric, "report_due" => due},
  evidence: evidence
)
puts "CONFIRM GO #{topic} 1 #{OwnerConfirmation.sha256_hex(snapshot)[0, 12]}"
RUBY
) || fail "prompt derivation failed"

EXPECT_CONFIRM=$prompt EXPECT_BIN="$root/scripts/adopt-confirm.sh" EXPECT_VAULT=$vault EXPECT_TOPIC=$topic \
  EXPECT_BACKUP=$backup EXPECT_METRIC=$metric EXPECT_DUE=$due expect <<'EXPECT' >"$tmp/issue.out" 2>&1 || fail "PTY confirmation failed"
set timeout 15
spawn $env(EXPECT_BIN) --vault $env(EXPECT_VAULT) --topic $env(EXPECT_TOPIC) --decision GO --backup-ref $env(EXPECT_BACKUP) --effect-metric $env(EXPECT_METRIC) --report-due $env(EXPECT_DUE)
expect -exact "$env(EXPECT_CONFIRM)\r\n"
send -- "$env(EXPECT_CONFIRM)\r"
expect eof
set result [wait]
exit [lindex $result 3]
EXPECT

 bash "$root/scripts/growth-lint.sh" --vault "$vault" --now 2026-07-26T00:00:00Z >/dev/null || fail "post-issuance lint failed"
grep -Fq 'CURRENT — supersedes any previously printed reference for this attempt' "$queue" || fail "current reference label missing"

consume_command=$(sed -n 's/^Consume command: //p' "$tmp/issue.out" | tail -n 1 | tr -d '\r')
[ -n "$consume_command" ] || fail "executable consume command missing"
eval "$consume_command" >/dev/null || fail "rendered consume command failed"
ruby -ryaml -e '
  d=YAML.load_file(ARGV[0])
  abort unless d["state"]=="ADOPTING"
  abort unless d["backup_ref"]==ARGV[1] && d["effect_metric"]==ARGV[2] && d["report_due"]==ARGV[3]
  abort unless d.dig("owner_confirmation","decision")=="GO"
' "$ledger/$topic.md" "$backup" "$metric" "$due" || fail "consume fields did not round-trip"

# Receipt time remains security-sampled by the consume worker; pin only this
# fixture's observation-window start before exercising the frozen completion time.
sed -i '' 's/^state_entered_at: .*/state_entered_at: 2026-07-21T00:00:00Z/' "$ledger/$topic.md"
printf smoke >"$tmp/smoke"
bash "$root/scripts/adopt-complete.sh" --vault "$vault" --topic "$topic" \
  --smoke-result "$tmp/smoke" --now 2026-08-10T00:00:00Z >/dev/null || fail "complete after window failed"
ruby -ryaml -e '
  d=YAML.load_file(ARGV[0])
  abort unless d["state"]=="ADOPTED" && !d.dig("links","adoption_entry").to_s.empty?
  abort unless d.dig("owner_confirmation","status")=="verified"
' "$ledger/$topic.md" || fail "adoption fields missing"
entry="$vault/30_decisions/2026-08-10-adoption-$topic.md"
if [ ! -s "$entry" ] || grep -q '{{' "$entry"; then
  fail "adoption record invalid"
fi
grep -q '^## Owner confirmation$' "$entry" || fail "owner confirmation block missing"
bash "$root/scripts/growth-lint.sh" --vault "$vault" --now 2026-08-11T00:00:00Z >/dev/null || fail "post-completion lint rejected UTF-8 adoption evidence"
! grep -Fq "$topic: damaged adoption correlation" "$queue" || fail "post-completion lint marked UTF-8 adoption evidence damaged"

echo "test-adopt-integration.sh: PASS"
