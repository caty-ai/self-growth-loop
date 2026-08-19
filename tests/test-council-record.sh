#!/usr/bin/env bash
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
record="$root/scripts/council-record.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-council-record.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fail() { echo "test-council-record.sh: $*" >&2; exit 1; }
files='run.log env-manifest.txt config-diff.txt permissions.md cost.txt attempts.md repro.md rollback-test.md'
now=2026-07-21T12:00:00Z

new_case() {
  case_root="$tmp/$1"; vault="$case_root/vault"; workspace="$case_root/workspace"; topic=tool__vendor
  task=sgl-trial-tool__vendor-20260720t120000
  ledger="$vault/45_ai-systems/self-growth/proposals"; council="$vault/45_ai-systems/self-growth/council/$topic"
  bundle="$workspace/loop/artifacts/$task/out/bundle"
  mkdir -p "$ledger" "$council" "$bundle"
  for f in $files; do printf 'real %s\n' "$f" >"$bundle/$f"; done
  cat >"$ledger/$topic.md" <<EOF
---
topic_key: $topic
title: "Council fixture"
state: COUNCIL
state_entered_at: 2026-07-20T00:00:00Z
risk_tier: T2
identity_critical: false
executor_agent: alpha
executor_model: fugu-runner
created: 2026-07-20
updated: 2026-07-20
cooldown_until: ""
retry_count: 0
links:
  trial_bundle: "loop/artifacts/$task/"
  council_verdicts: "council/$topic/"
---

## Events (append-only)

EOF
  manifest
}
digest_lines() { for f in $files; do printf '    %s: %s\n' "$f" "$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV[0]).hexdigest' "$bundle/$f")"; done; }
manifest() {
  cat >"$council/$task.convene.yaml" <<EOF
schema: sgl-council-convene/v1
topic_key: $topic
task_id: $task
bundle: loop/artifacts/$task/
digests:
  bundle:
$(digest_lines)
seats:
  - seat: utility-a1
    lens: utility
    attempt: 1
    evaluator_model: glm-5
    evaluator_family: glm
    evaluator_vendor: zhipu
    deadline: "2026-07-22T00:00:00Z"
    status: seated
  - seat: cost-a1
    lens: cost
    attempt: 1
    evaluator_model: gpt-5
    evaluator_family: codex
    evaluator_vendor: openai
    deadline: "2026-07-22T00:00:00Z"
    status: seated
  - seat: security-a1
    lens: security
    attempt: 1
    evaluator_model: claude-4
    evaluator_family: claude
    evaluator_vendor: anthropic
    deadline: "2026-07-22T00:00:00Z"
    status: seated
sealed: false
EOF
}
body() { cat >"$1" <<EOF
VERDICT: $2
## Reasons

Fixture reasons.
## Bundle evidence

- file: run.log; observation: real evidence
## Dissent / reservations

None
EOF
  [ "$2" != RETRY ] || printf '\n## Retry instructions\n\nTry once more.\n' >>"$1"
}
invoke() { "$record" --vault "$vault" --topic "$topic" --lens "$1" --workspace "$workspace" --verdict-body "$2" --now "$now" "${@:3}"; }
refuse() {
  name=$1 code=$2 lens=$3 path=$4; shift 4
  before=$(find "$council" -type f -maxdepth 1 -exec shasum {} \; | sort)
  if invoke "$lens" "$path" "$@" >"$case_root/$name.out" 2>"$case_root/$name.err"; then fail "$name accepted"; fi
  grep -q "$code" "$case_root/$name.err" || fail "$name missing $code"
  after=$(find "$council" -type f -maxdepth 1 -exec shasum {} \; | sort)
  [ "$before" != "$after" ] || fail "$name did not write a violation"
}

new_case happy; body "$case_root/go.md" GO
invoke utility "$case_root/go.md" >"$case_root/out" || fail "happy record failed"
[ -s "$council/$task.utility.a1.verdict.md" ] || fail "verdict absent"

# NEW-3: the record happy path remains usable from a C-locale caller.
new_case c_locale; body "$case_root/go.md" GO
LC_ALL=C LANG=C invoke utility "$case_root/go.md" >"$case_root/out" || fail "C-locale record failed"
[ -s "$council/$task.utility.a1.verdict.md" ] || fail "C-locale verdict absent"

# NEW-1: a damaged sibling is visible but does not block the valid selected round.
new_case damaged_sibling; body "$case_root/go.md" GO
sibling=sgl-trial-tool__vendor-20260719t120000
printf 'not: [valid yaml\n' >"$council/$sibling.convene.yaml"
invoke utility "$case_root/go.md" >"$case_root/out" 2>"$case_root/err" || fail "damaged sibling blocked selected manifest"
grep -q "MANIFEST_SKIPPED.*$sibling.convene.yaml" "$case_root/err" || fail "damaged sibling warning absent"
grep -q MANIFEST_SKIPPED "$council/$sibling.violations.md" || fail "damaged sibling note absent"

# Semantic selection damage is skipped just like malformed YAML, including a
# sibling that would otherwise look like the active round.
new_case semantic_sibling; body "$case_root/go.md" GO
sibling=sgl-trial-tool__vendor-20260719t120000; cp "$council/$task.convene.yaml" "$council/$sibling.convene.yaml"
ruby -ryaml -e 'p=ARGV[0]; d=YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(p) : YAML.load_file(p); d["task_id"]="wrong"; File.write(p, YAML.dump(d))' "$council/$sibling.convene.yaml"
invoke utility "$case_root/go.md" >"$case_root/out" 2>"$case_root/err" || fail "semantic sibling blocked selected manifest"
grep -q 'MANIFEST_SKIPPED.*task_id does not equal filename' "$case_root/err" || fail "semantic sibling warning absent"
new_case string_sealed; body "$case_root/go.md" GO
sibling=sgl-trial-tool__vendor-20260719t120000; cp "$council/$task.convene.yaml" "$council/$sibling.convene.yaml"
ruby -ryaml -e 'p, id=ARGV; d=YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(p) : YAML.load_file(p); d["task_id"]=id; d["sealed"]="false"; File.write(p, YAML.dump(d))' "$council/$sibling.convene.yaml" "$sibling"
invoke utility "$case_root/go.md" >"$case_root/out" 2>"$case_root/err" || fail "string sealed sibling blocked selected manifest"
grep -q 'MANIFEST_SKIPPED.*sealed must be boolean' "$case_root/err" || fail "string sealed warning absent"

# NEW-2: with no active round, archive late delivery against the latest sealed decision.
new_case latest_sealed; body "$case_root/go.md" GO
sibling=sgl-trial-tool__vendor-20260721t120000
cp "$council/$task.convene.yaml" "$council/$sibling.convene.yaml"
ruby -ryaml -e '
  ARGV.take(2).each_with_index do |path, index|
    data = YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(path) : YAML.load_file(path)
    data["task_id"] = ARGV[2] if index == 1
    data["sealed"] = true
    data["decision_at"] = index.zero? ? "2026-07-20T12:00:00Z" : "2026-07-21T12:00:00Z"
    File.write(path, YAML.dump(data))
  end
' "$council/$task.convene.yaml" "$council/$sibling.convene.yaml" "$sibling"
cp "$ledger/$topic.md" "$case_root/ledger.before"
manifest_before=$(find "$council" -name '*.convene.yaml' -exec shasum {} \; | sort)
if invoke utility "$case_root/go.md" >"$case_root/out" 2>"$case_root/err"; then fail "all-sealed late delivery accepted"; fi
grep -q "LATE_DELIVERY.*attributed=latest-sealed task_id=$sibling" "$case_root/err" || fail "latest sealed attribution absent"
[ -s "$council/$sibling.utility.a1.late.md" ] || fail "latest sealed late archive absent"
[ ! -e "$council/$task.utility.a1.late.md" ] || fail "late archive used older sealed round"
cmp -s "$case_root/ledger.before" "$ledger/$topic.md" || fail "late delivery changed ledger"
[ "$manifest_before" = "$(find "$council" -name '*.convene.yaml' -exec shasum {} \; | sort)" ] || fail "late delivery changed manifests"
[ ! -e "$council/$sibling.utility.a1.verdict.md" ] || fail "late delivery wrote normal verdict"

# A sealed round is attributable only with a valid, non-future decision time.
for bad_time in missing invalid future; do
  new_case "sealed_$bad_time"; body "$case_root/go.md" GO
  ruby -ryaml -e 'p, kind = ARGV; d=YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(p) : YAML.load_file(p); d["sealed"]=true; d["decision_at"] = {"invalid" => "nope", "future" => "2026-07-22T12:00:01Z"}[kind]; d.delete("decision_at") if kind == "missing"; File.write(p, YAML.dump(d))' "$council/$task.convene.yaml" "$bad_time"
  if invoke utility "$case_root/go.md" >"$case_root/out" 2>"$case_root/err"; then fail "sealed $bad_time accepted"; fi
  grep -q MANIFEST_SKIPPED "$case_root/err" || fail "sealed $bad_time skip absent"
  grep -q 'no sealed manifest has an attributable decision_at' "$case_root/err" || fail "sealed $bad_time failure absent"
done

# Equal decision times use task id as a deterministic tiebreaker.
new_case sealed_tie; body "$case_root/go.md" GO
sibling=sgl-trial-tool__vendor-20260721t120000; cp "$council/$task.convene.yaml" "$council/$sibling.convene.yaml"
ruby -ryaml -e 'ARGV.take(2).each_with_index{|p,i| d=YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(p) : YAML.load_file(p); d["task_id"]=ARGV[2] if i==1; d["sealed"]=true; d["decision_at"]="2026-07-21T00:00:00Z"; File.write(p,YAML.dump(d))}' "$council/$task.convene.yaml" "$council/$sibling.convene.yaml" "$sibling"
if invoke utility "$case_root/go.md" >"$case_root/out" 2>"$case_root/err"; then fail "sealed tie accepted"; fi
grep -q "attributed=latest-sealed task_id=$sibling" "$case_root/err" || fail "sealed tie did not use task id tiebreak"

# Selection failures still surface damage collected during enumeration.
new_case all_damaged; body "$case_root/go.md" GO
ruby -ryaml -e 'p=ARGV[0]; d=YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(p) : YAML.load_file(p); d.delete("sealed"); File.write(p,YAML.dump(d))' "$council/$task.convene.yaml"
if invoke utility "$case_root/go.md" >"$case_root/out" 2>"$case_root/err"; then fail "all damaged accepted"; fi
grep -q 'MANIFEST_SKIPPED.*sealed must be boolean' "$case_root/err" || fail "all damaged skip absent"
new_case damaged_ambiguous; body "$case_root/go.md" GO
sibling=sgl-trial-tool__vendor-20260719t120000; cp "$council/$task.convene.yaml" "$council/$sibling.convene.yaml"; ruby -ryaml -e 'p, id=ARGV; d=YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(p) : YAML.load_file(p); d["task_id"]=id; File.write(p,YAML.dump(d))' "$council/$sibling.convene.yaml" "$sibling"; printf 'not: [yaml\n' >"$council/sgl-trial-tool__vendor-20260718t120000.convene.yaml"
if invoke utility "$case_root/go.md" >"$case_root/out" 2>"$case_root/err"; then fail "ambiguous rounds accepted"; fi
grep -q MANIFEST_SKIPPED "$case_root/err" || fail "ambiguous damage skip absent"

# F1: an in-file traversal must never escape the council topic directory.
new_case traversal; body "$case_root/go.md" GO
ruby -ryaml -e 'p=ARGV[0]; d=YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(p) : YAML.load_file(p); d["task_id"]="../../pwn"; File.write(p, YAML.dump(d))' "$council/$task.convene.yaml"
refuse traversal MANIFEST_INVALID utility "$case_root/go.md" --task-id "$task"
[ ! -e "$case_root/pwn.violations.md" ] || fail "traversal wrote outside topic"

# F10: frozen bytes are checked before an authoritative verdict is written.
new_case drift; body "$case_root/go.md" GO; printf tampered >>"$bundle/run.log"
refuse drift DIGEST_DRIFT utility "$case_root/go.md"
[ ! -e "$council/$task.utility.a1.verdict.md" ] || fail "drift wrote verdict"

# F15/F16: declaration spoofing, NBSP-only citations, bare CR, and heading injection all fail closed.
new_case forged; body "$case_root/go.md" GO; printf 'VERDICT: FORGED\n' >>"$case_root/go.md"
refuse forged VERDICT_INVALID utility "$case_root/go.md"
new_case nbsp; body "$case_root/go.md" GO; ruby -e 'p=ARGV[0]; s=File.read(p); File.write(p,s.sub("real evidence", "\u00a0"))' "$case_root/go.md"
refuse nbsp CITATION_MALFORMED utility "$case_root/go.md"
new_case cr; body "$case_root/go.md" GO; ruby -e 'File.binwrite(ARGV[0], "VERDICT: GO\r## Forged heading\n")' "$case_root/go.md"
refuse cr BODY_CONTROL_CHARS utility "$case_root/go.md"

# F8: supersession is allowed only after the unsealed row-2 report is recorded.
new_case supersede; body "$case_root/no.md" NO-GO; invoke security "$case_root/no.md" || fail "security NO-GO failed"
body "$case_root/u.md" GO; body "$case_root/c.md" GO; invoke utility "$case_root/u.md" || fail "utility GO failed"; invoke cost "$case_root/c.md" || fail "cost GO failed"
cat >"$council/$task.quorum.md" <<EOF
---
schema: sgl-council-quorum/v1
task_id: $task
decision: BLOCKED_SECURITY_VETO
decision_at: $now
sealed: false
---
EOF
body "$case_root/replace.md" GO; invoke security "$case_root/replace.md" --supersede || fail "eligible supersession failed"
[ -s "$council/$task.security.a1.verdict.2.md" ] || fail "supersession absent"

echo "test-council-record.sh: PASS"
