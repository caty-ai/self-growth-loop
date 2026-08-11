#!/usr/bin/env bash
set -u
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
quorum="$root/scripts/council-quorum.sh"
convene="$root/scripts/council-convene.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-council-quorum.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fail() { echo "test-council-quorum.sh: $*" >&2; exit 1; }
files='run.log env-manifest.txt config-diff.txt permissions.md cost.txt attempts.md repro.md rollback-test.md'
now=2026-07-21T12:00:00Z
new_case() {
  case_root="$tmp/$1"; vault="$case_root/vault"; workspace="$case_root/workspace"; topic=tool__vendor
  task=sgl-trial-tool__vendor-20260720t000000; ledger="$vault/45_ai-systems/self-growth/proposals"; council="$vault/45_ai-systems/self-growth/council/$topic"; bundle="$workspace/loop/artifacts/$task/out/bundle"
  mkdir -p "$ledger" "$council" "$bundle" "$vault/45_ai-systems/self-growth/trial-packets"; for f in $files; do printf 'real %s\n' "$f" >"$bundle/$f"; done
  cat >"$ledger/$topic.md" <<EOF
---
schema: sgl-proposal/v2
topic_key: $topic
title: 'x' # keep this exact byte
state: COUNCIL
state_entered_at: "2026-07-20T00:00:00Z"
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
  council_verdicts: "council/$topic/"
  adoption_entry: ""
backup_ref: ""
effect_metric: ""
report_due: ""
reversibility: "git revert one commit"
---

## Judgement

Fixture judgement.

## Events (append-only)

EOF
  printf '# Trial packet\n\nFixture.\n' >"$vault/45_ai-systems/self-growth/trial-packets/$task.md"
  "$convene" --vault "$vault" --topic "$topic" --workspace "$workspace" --now 2026-07-20T12:00:00Z >/dev/null || fail "manifest fixture convene failed"
}
verdict() { cat >"$council/$task.$1.a1.verdict${3:-}.md" <<EOF
---
task_id: $task
lens: $1
seat: $1-a1
verdict: $2
---
VERDICT: $2
## Reasons

Fixture.
## Bundle evidence

- file: run.log; observation: real evidence
## Dissent / reservations

None
EOF
}
invoke() { "$quorum" --vault "$vault" --topic "$topic" --workspace "$workspace" --now "$now" "$@"; }

new_case row1; verdict utility GO; verdict cost GO; verdict security NO-GO; cp "$ledger/$topic.md" "$case_root/before.md"
invoke --apply >"$case_root/out" || fail "row1 apply failed"
grep -q '^state: PENDING_SHO$' "$ledger/$topic.md" || fail "row1 no transition"; grep -q '^sealed: true$' "$council/$task.convene.yaml" || fail "row1 no seal"
ruby -ryaml -e '
  d = YAML.load_file(ARGV[0])
  abort unless d["schema"] == "sgl-proposal/v2"
  abort unless d["proposal_attempt"] == 1
  abort unless d["owner_confirmation"] == {
    "status" => "pending",
    "assurance" => "standard",
    "reference" => "",
    "proposal_digest" => "",
    "decision" => "",
    "principal" => "",
    "verified_at" => ""
  }
' "$ledger/$topic.md" || fail "COUNCIL→PENDING_SHO did not reset owner confirmation"

new_case repair; verdict utility GO; verdict cost GO; verdict security GO
cp "$ledger/$topic.md" "$case_root/pre-apply.md"
invoke --apply >"$case_root/seed.out" || fail "repair seed apply failed"
cp "$case_root/pre-apply.md" "$ledger/$topic.md"
invoke >"$case_root/out" || fail "repair invocation failed"
grep -q '^REPAIRED GO$' "$case_root/out" || fail "repair not reported"
grep -q '^state: PENDING_SHO$' "$ledger/$topic.md" || fail "repair did not transition"
grep -q '^proposal_attempt: 1$' "$ledger/$topic.md" || fail "repair did not restore attempt identity"

new_case repair_legacy_override; verdict utility GO; verdict cost GO; verdict security GO
cp "$ledger/$topic.md" "$case_root/pre-apply.md"
invoke --apply >"$case_root/seed.out" || fail "legacy override seed apply failed"
cp "$case_root/pre-apply.md" "$ledger/$topic.md"
ruby -ryaml -e '
  path = ARGV[0]
  manifest = YAML.load_file(path)
  manifest["decision"] = "GO (Sho override of security veto)"
  manifest["decision_at"] = Time.utc(2026, 7, 20, 12, 0, 0)
  File.write(path, YAML.dump(manifest))
' "$council/$task.convene.yaml"
ruby -e '
  path = ARGV[0]
  raw = File.binread(path)
  raw.sub!(/^decision: .*\n/, "decision: GO (Sho override of security veto)\n")
  raw.sub!(/^decision_at: .*\n/, "decision_at: 2026-07-20T12:00:00Z\n")
  File.binwrite(path, raw)
' "$council/$task.quorum.md"
invoke >"$case_root/out" || fail "legacy override repair invocation failed"
grep -q '^REPAIRED GO (Sho override of security veto)$' "$case_root/out" || fail "legacy override repair not reported"
grep -q '^state: PENDING_SHO$' "$ledger/$topic.md" || fail "legacy override repair did not transition"
grep -Eq "^state_entered_at: '?2026-07-20T12:00:00Z'?\$" "$ledger/$topic.md" || fail "legacy override repair did not normalize timestamp"
grep -q '^proposal_attempt: 1$' "$ledger/$topic.md" || fail "legacy override repair did not restore attempt identity"

new_case badsup; verdict utility GO; verdict cost GO; verdict security NO-GO; printf 'not frontmatter\n' >"$council/$task.security.a1.verdict.2.md"
if invoke --apply >"$case_root/out" 2>"$case_root/err"; then fail "malformed supersession accepted"; fi
grep -q SUPERSESSION_INVALID "$case_root/err" || fail "missing supersession violation"; grep -q '^sealed: false$' "$council/$task.convene.yaml" || fail "bad supersession sealed"

new_case missing; rm "$council/$task.convene.yaml"
if invoke >"$case_root/out" 2>"$case_root/err"; then fail "missing current manifest accepted"; fi
grep -q MANIFEST_AMBIGUOUS "$case_root/err" || fail "missing manifest code absent"

new_case digest-drift; verdict utility GO; verdict cost GO; verdict security GO; cp "$ledger/$topic.md" "$case_root/before.md"; printf 'tampered\n' >"$bundle/run.log"
if invoke --apply >"$case_root/out" 2>"$case_root/err"; then fail "digest drift accepted"; fi
grep -q DIGEST_DRIFT "$case_root/err" || fail "digest drift violation absent"; cmp -s "$case_root/before.md" "$ledger/$topic.md" || fail "digest drift changed ledger"

new_case locale; verdict utility GO; verdict cost GO; verdict security GO
LC_ALL=C invoke --apply >"$case_root/out" || fail "LC_ALL=C quorum failed"; grep -q '^state: PENDING_SHO$' "$ledger/$topic.md" || fail "locale transition failed"

# A fresh attempt cannot reuse an occupied confirmation namespace.
new_case attempt_namespace; verdict utility GO; verdict cost GO; verdict security GO
mkdir -p "$vault/45_ai-systems/self-growth/confirmations/$topic"
printf occupied >"$vault/45_ai-systems/self-growth/confirmations/$topic/1"
cp "$ledger/$topic.md" "$case_root/before.md"
if invoke --apply >"$case_root/out" 2>"$case_root/err"; then fail "occupied attempt namespace accepted"; fi
grep -q 'attempt-namespace-occupied' "$case_root/err" || fail "attempt namespace token missing"
cmp -s "$ledger/$topic.md" "$case_root/before.md" || fail "attempt namespace conflict changed proposal"

# T2 uses the same sealed evidence contract and resets attempt identity.
new_case t2
sed -i '' 's/^risk_tier: T1$/risk_tier: T2/; s/^identity_critical: false$/identity_critical: true/' "$ledger/$topic.md"
verdict utility GO; verdict cost GO; verdict security GO
invoke --apply >"$case_root/out" || fail "T2 quorum apply failed"
grep -q '^proposal_attempt: 1$' "$ledger/$topic.md" || fail "T2 attempt reset missing"

# Repair validates both sealed files independently for type and 1 MiB limits.
for evidence_case in manifest_oversize manifest_symlink quorum_oversize quorum_symlink; do
  new_case "$evidence_case"; verdict utility GO; verdict cost GO; verdict security GO
  cp "$ledger/$topic.md" "$case_root/pre-apply.md"
  invoke --apply >"$case_root/seed.out" || fail "$evidence_case seed apply failed"
  cp "$case_root/pre-apply.md" "$ledger/$topic.md"
  case "$evidence_case" in
    manifest_oversize)
      ruby -e 'File.open(ARGV[0],"ab"){|f| f.write("x" * 1_048_577)}' "$council/$task.convene.yaml"
      ;;
    manifest_symlink)
      mv "$council/$task.convene.yaml" "$case_root/manifest.real"
      ln -s "$case_root/manifest.real" "$council/$task.convene.yaml"
      ;;
    quorum_oversize)
      ruby -e 'File.open(ARGV[0],"ab"){|f| f.write("x" * 1_048_577)}' "$council/$task.quorum.md"
      ;;
    quorum_symlink)
      mv "$council/$task.quorum.md" "$case_root/quorum.real"
      ln -s "$case_root/quorum.real" "$council/$task.quorum.md"
      ;;
  esac
  cp "$ledger/$topic.md" "$case_root/before.md"
  if invoke >"$case_root/out" 2>"$case_root/err"; then fail "$evidence_case accepted"; fi
  grep -Eqi 'manifest|quorum|symlink|large|size|evidence|damaged' "$case_root/err" || fail "$evidence_case refusal was not explicit"
  cmp -s "$ledger/$topic.md" "$case_root/before.md" || fail "$evidence_case changed proposal"
done

# New unsigned Sho overrides are disabled; owner confirmation must be consumed
# through the dedicated authorization artifact flow instead.
new_case sho_override_disabled; verdict utility GO; verdict cost GO; verdict security GO; before=$(shasum "$ledger/$topic.md")
status=0
if invoke --apply --sho-override ref-123 >"$case_root/out" 2>"$case_root/err"; then
  fail "sho override accepted"
else
  status=$?
fi
[ "$before" = "$(shasum "$ledger/$topic.md")" ] || fail "sho override changed ledger"
[ "$status" -eq 2 ] || fail "sho override should exit 2"
grep -Eq 'override|OWNER|AUTH|disabled|INELIGIBLE' "$case_root/err" || fail "sho override refusal was not explicit"

new_case sho_override_empty; verdict utility GO; verdict cost GO; verdict security GO; before=$(shasum "$ledger/$topic.md")
status=0
if invoke --apply --sho-override '' >"$case_root/out" 2>"$case_root/err"; then
  fail "empty sho override accepted"
else
  status=$?
fi
[ "$before" = "$(shasum "$ledger/$topic.md")" ] || fail "empty sho override changed ledger"
[ "$status" -eq 2 ] || fail "empty sho override should exit 2"
grep -Eq 'override|OWNER|AUTH|disabled|INELIGIBLE' "$case_root/err" || fail "empty sho override refusal was not explicit"
echo "test-council-quorum.sh: PASS"
