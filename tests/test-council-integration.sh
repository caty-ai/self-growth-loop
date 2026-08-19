#!/usr/bin/env bash
set -u
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
convene="$root/scripts/council-convene.sh"; record="$root/scripts/council-record.sh"; quorum="$root/scripts/council-quorum.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-council-integration.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fail() { echo "test-council-integration.sh: $*" >&2; exit 1; }
files='run.log env-manifest.txt config-diff.txt permissions.md cost.txt attempts.md repro.md rollback-test.md'
now=2026-07-21T12:00:00Z; topic=tool__vendor; task=sgl-trial-tool__vendor-20260720t120000
vault="$tmp/vault"; workspace="$tmp/workspace"; ledger="$vault/45_ai-systems/self-growth/proposals"; council="$vault/45_ai-systems/self-growth/council/$topic"
bundle="$workspace/loop/artifacts/$task/out/bundle"
mkdir -p "$ledger" "$council" "$bundle" "$vault/45_ai-systems/self-growth/trial-packets"
for f in $files; do printf 'engine layout %s\n' "$f" >"$bundle/$f"; done
printf '# Frozen trial packet\n' >"$vault/45_ai-systems/self-growth/trial-packets/$task.md"
cat >"$ledger/$topic.md" <<EOF
---
schema: sgl-proposal/v2
topic_key: $topic
title: "統合カウンシル"
state: COUNCIL
state_entered_at: "2026-07-20T12:00:00Z"
risk_tier: T1
identity_critical: false
tiebreak: T0
proposer: mine
executor_agent: alpha
executor_model: fugu-runner
created: 2026-07-20
updated: 2026-07-20
cooldown_until: ""
retry_count: 0
proposal_attempt: 0
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

統合カウンシル経路は可逆な判断の準備ができています。

## Events (append-only)

EOF
bash "$convene" --vault "$vault" --topic "$topic" --workspace "$workspace" --now "$now" >"$tmp/convene.out" || fail "convene failed"
manifest="$council/$task.convene.yaml"; [ -s "$manifest" ] || fail "manifest missing"
ruby -ryaml -rdigest -e 'm=YAML.load_file(ARGV[0]); m["digests"]["bundle"].each{|n,d| abort n unless Digest::SHA256.file(File.join(ARGV[1],n)).hexdigest==d}' "$manifest" "$bundle" || fail "convene did not freeze real bundle bytes"
body() { cat >"$1" <<EOF
VERDICT: $2
## Reasons

統合レビュー票です。
## Bundle evidence

- file: run.log; observation: engine layout evidence
## Dissent / reservations

None
EOF
}
for lens in utility cost security; do body "$tmp/$lens.md" GO; bash "$record" --vault "$vault" --topic "$topic" --workspace "$workspace" --lens "$lens" --task-id "$task" --verdict-body "$tmp/$lens.md" --now "$now" >"$tmp/$lens.out" || fail "$lens record failed"; done
bash "$quorum" --vault "$vault" --topic "$topic" --workspace "$workspace" --apply --now "$now" >"$tmp/quorum.out" || fail "quorum apply failed"
grep -q '^state: PENDING_OWNER$' "$ledger/$topic.md" || fail "record did not reach PENDING_OWNER"
ruby -ryaml -e '
  d=YAML.load_file(ARGV[0])
  abort unless d["schema"]=="sgl-proposal/v2" && d["proposal_attempt"]==1
  abort unless d["owner_confirmation"]=={
    "status"=>"pending", "assurance"=>"standard", "reference"=>"",
    "proposal_digest"=>"", "decision"=>"", "principal"=>"", "verified_at"=>""
  }
' "$ledger/$topic.md" || fail "PENDING_OWNER attempt/reset mapping invalid"
REPO_ROOT="$root" VAULT_ROOT="$vault" RECORD_PATH="$ledger/$topic.md" ruby <<'RUBY' || fail "UTF-8 council evidence validation failed"
require File.join(ENV.fetch("REPO_ROOT"), "scripts/lib-owner-confirmation")
record = OwnerConfirmation.load_proposal_record(path: ENV.fetch("RECORD_PATH"))
evidence = OwnerConfirmation.derive_council_evidence(vault_root: ENV.fetch("VAULT_ROOT"), record: record)
abort unless evidence.fetch("quorum").fetch("schema") == "sgl-council-quorum/v1"
abort unless evidence.fetch("quorum").fetch("counted_attempt_ids") == %w[utility-a1 cost-a1 security-a1]
abort unless evidence.fetch("council_evidence_sha256").match?(/\A[0-9a-f]{64}\z/)
RUBY
grep -q '^sealed: true$' "$manifest" || fail "manifest not sealed"
ruby -ryaml -e 'l=File.readlines(ARGV[0]); i=l[1..].index { |x| x == "---\n" }; abort unless i; d=YAML.load(l[0..i+1].join); abort unless d["schema"]=="sgl-council-quorum/v1" && d["task_id"]==ARGV[1] && d["decision"]=="GO"' "$council/$task.quorum.md" "$task" || fail "GO quorum report invalid"
echo "test-council-integration.sh: PASS"
