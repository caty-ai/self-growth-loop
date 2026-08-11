#!/usr/bin/env bash
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
convene="$root/scripts/council-convene.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-council-convene.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fail() { echo "test-council-convene.sh: $*" >&2; exit 1; }

files='run.log env-manifest.txt config-diff.txt permissions.md cost.txt attempts.md repro.md rollback-test.md'
now=2026-07-21T12:00:00Z

new_case() {
  case_root="$tmp/$1"; case_vault="$case_root/vault"; case_workspace="$case_root/workspace"
  case_ledger="$case_vault/45_ai-systems/self-growth/proposals"
  mkdir -p "$case_ledger" "$case_workspace"
}

write_record() {
  topic=$1 risk=$2 identity=$3 executor=$4
  task="sgl-trial-$topic-20260720t120000"
  cat >"$case_ledger/$topic.md" <<EOF
---
schema: sgl-proposal/v2
topic_key: $topic
title: "Trial $topic"
state: COUNCIL
state_entered_at: 2026-07-20T00:00:00Z
risk_tier: $risk
identity_critical: $identity
tiebreak: T0
proposer: mine
executor_agent: alpha
executor_model: "$executor"
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
reversibility: "rollback = remove scratch directory, <10 min, no data loss"
---

## Judgement

Fixture judgement.

## Events (append-only)

EOF
  bundle="$case_workspace/loop/artifacts/$task/out/bundle"
  mkdir -p "$bundle" "$case_vault/45_ai-systems/self-growth/trial-packets" "$case_vault/45_ai-systems/self-growth/council/$topic"
  for f in $files; do printf 'fixture %s\n' "$f" >"$bundle/$f"; done
  printf '# Packet\n\nPromised result.\n' >"$case_vault/45_ai-systems/self-growth/trial-packets/$task.md"
}

invoke() {
  bash "$convene" --vault "$case_vault" --topic "$1" --workspace "$case_workspace" --now "${2:-$now}" "${@:3}"
}

unchanged_refusal() {
  label=$1 topic=$2; shift 2
  before=$(shasum "$case_ledger/$topic.md")
  if invoke "$topic" "$now" "$@" >"$tmp/$label.out" 2>"$tmp/$label.err"; then fail "$label was accepted"; fi
  [ "$before" = "$(shasum "$case_ledger/$topic.md")" ] || fail "$label changed record"
  grep -q "$label" /dev/null 2>/dev/null || true
}

# A normal panel freezes all evidence and changes only the permitted ledger keys.
new_case happy; topic=happy__vendor; write_record "$topic" T1 false gpt-5
cp "$case_ledger/$topic.md" "$tmp/happy.before"
invoke "$topic" >"$tmp/happy.out" || fail "happy convene failed"
cdir="$case_vault/45_ai-systems/self-growth/council/$topic"
[ "$(find "$cdir" -type f | wc -l | tr -d ' ')" -eq 4 ] || fail "expected manifest plus three briefs"
manifest="$cdir/$task.convene.yaml"
ruby -ryaml -rdigest -e '
 m=YAML.load_file(ARGV.shift); abort unless m["schema"]=="sgl-council-convene/v1" && m["seats"].size==3
 abort unless m["seats"].map{|s|s["evaluator_family"]}.uniq.size==3
 abort unless m["seats"].all?{|s|s["deadline"]=="2026-07-22T12:00:00Z"}; abort unless m["digests"]["bundle"].size==8 && m["digests"]["packet"]
 m["digests"]["bundle"].each{|n,d| abort unless Digest::SHA256.file(File.join(ARGV[1],n)).hexdigest==d}; abort unless Digest::SHA256.file(ARGV[2]).hexdigest==m["digests"]["packet"]
 m["seats"].each{|s| abort unless Digest::SHA256.file(File.join(ARGV[0],s["brief"])).hexdigest==s["brief_digest"] }
' "$manifest" "$cdir" "$case_workspace/loop/artifacts/$task/out/bundle" "$case_vault/45_ai-systems/self-growth/trial-packets/$task.md" || fail "manifest content/digests invalid"
for lens in utility cost security; do grep -q 'BEGIN UNTRUSTED-DATA' "$cdir/$task.$lens.a1.brief.md" || fail "missing untrusted delimiters"; done
grep -q 'does what the packet promised' "$cdir/$task.utility.a1.brief.md" || fail "utility charter absent"
grep -q 'complexity budget' "$cdir/$task.cost.a1.brief.md" || fail "cost charter absent"
grep -q 'secrets hygiene' "$cdir/$task.security.a1.brief.md" || fail "security charter absent"
ruby -e '
 a=File.readlines(ARGV[0]); b=File.readlines(ARGV[1]); keep=/^(updated:|  council_verdicts:|$)/
 a=a.reject{|x|keep===x || x.start_with?("- 2026-07-21T12:00:00Z alpha EVENT")}; b=b.reject{|x|keep===x}; abort unless a==b
' "$case_ledger/$topic.md" "$tmp/happy.before" || fail "unrelated record bytes changed"
grep -q '^  council_verdicts: "council/happy__vendor/"$' "$case_ledger/$topic.md" || fail "council link missing"
grep -q 'COUNCIL convened' "$case_ledger/$topic.md" || fail "convene event missing"

# F3: a round is create-only; re-convening cannot replace frozen authority.
manifest_before=$(shasum "$manifest")
if invoke "$topic" >"$tmp/reconvene.out" 2>"$tmp/reconvene.err"; then fail "re-convene accepted"; fi
grep -q ROUND_EXISTS "$tmp/reconvene.err" || fail "re-convene did not report ROUND_EXISTS"
[ "$manifest_before" = "$(shasum "$manifest")" ] || fail "re-convene changed manifest"

# A malformed historical sibling is visible but cannot block a new round.
new_case damaged_sibling; topic=damaged__vendor; write_record "$topic" T1 false gpt-5
damaged_dir="$case_vault/45_ai-systems/self-growth/council/$topic"
printf 'not: [valid\n' >"$damaged_dir/sgl-trial-$topic-20260719t000000.convene.yaml"
invoke "$topic" >"$case_root/out" 2>"$case_root/err" || fail "damaged sibling blocked convene"
grep -q 'WARNING: skipped damaged sibling manifest' "$case_root/err" || fail "damaged sibling warning absent"
[ -s "$damaged_dir/$task.violations.md" ] || fail "damaged sibling audit absent"
grep -q MANIFEST_SKIPPED "$damaged_dir/$task.violations.md" || fail "damaged sibling audit code absent"
[ -s "$damaged_dir/$task.convene.yaml" ] || fail "current manifest absent after damaged sibling"

# A semantically damaged sibling that claims to be active is not selection authority.
new_case damaged_active; topic=damagedactive__vendor; write_record "$topic" T1 false gpt-5
damaged_dir="$case_vault/45_ai-systems/self-growth/council/$topic"
other=sgl-trial-$topic-20260719t000000
cat >"$damaged_dir/$other.convene.yaml" <<EOF
schema: sgl-council-convene/v1
topic_key: $topic
task_id: $other
sealed: "false"
EOF
invoke "$topic" >"$case_root/out" 2>"$case_root/err" || fail "damaged active sibling blocked convene"
grep -q 'MANIFEST_SKIPPED.*sealed must be boolean' "$case_root/err" || fail "damaged active warning absent"
grep -q MANIFEST_SKIPPED "$damaged_dir/$task.violations.md" || fail "damaged active audit absent"

# Ruby-backed paths remain operational under a minimal C locale.
new_case locale; topic=locale__vendor; write_record "$topic" T1 false gpt-5
LC_ALL=C LANG=C invoke "$topic" >"$case_root/out" || fail "LC_ALL=C convene failed"
[ -s "$case_vault/45_ai-systems/self-growth/council/$topic/$task.convene.yaml" ] || fail "locale manifest absent"

# T0 skips the panel but still requires Sho; identity-critical T0 is damaged.
new_case t0; topic=tzero__vendor; write_record "$topic" T0 false gpt-5
invoke "$topic" || fail "T0 fast path failed"
grep -q '^state: PENDING_SHO$' "$case_ledger/$topic.md" || fail "T0 did not advance"
t0_artifact="$case_vault/45_ai-systems/self-growth/council/$topic/$task.t0-skip.md"
[ -s "$t0_artifact" ] || fail "T0 note missing"
ruby -rdigest -e '
  artifact, packet, bundle, topic, task = ARGV
  packet_digest = Digest::SHA256.file(packet).hexdigest
  names = %w[attempts.md config-diff.txt cost.txt env-manifest.txt permissions.md repro.md rollback-test.md run.log]
  serialized = names.sort.map { |name| "#{name}=#{Digest::SHA256.file(File.join(bundle, name)).hexdigest}\n" }.join
  expected = [
    "sgl-t0-skip/v1",
    "sealed: true",
    "topic-key: #{topic}",
    "task-id: #{task}",
    "trial-reference: loop/artifacts/#{task}/",
    "packet-sha256: #{packet_digest}",
    "bundle-map-sha256: #{Digest::SHA256.hexdigest(serialized)}",
    "marker: auto-adopt path (T0), council skipped",
    "",
  ].join("\n")
  abort unless File.binread(artifact) == expected
' "$t0_artifact" "$case_vault/45_ai-systems/self-growth/trial-packets/$task.md" "$case_workspace/loop/artifacts/$task/out/bundle" "$topic" "$task" || fail "T0 sealed bytes are not exact"
cp "$t0_artifact" "$tmp/t0.sealed"
printf 'post-seal workspace drift\n' >"$case_workspace/loop/artifacts/$task/out/bundle/run.log"
cmp -s "$t0_artifact" "$tmp/t0.sealed" || fail "live workspace drift changed sealed T0 evidence"
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
' "$case_ledger/$topic.md" || fail "T0 fast path did not increment/reset owner confirmation"

# T0 artifact publication refuses symlinked parents.
new_case t0_symlink_parent; topic=t0symlink__vendor; write_record "$topic" T0 false gpt-5
real_topic_dir="$case_root/real-council-topic"
mkdir -p "$real_topic_dir"
rm -rf "$case_vault/45_ai-systems/self-growth/council/$topic"
ln -s "$real_topic_dir" "$case_vault/45_ai-systems/self-growth/council/$topic"
before=$(shasum "$case_ledger/$topic.md")
if invoke "$topic" >"$case_root/out" 2>"$case_root/err"; then fail "symlinked T0 parent accepted"; fi
[ "$before" = "$(shasum "$case_ledger/$topic.md")" ] || fail "symlinked T0 parent changed record"
grep -Eq 't0-evidence-symlink|symlink' "$case_root/err" || fail "symlinked T0 parent refusal was not explicit"

# T0 artifact publication refuses stale temp debris instead of overwriting it.
new_case t0_stale_temp; topic=t0stale__vendor; write_record "$topic" T0 false gpt-5
t0_dir="$case_vault/45_ai-systems/self-growth/council/$topic"
printf 'stale\n' >"$t0_dir/.$task.t0-skip.md.tmp.leftover"
before=$(shasum "$case_ledger/$topic.md")
if invoke "$topic" >"$case_root/out" 2>"$case_root/err"; then fail "stale T0 temp accepted"; fi
[ "$before" = "$(shasum "$case_ledger/$topic.md")" ] || fail "stale T0 temp changed record"
grep -q 'stale-t0-evidence-temp' "$case_root/err" || fail "stale T0 temp refusal token missing"

new_case t0bad; topic=tbad__vendor; write_record "$topic" T0 true gpt-5; before=$(shasum "$case_ledger/$topic.md")
if invoke "$topic" >"$tmp/t0bad.out" 2>"$tmp/t0bad.err"; then fail "identity-critical T0 accepted"; fi
[ "$before" = "$(shasum "$case_ledger/$topic.md")" ] || fail "bad T0 transitioned"
grep -q IDENTITY_CRITICAL_TIER_INVALID "$case_vault/45_ai-systems/self-growth/council/$topic/$task.violations.md" || fail "bad T0 violation absent"

# A pre-existing differing T0 artifact is fail-closed and leaves the record intact.
new_case t0_mismatch; topic=t0mismatch__vendor; write_record "$topic" T0 false gpt-5
printf 'pre-existing conflicting artifact\n' >"$case_vault/45_ai-systems/self-growth/council/$topic/$task.t0-skip.md"
before=$(shasum "$case_ledger/$topic.md")
if invoke "$topic" >"$tmp/t0-mismatch.out" 2>"$tmp/t0-mismatch.err"; then fail "T0 evidence mismatch accepted"; fi
[ "$before" = "$(shasum "$case_ledger/$topic.md")" ] || fail "T0 evidence mismatch changed record"
grep -Eqi 't0|digest|mismatch|violation|conflict|artifact' "$tmp/t0-mismatch.err" "$case_vault/45_ai-systems/self-growth/council/$topic/$task.violations.md" || fail "T0 evidence mismatch was not made visible"

# Refusals leave the ledger byte-for-byte intact and make a visible violation.
for kind in empty seat bundle; do
  new_case "ref-$kind"; topic="ref$kind"__vendor; write_record "$topic" T1 false gpt-5
  case $kind in
    empty) sed -i '' 's/executor_model: "gpt-5"/executor_model: ""/' "$case_ledger/$topic.md"; code=EXECUTOR_IDENTITY_UNRESOLVED; args='' ;;
    seat) code=SEAT_EQUALS_EXECUTOR; args='--seat security=gpt-5' ;;
    bundle) rm "$case_workspace/loop/artifacts/$task/out/bundle/run.log"; code=BUNDLE_INCOMPLETE; args='' ;;
  esac
  before=$(shasum "$case_ledger/$topic.md")
  # shellcheck disable=SC2086 # args intentionally expands to zero or multiple argv
  if invoke "$topic" "$now" $args >"$tmp/ref-$kind.out" 2>"$tmp/ref-$kind.err"; then fail "$kind refusal accepted"; fi
  [ "$before" = "$(shasum "$case_ledger/$topic.md")" ] || fail "$kind refusal changed record"
  grep -q "$code" "$case_vault/45_ai-systems/self-growth/council/$topic/$task.violations.md" || fail "$kind violation missing"
done

new_case dry; topic=dry__vendor; write_record "$topic" T1 false gpt-5; cp -R "$case_root" "$tmp/dry.before"
invoke "$topic" "$now" --dry-run >"$tmp/dry.out" || fail "dry run failed"
diff -r "$case_root" "$tmp/dry.before" >/dev/null || fail "dry run changed filesystem"

# Fallback first consumes an unused family, then reuses an active other-lens family only when all are used.
new_case fallback; topic=fallback__vendor; write_record "$topic" T1 false fugu-1
invoke "$topic" || fail "fallback setup failed"
later=2026-07-22T13:00:00Z
invoke "$topic" "$later" --fallback utility=kimi-k3 || fail "unused-family fallback failed"
ruby -ryaml -e 'm=YAML.load_file(ARGV[0]); abort unless m["seats"].find{|s|s["seat"]=="utility-a1"}["status"]=="timed_out"; abort unless m["seats"].any?{|s|s["seat"]=="utility-a2" && s["evaluator_family"]=="kimi"}' "$case_vault/45_ai-systems/self-growth/council/$topic/$task.convene.yaml" || fail "fallback manifest wrong"
for model in codex-x fugu-x; do
  before=$(shasum "$case_ledger/$topic.md")
  if invoke "$topic" "$later" --fallback cost="$model" >"$tmp/fb-$model.out" 2>"$tmp/fb-$model.err"; then fail "ineligible fallback accepted: $model"; fi
  [ "$before" = "$(shasum "$case_ledger/$topic.md")" ] || fail "fallback refusal changed record"
done
invoke "$topic" "$later" --fallback cost=claude-sonnet || fail "reuse fallback failed"
ruby -ryaml -e 'm=YAML.load_file(ARGV[0]); abort unless m["correlated_panel"] && m["correlated_reason"].include?("fallback reuse") && m["seats"].any?{|s|s["seat"]=="cost-a2" && s["evaluator_family"]=="claude"}' "$case_vault/45_ai-systems/self-growth/council/$topic/$task.convene.yaml" || fail "reuse was not stamped correlated"

# F7: a resolved seat cannot be replaced through fallback.
new_case resolved_fallback; topic=resolved__vendor; write_record "$topic" T1 false fugu-1
invoke "$topic" || fail "resolved fallback setup failed"
cat >"$case_vault/45_ai-systems/self-growth/council/$topic/$task.utility.a1.verdict.md" <<EOF
---
task_id: $task
lens: utility
seat: utility-a1
verdict: GO
---
VERDICT: GO
EOF
before=$(shasum "$case_vault/45_ai-systems/self-growth/council/$topic/$task.convene.yaml")
if invoke "$topic" "$later" --fallback utility=kimi-k3 >"$tmp/resolved.out" 2>"$tmp/resolved.err"; then fail "resolved fallback accepted"; fi
grep -q FALLBACK_INELIGIBLE "$tmp/resolved.err" || fail "resolved fallback code absent"
[ "$before" = "$(shasum "$case_vault/45_ai-systems/self-growth/council/$topic/$task.convene.yaml")" ] || fail "resolved fallback changed manifest"

echo "test-council-convene.sh: PASS"
