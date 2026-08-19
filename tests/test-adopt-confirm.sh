#!/usr/bin/env bash
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
confirm="$root/scripts/adopt-confirm.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-adopt-confirm.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fail() { echo "test-adopt-confirm.sh: $*" >&2; exit 1; }

future_due_utc() {
  ruby -e 'now = Time.now.utc; print(Time.utc(now.year + 1, now.month, now.day, now.hour, now.min, now.sec).strftime("%Y-%m-%dT%H:%M:%SZ"))'
}

report_due=$(future_due_utc) || fail "could not derive future report_due fixture"

[ -x "$confirm" ] || fail "missing executable: $confirm"
command -v expect >/dev/null || fail "expect is required for PTY regression coverage"

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
  ledger="$vault/45_ai-systems/self-growth/proposals"
  mkdir -p "$ledger" "$vault/45_ai-systems/self-growth/council/$topic"
  cat >"$ledger/$topic.md" <<EOF
---
schema: sgl-proposal/v2
topic_key: $topic
title: Confirm $topic
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
reversibility: "git revert one commit"
---

## Judgement

This exact reversible change is ready for disposition.

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

prompt_for() {
  decision=$1 backup=${2-} metric=${3-} due=${4-} reason=${5-}
  ruby - "$root" "$vault" "$topic" "$decision" "$backup" "$metric" "$due" "$reason" <<'RUBY'
repo, vault, topic, decision, backup, metric, due, reason = ARGV
require File.join(repo, "scripts/lib-owner-confirmation")
record = OwnerConfirmation.load_proposal_record(path: File.join(vault, "45_ai-systems/self-growth/proposals", "#{topic}.md"))
owner = OwnerConfirmation.load_owner_config(vault_root: vault)
inputs = decision == "GO" ? {"backup_ref" => backup, "effect_metric" => metric, "report_due" => due} : {"reason" => reason}
evidence = OwnerConfirmation.derive_t0_evidence(vault_root: vault, workspace_root: nil, record: record)
snapshot = OwnerConfirmation.build_decision_snapshot(record: record, owner_config: owner, decision: decision, issued_inputs: inputs, evidence: evidence)
digest = OwnerConfirmation.sha256_hex(snapshot)
puts "CONFIRM #{decision} #{topic} #{record["proposal_attempt"]} #{digest[0, 12]}"
RUBY
}

pty_issue() {
  decision=$1 backup=${2-} metric=${3-} due=${4-} reason=${5-} output=$6
  prompt=$(prompt_for "$decision" "$backup" "$metric" "$due" "$reason") || fail "prompt derivation failed"
  EXPECT_CONFIRM=$prompt EXPECT_BIN=$confirm EXPECT_VAULT=$vault EXPECT_TOPIC=$topic \
    EXPECT_DECISION=$decision EXPECT_BACKUP=$backup EXPECT_METRIC=$metric EXPECT_DUE=$due \
    EXPECT_REASON=$reason expect <<'EXPECT' >"$output" 2>&1
set timeout 15
set args [list $env(EXPECT_BIN) --vault $env(EXPECT_VAULT) --topic $env(EXPECT_TOPIC) --decision $env(EXPECT_DECISION)]
if {$env(EXPECT_DECISION) eq "GO"} {
  lappend args --backup-ref $env(EXPECT_BACKUP) --effect-metric $env(EXPECT_METRIC) --report-due $env(EXPECT_DUE)
} else {
  lappend args --reason $env(EXPECT_REASON)
}
spawn {*}$args
expect -exact "$env(EXPECT_CONFIRM)\r\n"
send -- "$env(EXPECT_CONFIRM)\r"
expect eof
set result [wait]
exit [lindex $result 3]
EXPECT
}

pty_reject() {
  response=$1 output=$2
  prompt=$(prompt_for GO backup metric "$report_due" "") || fail "negative prompt derivation failed"
  EXPECT_CONFIRM=$prompt EXPECT_RESPONSE=$response EXPECT_BIN=$confirm EXPECT_VAULT=$vault EXPECT_TOPIC=$topic EXPECT_DUE=$report_due \
    expect <<'EXPECT' >"$output" 2>&1
set timeout 15
spawn $env(EXPECT_BIN) --vault $env(EXPECT_VAULT) --topic $env(EXPECT_TOPIC) --decision GO --backup-ref backup --effect-metric metric --report-due $env(EXPECT_DUE)
expect -exact "$env(EXPECT_CONFIRM)\r\n"
send -- $env(EXPECT_RESPONSE)
expect eof
set result [wait]
exit [expr {[lindex $result 3] == 0 ? 1 : 0}]
EXPECT
}

pty_eof_reject() {
  output=$1
  prompt=$(prompt_for GO backup metric "$report_due" "") || fail "EOF prompt derivation failed"
  EXPECT_CONFIRM=$prompt EXPECT_BIN=$confirm EXPECT_VAULT=$vault EXPECT_TOPIC=$topic EXPECT_DUE=$report_due \
    expect <<'EXPECT' >"$output" 2>&1
set timeout 15
spawn $env(EXPECT_BIN) --vault $env(EXPECT_VAULT) --topic $env(EXPECT_TOPIC) --decision GO --backup-ref backup --effect-metric metric --report-due $env(EXPECT_DUE)
expect -exact "$env(EXPECT_CONFIRM)\r\n"
send -- $env(EXPECT_CONFIRM)
after 100
close
catch wait result
exit 0
EXPECT
}

artifact_path() {
  printf '%s/45_ai-systems/self-growth/confirmations/%s/1/owner-confirmation.txt' "$vault" "$topic"
}

reference_from() {
  sed -n 's/^Authorization reference: //p' "$1" | tail -n 1 | tr -d '\r'
}

# Byte-addressed evidence spans must remain exact when preceding and captured
# content contains multibyte UTF-8.
ruby - "$root" <<'RUBY' || fail "UTF-8 Judgement byte-span regression"
require File.join(ARGV.fetch(0), "scripts/lib-owner-confirmation")
sample = "前置き\n## Judgement\n\n変更は可逆です。\n\n## Events (append-only)\n"
heading = "## Judgement\n"
offset = OwnerConfirmation.exact_line_offset(sample, heading)
abort unless offset == sample.b.index(heading.b)
span = OwnerConfirmation.extract_judgement_span(sample)
abort unless span == "\n変更は可逆です。\n\n"
changed = sample.sub("可逆です", "安全です")
abort if OwnerConfirmation.sha256_hex(span) == OwnerConfirmation.sha256_hex(OwnerConfirmation.extract_judgement_span(changed))
RUBY

# Validation precedes TTY access, and a valid absent issuance requires a TTY.
new_case non_tty; topic=non-tty__tool; write_pending_t0 "$topic"
if bash "$confirm" --vault "$vault" --topic "$topic" --decision GO \
  --backup-ref backup --effect-metric metric --report-due "$report_due" \
  </dev/null >"$tmp/non-tty.out" 2>"$tmp/non-tty.err"; then
  fail "non-TTY issuance unexpectedly succeeded"
fi
grep -q 'tty-required' "$tmp/non-tty.err" || fail "non-TTY token missing"
[ ! -e "$(artifact_path)" ] || fail "non-TTY refusal wrote an artifact"
printf 'schema: wrong\n' >"$vault/45_ai-systems/self-growth/config/owner.yaml"
if bash "$confirm" --vault "$vault" --topic "$topic" --decision GO \
  --backup-ref backup --effect-metric metric --report-due "$report_due" \
  >"$tmp/order.out" 2>"$tmp/order.err"; then
  fail "damaged owner config accepted"
fi
grep -q 'owner-config' "$tmp/order.err" || fail "owner config was not rejected before TTY access"
! grep -q 'tty-required' "$tmp/order.err" || fail "TTY check ran before owner validation"

# Exact TTY response grammar rejects any mismatched or surplus byte. Each case
# starts without an artifact so a false acceptance is durable and observable.
for response_case in wrong leading trailing extra crlf; do
  new_case "response-$response_case"; topic="response-${response_case}__tool"; write_pending_t0 "$topic"
  prompt=$(prompt_for GO backup metric "$report_due" "") || fail "$response_case prompt derivation failed"
  case "$response_case" in
    wrong) response="WRONG $prompt"$'\r' ;;
    leading) response=" $prompt"$'\r' ;;
    trailing) response="$prompt "$'\r' ;;
    extra) response="$prompt"$'\rX' ;;
    crlf) response="$prompt"$'\r\n' ;;
  esac
  pty_reject "$response" "$tmp/response-$response_case.out" || fail "$response_case TTY response was accepted"
  [ ! -e "$(artifact_path)" ] || fail "$response_case TTY response wrote an artifact"
done

new_case response-eof; topic='response-eof__tool'; write_pending_t0 "$topic"
pty_eof_reject "$tmp/response-eof.out" || fail "EOF-without-LF TTY response was accepted"
[ ! -e "$(artifact_path)" ] || fail "EOF-without-LF response wrote an artifact"

# Redirected stdin cannot supply the confirmation response while /dev/tty is
# authoritative. The exact prompt on stdin is ignored; a wrong TTY response
# still rejects and leaves the namespace empty.
new_case redirected-stdin; topic=redirected-stdin__tool; write_pending_t0 "$topic"
prompt=$(prompt_for GO backup metric "$report_due" "") || fail "redirected stdin prompt derivation failed"
printf '%s\n' "$prompt" >"$tmp/redirected-input"
EXPECT_CONFIRM=$prompt EXPECT_BIN=$confirm EXPECT_VAULT=$vault EXPECT_TOPIC=$topic EXPECT_INPUT="$tmp/redirected-input" EXPECT_DUE=$report_due \
  expect <<'EXPECT' >"$tmp/redirected.out" 2>&1 || fail "redirected stdin supplied confirmation"
set timeout 15
spawn /bin/sh -c {exec "$EXPECT_BIN" --vault "$EXPECT_VAULT" --topic "$EXPECT_TOPIC" --decision GO --backup-ref backup --effect-metric metric --report-due "$EXPECT_DUE" < "$EXPECT_INPUT"}
expect -exact "$env(EXPECT_CONFIRM)\r\n"
send -- "WRONG\r"
expect eof
set result [wait]
exit [expr {[lindex $result 3] == 0 ? 1 : 0}]
EXPECT
[ ! -e "$(artifact_path)" ] || fail "redirected stdin wrote an artifact"

# Empty-valued irrelevant decision options remain present options and fail
# before TTY access or artifact publication.
new_case empty-irrelevant-go; topic=empty-irrelevant-go__tool; write_pending_t0 "$topic"
status=0
bash "$confirm" --vault "$vault" --topic "$topic" --decision GO \
  --backup-ref backup --effect-metric metric --report-due "$report_due" --reason '' \
  </dev/null >"$tmp/empty-irrelevant-go.out" 2>"$tmp/empty-irrelevant-go.err" || status=$?
[ "$status" -eq 2 ] || fail "empty GO reason exit code was $status"
grep -q -- '--reason is irrelevant to GO' "$tmp/empty-irrelevant-go.err" || fail "empty GO reason refusal missing"
[ ! -e "$(artifact_path)" ] || fail "empty GO reason wrote an artifact"

new_case empty-irrelevant-watch; topic=empty-irrelevant-watch__tool; write_pending_t0 "$topic"
status=0
bash "$confirm" --vault "$vault" --topic "$topic" --decision WATCH --reason wait --backup-ref '' \
  </dev/null >"$tmp/empty-irrelevant-watch.out" 2>"$tmp/empty-irrelevant-watch.err" || status=$?
[ "$status" -eq 2 ] || fail "empty WATCH backup exit code was $status"
grep -q -- '--backup-ref is irrelevant to non-GO decisions' "$tmp/empty-irrelevant-watch.err" || fail "empty WATCH backup refusal missing"
[ ! -e "$(artifact_path)" ] || fail "empty WATCH backup wrote an artifact"

# A real PTY creates one artifact. An identical rerun returns the exact same
# reference and bytes without needing a controlling terminal.
new_case reuse; topic=reuse__tool; write_pending_t0 "$topic"
pty_issue GO "backup O'Brien" "latency p95" "$report_due" "" "$tmp/reuse.issue" || fail "PTY issuance failed"
artifact=$(artifact_path)
[ -s "$artifact" ] || fail "PTY issuance did not create artifact"
reference=$(reference_from "$tmp/reuse.issue")
[ -n "$reference" ] || fail "issuance reference missing"
cp "$artifact" "$tmp/reuse.bytes"
if ! bash "$confirm" --vault "$vault" --topic "$topic" --decision GO \
  --backup-ref "backup O'Brien" --effect-metric "latency p95" --report-due "$report_due" \
  </dev/null >"$tmp/reuse.again" 2>"$tmp/reuse.err"; then
  fail "unexpired identical artifact required a TTY"
fi
[ "$reference" = "$(reference_from "$tmp/reuse.again")" ] || fail "unexpired reference changed"
cmp -s "$artifact" "$tmp/reuse.bytes" || fail "unexpired artifact bytes changed"
grep -Fq "'backup O'\\''Brien'" "$tmp/reuse.again" || fail "single quote was not POSIX-serialized"

# Expired, byte-identical evidence is replaced atomically and invalidates the
# old durable digest while retaining a single canonical filename.
old_reference=$reference
ruby - "$root" "$vault" "$topic" "$artifact" "$report_due" <<'RUBY'
repo, vault, topic, path, due = ARGV
require File.join(repo, "scripts/lib-owner-confirmation")
record = OwnerConfirmation.load_proposal_record(path: File.join(vault, "45_ai-systems/self-growth/proposals", "#{topic}.md"))
owner = OwnerConfirmation.load_owner_config(vault_root: vault)
evidence = OwnerConfirmation.derive_t0_evidence(vault_root: vault, workspace_root: nil, record: record)
inputs = {"backup_ref" => "backup O'Brien", "effect_metric" => "latency p95", "report_due" => due}
bytes = OwnerConfirmation.build_owner_confirmation_artifact(
  record: record, owner_config: owner, decision: "GO",
  issued_at: Time.now.utc - (2 * 86_400), issued_inputs: inputs, evidence: evidence
)
File.binwrite(path, bytes)
RUBY
expired_reference=$(ruby - "$root" "$topic" "$artifact" <<'RUBY'
repo, topic, path = ARGV
require File.join(repo, "scripts/lib-owner-confirmation")
print OwnerConfirmation.build_owner_confirmation_reference(topic_key: topic, proposal_attempt: 1, bytes: File.binread(path))
RUBY
)
pty_issue GO "backup O'Brien" "latency p95" "$report_due" "" "$tmp/reuse.replace" || fail "expired replacement failed"
new_reference=$(reference_from "$tmp/reuse.replace")
[ "$new_reference" != "$old_reference" ] && [ "$new_reference" != "$expired_reference" ] || fail "replacement did not publish new bytes"
[ "$(find "$(dirname "$artifact")" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 1 ] || fail "replacement retained superseded files"

# Namespace and stale-temp conflicts are classified before any prompt.
new_case namespace; topic=namespace__tool; write_pending_t0 "$topic"
mkdir -p "$vault/45_ai-systems/self-growth/confirmations/$topic"
printf occupied >"$vault/45_ai-systems/self-growth/confirmations/$topic/1"
if bash "$confirm" --vault "$vault" --topic "$topic" --decision WATCH --reason wait >"$tmp/ns.out" 2>"$tmp/ns.err"; then
  fail "occupied attempt namespace accepted"
fi
grep -q 'attempt-namespace-occupied' "$tmp/ns.err" || fail "namespace token missing"

new_case stale; topic=stale__tool; write_pending_t0 "$topic"
mkdir -p "$vault/45_ai-systems/self-growth/confirmations/$topic/1"
printf partial >"$vault/45_ai-systems/self-growth/confirmations/$topic/1/.owner-confirmation.txt.tmp.99.0123456789abcdef"
if bash "$confirm" --vault "$vault" --topic "$topic" --decision WATCH --reason wait >"$tmp/stale.out" 2>"$tmp/stale.err"; then
  fail "stale confirmation temp accepted"
fi
grep -q 'stale-confirmation-temp' "$tmp/stale.err" || fail "stale temp token missing"

# The printed quoted command round-trips a raw apostrophe and semicolon.
new_case quote; topic=quote__tool; write_pending_t0 "$topic"
reason="Sho's reason; literal"
pty_issue WATCH "" "" "" "$reason" "$tmp/quote.issue" || fail "WATCH issuance failed"
consume_command=$(sed -n 's/^Consume command: //p' "$tmp/quote.issue" | tail -n 1 | tr -d '\r')
[ -n "$consume_command" ] || fail "quoted consume command missing"
eval "$consume_command" >/dev/null || fail "printed consume command did not execute"
grep -Fq "operator_reason=$reason" "$vault/45_ai-systems/self-growth/proposals/$topic.md" || fail "quoted reason did not round-trip"

# T0 eligibility is checked on every issuance, and representability failures
# are exposed by the shared artifact builder used by Phase B.
new_case eligibility; topic=eligibility__tool; write_pending_t0 "$topic"
sed -i '' 's/^identity_critical: false$/identity_critical: true/' "$vault/45_ai-systems/self-growth/proposals/$topic.md"
if bash "$confirm" --vault "$vault" --topic "$topic" --decision WATCH --reason wait >"$tmp/eligibility.out" 2>"$tmp/eligibility.err"; then
  fail "ineligible T0 accepted"
fi
grep -q 't0-eligibility-mismatch' "$tmp/eligibility.err" || fail "T0 eligibility token missing"

ruby - "$root" "$tmp/reuse/vault" reuse__tool <<'RUBY' || fail "confirmation window overflow was not rejected"
repo, vault, topic = ARGV
require File.join(repo, "scripts/lib-owner-confirmation")
record = OwnerConfirmation.load_proposal_record(path: File.join(vault, "45_ai-systems/self-growth/proposals", "#{topic}.md"))
owner = OwnerConfirmation.load_owner_config(vault_root: vault)
evidence = OwnerConfirmation.derive_t0_evidence(vault_root: vault, workspace_root: nil, record: record)
begin
  OwnerConfirmation.build_owner_confirmation_artifact(
    record: record, owner_config: owner, decision: "WATCH",
    issued_at: Time.utc(9999, 12, 31, 23, 59, 59),
    issued_inputs: {"reason" => "wait"}, evidence: evidence
  )
  exit 1
rescue OwnerConfirmation::Error => e
  exit(e.code == "confirmation-window-overflow" ? 0 : 1)
end
RUBY

echo "test-adopt-confirm.sh: PASS"
