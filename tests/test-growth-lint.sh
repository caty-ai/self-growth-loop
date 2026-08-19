#!/usr/bin/env bash
# Regression tests for SLA transitions, queue visibility, and writer locking.
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
lint="$root/scripts/growth-lint.sh"
propose="$root/scripts/propose.sh"
vault=$(mktemp -d "${TMPDIR:-/tmp}/growth-lint-test.XXXXXX")
ledger="$vault/45_ai-systems/self-growth/proposals"
failures=0
cleanup() { rm -rf "$vault"; }
trap cleanup EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
assert_contains() { printf '%s' "$1" | grep -Fq "$2" || fail "expected [$2] in [$1]"; }
state_of() { ruby -ryaml -e 'puts (YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]))["state"]' "$1"; }
assert_pending_confirmation() {
  ruby -ryaml -e '
    expected = {
      "status" => "pending",
      "assurance" => "standard",
      "reference" => "",
      "proposal_digest" => "",
      "decision" => "",
      "principal" => "",
      "verified_at" => "",
    }
    abort unless (YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]))["owner_confirmation"] == expected
  ' "$1" || fail "$2"
}
call_propose() { "$propose" --vault "$vault" --topic-key "$1" --title "$2" --state PROPOSED --proposer alpha --url "https://$1.test" --report source.md --now 2026-07-31T00:00:00Z >/dev/null; }
set_field() {
  FIELD=$2 VALUE=$3 ruby -ryaml -e '
    p=ARGV[0]; lines=File.readlines(p); stop=lines[1..-1].index("---\n") + 1
    lines.map!.with_index { |line,i| i <= stop && line =~ /^#{Regexp.escape(ENV["FIELD"])}:/ ? "#{ENV["FIELD"]}: #{ENV["VALUE"]}\n" : line }
    File.write(p, lines.join)
  ' "$1"
}
set_verified_confirmation() {
  RECORD=$1 TOPIC=$2 ATTEMPT=$3 VERIFIED_AT=$4 DECISION=${5:-GO} ruby -e '
    path = ENV.fetch("RECORD")
    lines = File.readlines(path)
    start = lines.index("owner_confirmation:\n")
    abort "owner_confirmation block missing" unless start
    finish = start + 1
    finish += 1 while finish < lines.length && lines[finish].start_with?("  ")
    block = [
      "owner_confirmation:\n",
      "  status: verified\n",
      "  assurance: standard\n",
      "  reference: 45_ai-systems/self-growth/confirmations/#{ENV.fetch("TOPIC")}/#{ENV.fetch("ATTEMPT")}/owner-confirmation.txt#sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
      "  proposal_digest: sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n",
      "  decision: #{ENV.fetch("DECISION")}\n",
      "  principal: sho\n",
      "  verified_at: \"#{ENV.fetch("VERIFIED_AT")}\"\n",
    ]
    lines[start...finish] = block
    File.write(path, lines.join)
  '
}

# Use real intake, then hand-edit the current state and SLA clock.
call_propose trial__community 'Trial item'; trial="$ledger/trial__community.md"
set_field "$trial" state TRIALING; set_field "$trial" state_entered_at 2026-07-24T00:00:00Z; set_field "$trial" executor_agent beta
call_propose expired__community 'Expired pending'; expired="$ledger/expired__community.md"
set_field "$expired" state PENDING_OWNER; set_field "$expired" state_entered_at 2026-07-01T00:00:00Z
call_propose reminder__community 'Reminder pending'; reminder="$ledger/reminder__community.md"
set_field "$reminder" state PENDING_OWNER; set_field "$reminder" state_entered_at 2026-07-16T00:00:00Z
"$propose" --vault "$vault" --topic-key legacy-read__community --title 'Legacy pending' --state PROPOSED --proposer alpha --url https://legacy-read.test --report source.md --reversibility 'git revert one commit' --judgement 'Legacy pending read fixture.' --now 2026-07-31T00:00:00Z >/dev/null || fail 'legacy pending fixture setup failed'
legacy_read="$ledger/legacy-read__community.md"; set_field "$legacy_read" state PENDING_SHO; set_field "$legacy_read" state_entered_at 2026-07-20T00:00:00Z; set_field "$legacy_read" proposal_attempt 1
call_propose rollout__community 'Rollout item'; rollout="$ledger/rollout__community.md"
set_field "$rollout" state ADOPTING; set_field "$rollout" state_entered_at 2026-07-24T00:00:00Z; set_field "$rollout" reversibility 'git revert one commit'; set_field "$rollout" proposal_attempt 1
set_verified_confirmation "$rollout" rollout__community 1 2026-07-24T00:00:00Z
call_propose adopted__community 'Adopted item'; adopted="$ledger/adopted__community.md"
set_field "$adopted" state ADOPTED; set_field "$adopted" report_due 2026-07-16T00:00:00Z; set_field "$adopted" proposal_attempt 1
set_verified_confirmation "$adopted" adopted__community 1 2026-07-16T00:00:00Z
mkdir -p "$(dirname "$vault/45_ai-systems/self-growth/sense-status.log")"
printf '%s\n' '2026-08-01T00:00:00Z mine FAIL feed unavailable' > "$vault/45_ai-systems/self-growth/sense-status.log"

"$lint" --vault "$vault" --now 2026-08-01T00:00:00Z >/dev/null || fail 'lint failed'
assert_contains "$(state_of "$trial")" DLQ
assert_contains "$(state_of "$expired")" EXPIRED
assert_pending_confirmation "$expired" 'PENDING_OWNER expiry corrupted canonical pending owner confirmation'
grep -q '^cooldown_until: ""$' "$expired" || fail 'PENDING_OWNER expiry set a cooldown'
assert_contains "$(state_of "$reminder")" PENDING_OWNER
assert_contains "$(state_of "$rollout")" DLQ
grep -Fq 'rollback_required: git revert one commit' "$rollout" || fail 'ADOPTING rollback requirement absent'
queue="$vault/25_review-pending/self-growth-queue.md"
grep -Fq '## PENDING_OWNER' "$queue" || fail 'pending section missing'
grep -Fq 'reminder__community' "$queue" || fail 'pending reminder absent'
awk '/## PENDING_OWNER/{p=1;next} /^## /{p=0} p' "$queue" | grep -Fq 'legacy-read__community' || fail 'legacy pending state fell out of the owner queue'
ruby - "$root" "$legacy_read" <<'RUBY' || fail 'shared proposal reader did not normalize the legacy pending state'
root, path = ARGV
require File.join(root, 'scripts/lib-owner-confirmation')
abort unless OwnerConfirmation.load_proposal_record(path: path)['state'] == 'PENDING_OWNER'
RUBY
grep -Fq 'SENSE BROKEN' "$queue" || fail 'failed sensor not visible'
grep -Fq 'effect report overdue — escalated to Sho' "$adopted" || fail 'effect report escalation absent'
# shellcheck disable=SC2016 # literal Markdown command text
grep -Fq 'Run `EFFECT_REPORT` or `SHO_WAIVER`' "$queue" || fail 'effect report action text missing'

# Missing sense status is also fail-visible.
rm -f "$vault/45_ai-systems/self-growth/sense-status.log"
"$lint" --vault "$vault" --now 2026-08-01T00:00:00Z >/dev/null || fail 'lint with missing status failed'
grep -Fq 'SENSE BROKEN' "$queue" || fail 'missing sensor status not visible'
# Escalation pin is sticky on the second run, and the event is appended only once.
grep -Fq 'adopted__community' "$queue" || fail 'unresolved effect-report escalation dropped from queue on rerun'
awk '/## PENDING_OWNER/{p=1;next} /^## /{p=0} p' "$queue" | grep -Fq 'adopted__community' || fail 'escalation not pinned in PENDING_OWNER section on rerun'
[ "$(grep -c 'EFFECT_REPORT_OVERDUE' "$adopted")" -eq 1 ] || fail 'escalation event duplicated on rerun'

# Dry run must leave the vault byte-for-byte untouched, including its report.
before=$(mktemp "${TMPDIR:-/tmp}/growth-before.XXXXXX")
after=$(mktemp "${TMPDIR:-/tmp}/growth-after.XXXXXX")
tar -cf "$before" -C "$vault" .
"$lint" --vault "$vault" --now 2026-09-01T00:00:00Z --dry-run >/dev/null || fail 'dry run failed'
tar -cf "$after" -C "$vault" .
cmp -s "$before" "$after" || fail 'dry run mutated vault'
rm -f "$before" "$after"

# A live owner is never broken or overwritten by the second writer.
mkdir "$ledger/.lock"; printf '%s %s %s\n' "$$" "$(hostname)" propose.sh > "$ledger/.lock/owner"
busy_stderr=$(mktemp "${TMPDIR:-/tmp}/growth-busy.XXXXXX")
set +e
"$lint" --vault "$vault" --now 2026-09-01T00:00:00Z >/dev/null 2>"$busy_stderr"
locked_status=$?
set -e
[ "$locked_status" -eq 1 ] || fail "live lock exit changed: expected 1, got $locked_status"
[ -f "$ledger/.lock/owner" ] || fail 'live lock was corrupted'
grep -Fq "growth-lint.sh: lock busy; skipped without writes: $ledger/.lock" "$busy_stderr" || fail 'busy lock message changed'
rm -f "$busy_stderr"
rm -f "$ledger/.lock/owner"
rmdir "$ledger/.lock" 2>/dev/null || true

# Dry run bypasses the shared lock path and leaves a live lock untouched.
mkdir "$ledger/.lock"; printf '%s %s %s\n' "$$" "$(hostname)" propose.sh > "$ledger/.lock/owner"
"$lint" --vault "$vault" --now 2026-09-01T00:00:00Z --dry-run >/dev/null || fail 'dry run unexpectedly blocked on live lock'
[ -f "$ledger/.lock/owner" ] || fail 'dry run disturbed live lock owner'
rm -f "$ledger/.lock/owner"
rmdir "$ledger/.lock" 2>/dev/null || true

# Boundary, damaged-input, report, and lock-recovery regressions.
empty=$(mktemp -d "${TMPDIR:-/tmp}/growth-empty.XXXXXX")
"$lint" --vault "$empty" --now 2026-08-01T00:00:00Z --dry-run >/dev/null || fail 'empty dry run failed'
[ -z "$(find "$empty" -mindepth 1 -print -quit)" ] || fail 'dry run created a nonexistent vault tree'
rm -rf "$empty"

v2=$(mktemp -d "${TMPDIR:-/tmp}/growth-hardening.XXXXXX")
l2="$v2/45_ai-systems/self-growth/proposals"; mkdir -p "$l2"
vault_save=$vault; ledger_save=$ledger; vault=$v2; ledger=$l2
call_propose exact__community 'Exact boundary'; exact="$l2/exact__community.md"
set_field "$exact" state_entered_at 2026-07-18T00:00:00Z
call_propose bad__community 'Bad spelling'; bad="$l2/bad__community.md"
set_field "$bad" state_entered_at 2026-07-01T00:00:00Z
sed -i.bak 's/^state: /"state": /' "$bad" && rm -f "$bad.bak"
call_propose utf__community 'UTF bad'; utf="$l2/utf__community.md"
printf '\377' >> "$utf"
form_mismatch="$l2/form-mismatch__community.md"
cat >"$form_mismatch" <<'EOF'
---
schema: sgl-proposal/v2
topic_key: form-mismatch__community
title: "Form mismatch"
state: PENDING_OWNER
state_entered_at: 2026-07-01T00:00:00Z
risk_tier: T0
identity_critical: false
tiebreak: T0
proposer: alpha
executor_agent: ""
executor_model: ""
created: 2026-07-01
updated: 2026-07-01
cooldown_until: ""
retry_count: 0
proposal_attempt: 1
owner_confirmation:
  status: verified
  assurance: standard
  reference: 45_ai-systems/self-growth/confirmations/form-mismatch__community/1/owner-confirmation.txt#sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  proposal_digest: sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  decision: GO
  principal: sho
  verified_at: "2026-07-01T00:00:00Z"
source_items: []
links:
  trial_bundle: ""
  council_verdicts: ""
  adoption_entry: ""
backup_ref: ""
effect_metric: ""
report_due: ""
reversibility: "git revert one commit"
---

## Judgement

Mismatch fixture.

## Events (append-only)

EOF
chmod 600 "$exact"
mkdir -p "$v2/45_ai-systems/self-growth"; printf '%s\n' '2026-08-01T00:00:00Z mine OK ok' > "$v2/45_ai-systems/self-growth/sense-status.log"
"$lint" --vault "$v2" --now 2026-08-01T00:00:00Z >/dev/null || fail 'hardening lint failed'
assert_contains "$(state_of "$exact")" EXPIRED
[ "$(ruby -e 'printf "%o", File.stat(ARGV.fetch(0)).mode & 0777' "$exact")" = 600 ] || fail 'rewritten record mode not preserved'
[ "$(state_of "$form_mismatch")" = PENDING_OWNER ] || fail 'invalid v2 state/form record mutated before damage classification'
! grep -Fq 'growth-lint PENDING_OWNER→EXPIRED' "$form_mismatch" || fail 'invalid v2 state/form record appended an SLA transition'
q2="$v2/25_review-pending/self-growth-queue.md"
grep -Fq 'RUN ERRORS:' "$q2" || fail 'bad record did not publish run-error banner'
grep -Fq 'DAMAGED bad__community.md' "$q2" || fail 'quoted state key not damaged'
grep -Fq 'DAMAGED utf__community.md' "$q2" || fail 'invalid UTF-8 not damaged'
grep -Fq 'DAMAGED form-mismatch__community.md — record-damaged: state/owner_confirmation form mismatch' "$q2" || fail 'state/form mismatch did not damage before mutation'
call_propose card__community 'Damaged card'; card="$l2/card__community.md"
set_field "$card" state PENDING_OWNER; set_field "$card" state_entered_at 2026-07-20T00:00:00Z
set_field "$card" links broken
set_field "$card" risk_tier T1
"$lint" --vault "$v2" --now 2026-08-01T00:00:00Z >/dev/null || fail 'damaged card lint failed'
grep -Fq 'card__community' "$q2" || fail 'damaged card was not fail-visible'

# A sealed T1 quorum renders the per-seat vote table and dissent text verbatim.
call_propose t1__community 'T1 quorum card'; t1="$l2/t1__community.md"
set_field "$t1" state PENDING_OWNER; set_field "$t1" state_entered_at 2026-07-20T00:00:00Z; set_field "$t1" risk_tier T1
council_dir="$v2/45_ai-systems/self-growth/council/t1__community"; mkdir -p "$council_dir"
cat >"$council_dir/2026-07-21.quorum.md" <<'EOF'
sealed: true

## Vote table

| Seat | Verdict | Summary |
| --- | --- | --- |
| utility | GO | Faster review |
| cost | WATCH | Meter first |
| security | NO | Need rollback proof |

## Dissents / reservations

security: Need rollback proof before rollout.
EOF
"$lint" --vault "$v2" --now 2026-08-01T00:00:00Z >/dev/null || fail 'sealed quorum lint failed'
grep -Fq '| utility | GO | Faster review |' "$q2" || fail 'utility verdict missing from card'
grep -Fq '| cost | WATCH | Meter first |' "$q2" || fail 'cost verdict missing from card'
grep -Fq '| security | NO | Need rollback proof |' "$q2" || fail 'security verdict missing from card'
grep -Fq '> security: Need rollback proof before rollout.' "$q2" || fail 'verbatim dissent missing from card'

# A dead-owner and ownerless old lock are safely quarantined and recovered.
mkdir "$l2/.lock"; printf '%s %s %s\n' 999999 "$(hostname)" old > "$l2/.lock/owner"; touch -t 202607010000 "$l2/.lock"
dead_lock_out=$(mktemp "${TMPDIR:-/tmp}/growth-stale-dead.XXXXXX")
"$lint" --vault "$v2" --now 2026-08-01T00:00:00Z >"$dead_lock_out" || fail 'dead stale lock not recovered'
grep -Fq "STALE_LOCK_BROKEN $l2/.lock" "$dead_lock_out" || fail 'dead stale lock message changed'
rm -f "$dead_lock_out"
mkdir "$l2/.lock"; touch -t 202607010000 "$l2/.lock"
ownerless_lock_out=$(mktemp "${TMPDIR:-/tmp}/growth-stale-ownerless.XXXXXX")
"$lint" --vault "$v2" --now 2026-08-01T00:00:00Z >"$ownerless_lock_out" || fail 'ownerless stale lock not recovered'
grep -Fq "STALE_LOCK_BROKEN (ownerless) $l2/.lock" "$ownerless_lock_out" || fail 'ownerless stale lock message changed'
rm -f "$ownerless_lock_out"

# A stale lock with a mismatched host token fails safe busy and is not broken.
mkdir "$l2/.lock"; printf '%s %s %s\n' 999999 not-this-host old > "$l2/.lock/owner"; touch -t 202607010000 "$l2/.lock"
mismatched_host_stderr=$(mktemp "${TMPDIR:-/tmp}/growth-stale-host.XXXXXX")
set +e
"$lint" --vault "$v2" --now 2026-08-01T00:00:00Z >/dev/null 2>"$mismatched_host_stderr"
mismatched_host_status=$?
set -e
[ "$mismatched_host_status" -eq 1 ] || fail "mismatched-host stale lock exit changed: expected 1, got $mismatched_host_status"
[ -d "$l2/.lock" ] || fail 'mismatched-host stale lock was incorrectly broken'
grep -Fq "growth-lint.sh: lock busy; skipped without writes: $l2/.lock" "$mismatched_host_stderr" || fail 'mismatched-host busy message changed'
rm -f "$mismatched_host_stderr" "$l2/.lock/owner"
rmdir "$l2/.lock" 2>/dev/null || true

# Latest malformed/future sensor observations must win over older OK entries.
printf '%s\n' '2026-08-01T00:00:00Z mine OK old' 'not-a-time mine FAIL corrupt' > "$v2/45_ai-systems/self-growth/sense-status.log"
"$lint" --vault "$v2" --now 2026-08-01T00:00:00Z >/dev/null || fail 'malformed sensor lint failed'
grep -Fq 'malformed latest status' "$q2" || fail 'malformed latest sensor was ignored'
printf '%s\n' '2030-01-01T00:00:00Z mine OK future' > "$v2/45_ai-systems/self-growth/sense-status.log"
"$lint" --vault "$v2" --now 2026-08-01T00:00:00Z >/dev/null || fail 'future sensor lint failed'
grep -Fq 'future timestamp' "$q2" || fail 'future sensor was not broken'
rm -rf "$v2"; vault=$vault_save; ledger=$ledger_save

# Owner disposition reporting is isolated from SLA writes. A malformed owner
# config blocks templates but does not stop an unrelated expired transition.
authv=$(mktemp -d "${TMPDIR:-/tmp}/growth-owner.XXXXXX")
authl="$authv/45_ai-systems/self-growth/proposals"; mkdir -p "$authl" "$authv/45_ai-systems/self-growth/config"
vault=$authv; ledger=$authl
call_propose blocked__community 'Blocked owner'; blocked="$authl/blocked__community.md"
set_field "$blocked" state PENDING_OWNER; set_field "$blocked" state_entered_at 2026-07-15T00:00:00Z; set_field "$blocked" proposal_attempt 1
call_propose sla__community 'SLA continues'; sla="$authl/sla__community.md"
set_field "$sla" state PENDING_OWNER; set_field "$sla" state_entered_at 2026-06-01T00:00:00Z; set_field "$sla" proposal_attempt 1
printf 'schema: wrong\n' >"$authv/45_ai-systems/self-growth/config/owner.yaml"
mkdir -p "$authv/45_ai-systems/self-growth"; printf '%s\n' '2026-08-01T00:00:00Z mine OK ok' >"$authv/45_ai-systems/self-growth/sense-status.log"
"$lint" --vault "$authv" --now 2026-08-01T00:00:00Z >/dev/null || fail 'owner-config isolation lint failed'
[ "$(state_of "$sla")" = EXPIRED ] || fail 'bad owner config stopped unrelated SLA transition'
authq="$authv/25_review-pending/self-growth-queue.md"
grep -Fq 'owner-config' "$authq" || fail 'bad owner config was not fail-visible'
for decision in GO REJECT WATCH; do
  grep -Fq "$decision (NON-EXECUTABLE TEMPLATE): scripts/adopt-confirm.sh" "$authq" || fail "$decision owner template missing while config blocked"
done

# A valid owner config renders three non-executable templates.
printf '%s\n' \
  'schema: sgl-owner-config/v1' \
  'principal: sho' \
  'repository_id: caty-ai/self-growth-loop' \
  'default_assurance: standard' \
  >"$authv/45_ai-systems/self-growth/config/owner.yaml"
"$lint" --vault "$authv" --now 2026-08-01T00:00:00Z >/dev/null || fail 'owner template lint failed'
for decision in GO REJECT WATCH; do
  grep -Fq "$decision (NON-EXECUTABLE TEMPLATE): scripts/adopt-confirm.sh" "$authq" || fail "$decision owner template missing"
done

# Closed legacy ADOPTED records report unknown correlation, while v2 adoption
# records distinguish a missing artifact from a damaged block.
legacy_topic=legacy-adopted__community
legacy_record="$authl/$legacy_topic.md"
cat >"$legacy_record" <<EOF
---
topic_key: $legacy_topic
title: Legacy adopted
state: ADOPTED
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
source_items: []
links:
  trial_bundle: ""
  council_verdicts: ""
  adoption_entry: "30_decisions/legacy-adoption.md"
backup_ref: backup
effect_metric: metric
report_due: 2026-12-01T00:00:00Z
reversibility: "git revert one commit"
---

## Judgement

Legacy adopted fixture.

## Events (append-only)

EOF
mkdir -p "$authv/30_decisions"
cat >"$authv/30_decisions/legacy-adoption.md" <<'EOF'
# Adoption record

## Decision basis

Legacy evidence.

## Observation contract

Legacy observation.
EOF
"$lint" --vault "$authv" --now 2026-08-01T00:00:00Z >/dev/null || fail 'legacy correlation lint failed'
grep -Fq "$legacy_topic: authorization-reference-unknown" "$authq" || fail 'legacy unknown correlation token missing'

missing_topic=missing-artifact__community
missing_record="$authl/$missing_topic.md"
cat >"$missing_record" <<EOF
---
schema: sgl-proposal/v2
topic_key: $missing_topic
title: Missing artifact
state: ADOPTED
state_entered_at: 2026-07-25T00:00:00Z
risk_tier: T0
identity_critical: false
tiebreak: T0
proposer: mine
executor_agent: alpha
executor_model: gpt-5
created: 2026-07-20
updated: 2026-07-25
cooldown_until: ""
retry_count: 0
proposal_attempt: 1
owner_confirmation:
  status: verified
  assurance: standard
  reference: 45_ai-systems/self-growth/confirmations/$missing_topic/1/owner-confirmation.txt#sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  proposal_digest: sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  decision: GO
  principal: sho
  verified_at: "2026-07-25T00:00:00Z"
source_items: []
links:
  trial_bundle: ""
  council_verdicts: ""
  adoption_entry: "30_decisions/missing-adoption.md"
backup_ref: backup
effect_metric: metric
report_due: 2026-12-01T00:00:00Z
reversibility: "git revert one commit"
---

## Judgement

V2 adopted fixture.

## Events (append-only)

EOF
cat >"$authv/30_decisions/missing-adoption.md" <<EOF
# Adoption record

## Decision basis

Evidence.

## Owner confirmation

- Status: verified
- Assurance: standard
- Reference: 45_ai-systems/self-growth/confirmations/$missing_topic/1/owner-confirmation.txt#sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
- Proposal digest: sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
- Decision: GO
- Principal: sho
- Verified at: 2026-07-25T00:00:00Z

## Observation contract

Observation.
EOF
"$lint" --vault "$authv" --now 2026-08-01T00:00:00Z >/dev/null || fail 'missing artifact lint failed'
grep -Fq "$missing_topic: authorization-artifact-missing" "$authq" || fail 'missing artifact status token missing'
sed -i.bak 's/- Principal: sho/- Principal: other/' "$authv/30_decisions/missing-adoption.md" &&
  rm -f "$authv/30_decisions/missing-adoption.md.bak"
"$lint" --vault "$authv" --now 2026-08-01T00:00:00Z >/dev/null || fail 'damaged owner block lint failed'
grep -Fq "$missing_topic: damaged adoption correlation" "$authq" || fail 'damaged owner block was not classified damaged'

# Lock age is strictly greater than 300 seconds. A deterministic PATH shim
# freezes CLOCK_REALTIME for the retry loop, avoiding wall-clock flakiness.
fakebin="$authv/fakebin"; mkdir -p "$fakebin"
cat >"$fakebin/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1-}" = "+%s" ]; then printf '%s\n' "${TEST_LOCK_NOW:?}"; else exec /bin/date "$@"; fi
EOF
chmod +x "$fakebin/date"
mkdir "$authl/.lock"
ruby -e 't=Time.at(1000); File.utime(t,t,ARGV[0])' "$authl/.lock"
if PATH="$fakebin:$PATH" TEST_LOCK_NOW=1300 "$lint" --vault "$authv" --now 2026-08-01T00:00:00Z >/dev/null 2>&1; then
  fail '300-second ownerless lock was broken'
fi
[ -d "$authl/.lock" ] || fail '300-second lock disappeared'
PATH="$fakebin:$PATH" TEST_LOCK_NOW=1301 "$lint" --vault "$authv" --now 2026-08-01T00:00:00Z >/dev/null || fail '301-second ownerless lock was not recovered'
[ ! -e "$authl/.lock" ] || fail '301-second lock remained'

rm -rf "$authv"; vault=$vault_save; ledger=$ledger_save

if [ "$failures" -ne 0 ]; then exit 1; fi
echo 'PASS: test-growth-lint'
