#!/usr/bin/env bash
# macOS Bash 3.2 regression tests for proposal-ledger intake hardening.
set -u
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tool="$root/scripts/propose.sh"
temp_vault=$(mktemp -d "${TMPDIR:-/tmp}/propose-test.XXXXXX")
ledger="$temp_vault/45_ai-systems/self-growth/proposals"
failures=0
cleanup() { rm -rf "$temp_vault"; }
trap cleanup EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
assert_contains() { printf '%s' "$1" | grep -Fq "$2" || fail "expected [$2] in [$1]"; }
assert_eq() { [ "$1" = "$2" ] || fail "expected [$2], got [$1]"; }
yaml_ok() { ruby -ryaml -e 'YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0])' "$1" >/dev/null 2>&1 || fail "invalid YAML: $1"; }
count() { grep -c "$1" "$2" || true; }
call() { "$tool" --vault "$temp_vault" --topic-key "$1" --title "$2" --state "$3" --proposer "$4" --url "$5" --report "$6" --actor "$4"; }

# Quoted/backslash values append safely and exact dedupe uses original values.
key='quote-test__community'
first=$(call "$key" x PROPOSED alpha https://first.example first.md)
second=$(call "$key" x PROPOSED alpha 'https://second.example/a"b\q' 'second"report.md')
record="$ledger/$key.md"
assert_contains "$first" CREATED; assert_contains "$second" SIGHTED; yaml_ok "$record"
ruby -ryaml -e 'd=YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]); abort unless d["source_items"][1]["url"] == "https://second.example/a\"b\\q" && d["source_items"][1]["report"] == "second\"report.md"' "$record" || fail 'quoted/backslash append was not preserved'
call "$key" x PROPOSED alpha 'https://second.example/a"b\q' duplicate.md >/dev/null
assert_eq "$(count '^  - url:' "$record")" 2; yaml_ok "$record"

# Legacy state bytes normalize on both existing-record write paths.
legacy_key='pending-legacy__community'; call "$legacy_key" x PROPOSED alpha https://legacy-pending.example one.md >/dev/null
legacy_record="$ledger/$legacy_key.md"; sed -i.bak 's/^state: PROPOSED$/state: PENDING_SHO/' "$legacy_record"; rm -f "$legacy_record.bak"
legacy_sighting=$(call "$legacy_key" x PROPOSED beta https://legacy-pending.example/two two.md)
assert_contains "$legacy_sighting" SIGHTED; grep -q '^state: PENDING_OWNER$' "$legacy_record" || fail 'legacy sighting state was not normalized'

legacy_old_key='pending-old__vendor'; call "$legacy_old_key" x PROPOSED alpha https://pending-old.example/v1 one.md >/dev/null
legacy_old_record="$ledger/$legacy_old_key.md"; sed -i.bak 's/^state: PROPOSED$/state: PENDING_SHO/' "$legacy_old_record"; rm -f "$legacy_old_record.bak"
legacy_new_key='pending-old__vendor__v2'
legacy_superseded=$("$tool" --vault "$temp_vault" --topic-key "$legacy_new_key" --title x --state PROPOSED --proposer alpha --url https://pending-old.example/v2 --report two.md --supersedes "$legacy_old_key")
assert_contains "$legacy_superseded" CREATED; grep -q '^state: PENDING_OWNER$' "$legacy_old_record" || fail 'legacy superseded state was not normalized'

# Injection, all C0 controls, bad keys, and missing values fail fast with status 2.
set +e
"$tool" --vault "$temp_vault" --topic-key inject__community --title x --state PROPOSED --proposer $'alpha\nstate: ADOPTED' --url u --report r >/dev/null 2>&1; injection_status=$?
"$tool" --vault "$temp_vault" --topic-key ctl__community --title x --state PROPOSED --proposer alpha --url $'u\a' --report r >/dev/null 2>&1; control_status=$?
"$tool" --vault >/dev/null 2>&1; missing_status=$?
"$tool" --vault "$temp_vault" --topic-key 'foo--bar__vendor' --title x --state PROPOSED --proposer alpha --url u --report r >/dev/null 2>&1; repeated_dash_status=$?
"$tool" --vault "$temp_vault" --topic-key '-foo__vendor' --title x --state PROPOSED --proposer alpha --url u --report r >/dev/null 2>&1; leading_dash_status=$?
set -e
assert_eq "$injection_status" 2; assert_eq "$control_status" 2; assert_eq "$missing_status" 2; assert_eq "$repeated_dash_status" 2; assert_eq "$leading_dash_status" 2

# Stubs redirect once; damaged stubs are fail-visible.
call canonical-tool__vendor x PROPOSED alpha https://canon.example one.md >/dev/null
printf '%s\n' 'MERGED_INTO: canonical-tool__vendor' > "$ledger/old-tool__vendor.md"
redirected=$(call old-tool__vendor x PROPOSED alpha https://redirect.example two.md)
assert_contains "$redirected" 'REDIRECTED old-tool__vendor -> canonical-tool__vendor'; assert_contains "$redirected" SIGHTED
yaml_ok "$ledger/canonical-tool__vendor.md"
printf '%s\n' 'MERGED_INTO: missing-tool__vendor' > "$ledger/damaged-tool__vendor.md"
set +e; call damaged-tool__vendor x PROPOSED alpha https://bad.example r >/dev/null 2>&1; damaged_status=$?; set -e
assert_eq "$damaged_status" 3

# Re-entry needs evidence; DLQ writes a backup reference before rewriting.
re_key='legacy-tool__community'; call "$re_key" x PROPOSED alpha https://legacy.example one.md >/dev/null
re_record="$ledger/$re_key.md"
# SLA clock (§2/§3): sightings preserve state_entered_at; re-entry rewrites it.
entered_before=$(awk '/^state_entered_at:/{print $2; exit}' "$re_record")
[ -n "$entered_before" ] || fail 'state_entered_at missing on creation'
call "$re_key" x PROPOSED alpha https://legacy.example/again again.md >/dev/null
entered_after_sighting=$(awk '/^state_entered_at:/{print $2; exit}' "$re_record")
assert_eq "$entered_after_sighting" "$entered_before"
sed -i.bak 's/^state: PROPOSED$/state: REJECTED/' "$re_record"; rm -f "$re_record.bak"
set +e; "$tool" --vault "$temp_vault" --topic-key "$re_key" --title x --state PROPOSED --proposer beta --url https://legacy.example/fix --report fix.md --materially-new security-fix >/dev/null 2>&1; no_evidence=$?; set -e
assert_eq "$no_evidence" 2
sleep 1  # ensure the re-entry timestamp differs from creation (second granularity)
reentered=$("$tool" --vault "$temp_vault" --topic-key "$re_key" --title x --state PROPOSED --proposer beta --url https://legacy.example/fix --report fix.md --materially-new security-fix --evidence CVE-2026-1)
assert_contains "$reentered" REENTERED; grep -Fq 'evidence CVE-2026-1' "$re_record" || fail 'evidence missing'; yaml_ok "$re_record"
entered_after_reentry=$(awk '/^state_entered_at:/{print $2; exit}' "$re_record")
[ "$entered_after_reentry" != "$entered_before" ] || fail 'state_entered_at not rewritten on re-entry'
dlq_key='stuck-tool__community'; call "$dlq_key" x PROPOSED alpha https://dlq.example one.md >/dev/null
dlq_record="$ledger/$dlq_key.md"; sed -i.bak 's/^state: PROPOSED$/state: DLQ/' "$dlq_record"; rm -f "$dlq_record.bak"
dlq_reentry=$("$tool" --vault "$temp_vault" --topic-key "$dlq_key" --title x --state PROPOSED --proposer beta --url https://dlq.example/fix --report fix.md --materially-new human-bump --evidence sho-message-1)
assert_contains "$dlq_reentry" REENTERED; grep -Fq 'backup ' "$dlq_record" || fail 'DLQ backup path missing'; find "$temp_vault/45_ai-systems/self-growth/backups" -name 'proposals-*.tar.gz' | grep -q . || fail 'DLQ backup missing'; yaml_ok "$dlq_record"

# Version change creates a new record, preserves old state, and logs supersession.
old_key='engine__vendor'; call "$old_key" x PROPOSED alpha https://engine.example/v1 one.md >/dev/null
old_record="$ledger/$old_key.md"; sed -i.bak 's/^state: PROPOSED$/state: REJECTED/' "$old_record"; rm -f "$old_record.bak"
new_key='engine__vendor__v2'
superseded=$("$tool" --vault "$temp_vault" --topic-key "$new_key" --title x --state PROPOSED --proposer alpha --url https://engine.example/v2 --report two.md --supersedes "$old_key")
assert_contains "$superseded" CREATED; [ -f "$ledger/$new_key.md" ] || fail 'superseding record missing'; grep -q '^state: REJECTED$' "$old_record" || fail 'superseded state changed'; grep -Fq "SUPERSEDED_BY — $new_key" "$old_record" || fail 'supersession event missing'; yaml_ok "$old_record"; yaml_ok "$ledger/$new_key.md"

# Existing identity-critical records are repaired, with an event note.
identity_key='identity-tool__community'; call "$identity_key" x PROPOSED alpha https://identity.example one.md >/dev/null
identity_record="$ledger/$identity_key.md"; sed -i.bak 's/^risk_tier: T0$/risk_tier: T1/; s/^identity_critical: false$/identity_critical: true/' "$identity_record"; rm -f "$identity_record.bak"
call "$identity_key" x PROPOSED beta https://identity.example two.md >/dev/null
grep -q '^risk_tier: T2$' "$identity_record" || fail 'identity clamp missing'; grep -Fq IDENTITY_CRITICAL "$identity_record" || fail 'identity clamp event missing'; yaml_ok "$identity_record"

# A stale, empty owner file is recoverable.
mkdir "$ledger/.lock"; : > "$ledger/.lock/owner"; touch -t 202001010000 "$ledger/.lock"
lock_result=$(call stale-lock__community x PROPOSED alpha https://stale.example r)
assert_contains "$lock_result" STALE_LOCK_BROKEN; yaml_ok "$ledger/stale-lock__community.md"

# TERM exits the delayed writer and leaves no torn YAML file.
signal_vault=$(mktemp -d "${TMPDIR:-/tmp}/propose-signal.XXXXXX"); mkdir "$signal_vault/bin"
printf '%s\n' '#!/bin/sh' 'sleep 1' '/bin/date "$@"' > "$signal_vault/bin/date"; chmod +x "$signal_vault/bin/date"
PATH="$signal_vault/bin:$PATH" "$tool" --vault "$signal_vault/v" --topic-key signal-tool__community --title x --state PROPOSED --proposer alpha --url u --report r & signal_pid=$!
signal_lock="$signal_vault/v/45_ai-systems/self-growth/proposals/.lock/owner"; tries=0
while [ ! -f "$signal_lock" ] && [ "$tries" -lt 40 ]; do sleep 0.05; tries=$((tries + 1)); done
kill -TERM "$signal_pid" 2>/dev/null || true; set +e; wait "$signal_pid"; signal_status=$?; set -e
assert_eq "$signal_status" 143
signal_record="$signal_vault/v/45_ai-systems/self-growth/proposals/signal-tool__community.md"; [ ! -e "$signal_record" ] || yaml_ok "$signal_record"
rm -rf "$signal_vault"

# Standard owner confirmation upgrades proposal frontmatter to the exact
# 23-key v2 shape without changing scripts/propose.sh.
v2_key='owner-confirm__community'
call "$v2_key" 'Owner confirmation fixture' PROPOSED alpha https://owner.example owner.md >/dev/null
v2_record="$ledger/$v2_key.md"
yaml_ok "$v2_record"
ruby -ryaml -e '
  data = YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0])
  expected = %w[
    schema topic_key title state state_entered_at risk_tier
    identity_critical tiebreak proposer executor_agent executor_model
    created updated cooldown_until retry_count proposal_attempt
    owner_confirmation source_items links backup_ref effect_metric
    report_due reversibility
  ]
  abort "top-level key order mismatch" unless data.keys == expected
  abort "schema mismatch" unless data["schema"] == "sgl-proposal/v2"
  abort "proposal_attempt mismatch" unless data["proposal_attempt"] == 0
  owner = data["owner_confirmation"]
  abort "owner_confirmation missing" unless owner.is_a?(Hash)
  abort "owner_confirmation key order mismatch" unless owner.keys == %w[status assurance reference proposal_digest decision principal verified_at]
  abort "owner_confirmation pending mismatch" unless owner == {
    "status" => "pending",
    "assurance" => "standard",
    "reference" => "",
    "proposal_digest" => "",
    "decision" => "",
    "principal" => "",
    "verified_at" => ""
  }
' "$v2_record" || fail 'proposal did not render exact owner-confirmation v2 shape'

if [ "$failures" -ne 0 ]; then exit 1; fi
echo 'PASS: test-propose-convergence'
