#!/usr/bin/env bash
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
reconcile="$root/scripts/adopt-reconcile.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-adopt-reconcile.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fail() { echo "test-adopt-reconcile.sh: $*" >&2; exit 1; }
files='run.log env-manifest.txt config-diff.txt permissions.md cost.txt attempts.md repro.md rollback-test.md'

[ -x "$reconcile" ] || fail "missing executable: $reconcile"

new_case() {
  vault="$tmp/$1/vault"
  ledger="$vault/45_ai-systems/self-growth/proposals"
  mkdir -p "$ledger"
}

write_legacy() {
  topic=$1 state=$2 risk=${3:-T1}
  task="sgl-trial-$topic-20260720t000000"
  record="$ledger/$topic.md"
  cat >"$record" <<EOF
---
topic_key: $topic
title: Legacy $topic
state: $state
state_entered_at: 2026-07-20T00:00:00Z
risk_tier: $risk
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
  trial_bundle: "loop/artifacts/$task/"
  council_verdicts: ""
  adoption_entry: ""
backup_ref: ""
effect_metric: ""
report_due: ""
reversibility: "git revert one commit"
---

## Judgement

Legacy fixture with no prior Standard correlation.

## Events (append-only)

EOF
}

backup_for() {
  find "$vault/45_ai-systems/self-growth/backups" -type f -name "reconcile-*-$topic.tar.gz" -print
}

assert_v2() {
  expected_attempt=$1 expected_state=$2
  ruby -ryaml -e '
    d=YAML.load_file(ARGV[0])
    abort unless d.keys == %w[schema topic_key title state state_entered_at risk_tier identity_critical tiebreak proposer executor_agent executor_model created updated cooldown_until retry_count proposal_attempt owner_confirmation source_items links backup_ref effect_metric report_due reversibility]
    abort unless d["schema"]=="sgl-proposal/v2" && d["state"]==ARGV[1] && d["proposal_attempt"]==ARGV[2].to_i
    abort unless d["owner_confirmation"]=={"status"=>"pending","assurance"=>"standard","reference"=>"","proposal_digest"=>"","decision"=>"","principal"=>"","verified_at"=>""}
  ' "$record" "$expected_state" "$expected_attempt" || fail "reconciled v2 shape invalid"
}

# Non-T0 migration creates one exact-member backup, is idempotent only with
# that backup intact, and restores the exact legacy bytes.
new_case proposed; topic=legacy-proposed__tool; write_legacy "$topic" PROPOSED T1
cp "$record" "$tmp/proposed.legacy"
"$reconcile" --vault "$vault" --topic "$topic" --now 2026-07-21T00:00:00Z >"$tmp/proposed.out" || fail "PROPOSED reconcile failed"
assert_v2 0 PROPOSED
backup=$(backup_for)
[ -f "$backup" ] || fail "reconcile backup missing"
relative=${backup#"$vault/"}
[ "$(tar -tzf "$backup")" = "45_ai-systems/self-growth/proposals/$topic.md" ] || fail "backup member set is not exact"
tar -xOzf "$backup" "45_ai-systems/self-growth/proposals/$topic.md" >"$tmp/proposed.archived"
cmp -s "$tmp/proposed.archived" "$tmp/proposed.legacy" || fail "backup proposal bytes differ"
cp "$record" "$tmp/proposed.v2"
backup_digest=$(shasum "$backup")
"$reconcile" --vault "$vault" --topic "$topic" --now 2026-07-22T00:00:00Z >"$tmp/proposed.retry" || fail "reconcile idempotent retry failed"
cmp -s "$record" "$tmp/proposed.v2" || fail "reconcile retry changed proposal"
[ "$backup_digest" = "$(shasum "$backup")" ] || fail "reconcile retry changed backup"
[ "$(backup_for | wc -l | tr -d ' ')" -eq 1 ] || fail "reconcile retry created a second backup"
cp "$record" "$tmp/proposed.before-empty-restore"
"$reconcile" --vault "$vault" --topic "$topic" --restore-backup '' \
  >"$tmp/proposed.empty-restore.out" 2>"$tmp/proposed.empty-restore.err"
rc=$?
[ "$rc" -eq 2 ] || fail "empty restore-backup exit code was $rc"
cmp -s "$record" "$tmp/proposed.before-empty-restore" || fail "empty restore-backup changed proposal"
[ "$backup_digest" = "$(shasum "$backup")" ] || fail "empty restore-backup changed backup"
cp "$record" "$tmp/proposed.before-duplicate-restore"
"$reconcile" --vault "$vault" --topic "$topic" --restore-backup "$relative" --restore-backup "$relative" \
  >"$tmp/proposed.duplicate-restore.out" 2>"$tmp/proposed.duplicate-restore.err"
rc=$?
[ "$rc" -eq 2 ] || fail "duplicate restore-backup exit code was $rc"
grep -q 'duplicate option: --restore-backup' "$tmp/proposed.duplicate-restore.err" || fail "duplicate restore-backup refusal missing"
cmp -s "$record" "$tmp/proposed.before-duplicate-restore" || fail "duplicate restore-backup changed proposal"
[ "$backup_digest" = "$(shasum "$backup")" ] || fail "duplicate restore-backup changed backup"
[ "$(backup_for | wc -l | tr -d ' ')" -eq 1 ] || fail "duplicate restore-backup changed backup count"
"$reconcile" --vault "$vault" --topic "$topic" --restore-backup "$relative" >"$tmp/proposed.restore" || fail "restore failed"
cmp -s "$record" "$tmp/proposed.legacy" || fail "restore did not recover exact legacy proposal bytes"
[ -f "$backup" ] || fail "restore deleted backup"

# Terminal legacy states do not migrate, and non-T0 migration rejects workspace.
for terminal_state in ADOPTED EXPIRED REJECTED DLQ WATCH; do
  terminal_slug=$(printf '%s' "$terminal_state" | tr '[:upper:]' '[:lower:]')
  new_case "terminal-$terminal_slug"; topic="legacy-${terminal_slug}__tool"; write_legacy "$topic" "$terminal_state" T0
  cp "$record" "$tmp/terminal-$terminal_slug.before"
  if "$reconcile" --vault "$vault" --topic "$topic" --now 2026-07-21T00:00:00Z \
    >"$tmp/terminal-$terminal_slug.out" 2>"$tmp/terminal-$terminal_slug.err"; then
    fail "legacy $terminal_state reconcile unexpectedly succeeded"
  fi
  grep -q 'legacy-terminal-reconcile-unsupported' "$tmp/terminal-$terminal_slug.err" || fail "legacy $terminal_state refusal token missing"
  cmp -s "$record" "$tmp/terminal-$terminal_slug.before" || fail "legacy $terminal_state refusal changed proposal"
  [ ! -d "$vault/45_ai-systems/self-growth/backups" ] || fail "legacy $terminal_state refusal wrote backup directory"
done

new_case workspace; topic=legacy-workspace__tool; write_legacy "$topic" PROPOSED T1
mkdir -p "$tmp/workspace-root"
cp "$record" "$tmp/workspace.before"
if "$reconcile" --vault "$vault" --topic "$topic" --workspace "$tmp/workspace-root" --now 2026-07-21T00:00:00Z \
  >"$tmp/workspace.out" 2>"$tmp/workspace.err"; then
  fail "irrelevant non-T0 workspace accepted"
fi
grep -q 'workspace is only valid' "$tmp/workspace.err" || fail "non-T0 workspace refusal missing"
cmp -s "$record" "$tmp/workspace.before" || fail "workspace refusal changed proposal"

new_case duplicate-workspace; topic=legacy-duplicate-workspace__tool; write_legacy "$topic" PROPOSED T1
mkdir -p "$tmp/duplicate-workspace-1" "$tmp/duplicate-workspace-2"
cp "$record" "$tmp/duplicate-workspace.before"
"$reconcile" --vault "$vault" --topic "$topic" \
  --workspace "$tmp/duplicate-workspace-1" --workspace "$tmp/duplicate-workspace-2" \
  --now 2026-07-21T00:00:00Z >"$tmp/duplicate-workspace.out" 2>"$tmp/duplicate-workspace.err"
rc=$?
[ "$rc" -eq 2 ] || fail "duplicate workspace exit code was $rc"
grep -q 'duplicate option: --workspace' "$tmp/duplicate-workspace.err" || fail "duplicate workspace refusal missing"
cmp -s "$record" "$tmp/duplicate-workspace.before" || fail "duplicate workspace changed proposal"
[ ! -d "$vault/45_ai-systems/self-growth/backups" ] || fail "duplicate workspace wrote backup directory"

new_case duplicate-now; topic=legacy-duplicate-now__tool; write_legacy "$topic" PROPOSED T1
cp "$record" "$tmp/duplicate-now.before"
"$reconcile" --vault "$vault" --topic "$topic" \
  --now 2026-07-21T00:00:00Z --now 2026-07-22T00:00:00Z \
  >"$tmp/duplicate-now.out" 2>"$tmp/duplicate-now.err"
rc=$?
[ "$rc" -eq 2 ] || fail "duplicate now exit code was $rc"
grep -q 'duplicate option: --now' "$tmp/duplicate-now.err" || fail "duplicate now refusal missing"
cmp -s "$record" "$tmp/duplicate-now.before" || fail "duplicate now changed proposal"
[ ! -d "$vault/45_ai-systems/self-growth/backups" ] || fail "duplicate now wrote backup directory"

# Unexpected hidden archive residue blocks publication.
new_case stale; topic=legacy-stale__tool; write_legacy "$topic" PROPOSED T1
mkdir -p "$vault/45_ai-systems/self-growth/backups"
printf partial >"$vault/45_ai-systems/self-growth/backups/.reconcile-20260721t000000z-$topic.tar.gz.tmp.99.0123456789abcdef"
if "$reconcile" --vault "$vault" --topic "$topic" --now 2026-07-21T00:00:00Z >"$tmp/stale.out" 2>"$tmp/stale.err"; then
  fail "stale reconcile temp accepted"
fi
grep -q 'stale-reconcile-temp' "$tmp/stale.err" || fail "stale reconcile temp token missing"

new_case symlinked-backup-ancestor; topic=legacy-symlinked-backup-ancestor__tool; write_legacy "$topic" PROPOSED T1
"$reconcile" --vault "$vault" --topic "$topic" --now 2026-07-21T00:00:00Z >"$tmp/symlinked-ancestor.out" || fail "symlinked backup ancestor setup reconcile failed"
backup=$(backup_for)
backup_dir=$(dirname "$backup")
backup_name=$(basename "$backup")
mkdir -p "$tmp/symlinked-external-backups"
mv "$backup" "$tmp/symlinked-external-backups/$backup_name"
rmdir "$backup_dir"
ln -s "$tmp/symlinked-external-backups" "$backup_dir"
cp "$record" "$tmp/symlinked-backup-ancestor.before"
if "$reconcile" --vault "$vault" --topic "$topic" --now 2026-07-22T00:00:00Z \
  >"$tmp/symlinked-backup-ancestor.rerun.out" 2>"$tmp/symlinked-backup-ancestor.rerun.err"; then
  fail "symlinked backup ancestor rerun accepted"
fi
grep -q 'reconcile-backup-symlink' "$tmp/symlinked-backup-ancestor.rerun.err" || fail "symlinked backup ancestor token missing"
cmp -s "$record" "$tmp/symlinked-backup-ancestor.before" || fail "symlinked backup ancestor rerun changed proposal"

new_case cleanup; topic=legacy-cleanup__tool; write_legacy "$topic" PROPOSED T1
mkdir -p "$tmp/cleanup-external-backups"
ln -s "$tmp/cleanup-external-backups" "$vault/45_ai-systems/self-growth/backups"
cp "$record" "$tmp/cleanup.before"
if "$reconcile" --vault "$vault" --topic "$topic" --now 2026-07-21T00:00:00Z \
  >"$tmp/cleanup.out" 2>"$tmp/cleanup.err"; then
  fail "symlinked backup leaf accepted"
fi
grep -q 'backups-directory-invalid' "$tmp/cleanup.err" || fail "cleanup refusal token missing"
if grep -q 'NameError' "$tmp/cleanup.err"; then
  fail "cleanup path leaked NameError"
fi
cmp -s "$record" "$tmp/cleanup.before" || fail "cleanup refusal changed proposal"
[ -z "$(find "$tmp/cleanup-external-backups" -mindepth 1 -print -quit)" ] || fail "cleanup left backup residue"

# Legacy T0 migration seals held workspace evidence, backs up both exact source
# files, repairs a crash between seal and proposal publication, detects later
# workspace drift, and restores both legacy files.
new_case t0; topic=legacy-t0__tool; write_legacy "$topic" PENDING_SHO T0
workspace="$tmp/t0/workspace"
bundle="$workspace/loop/artifacts/$task/out/bundle"
packet="$vault/45_ai-systems/self-growth/trial-packets/$task.md"
t0_artifact="$vault/45_ai-systems/self-growth/council/$topic/$task.t0-skip.md"
mkdir -p "$bundle" "$(dirname "$packet")" "$(dirname "$t0_artifact")"
for file in $files; do printf 'fixture %s\n' "$file" >"$bundle/$file"; done
printf '# Packet\n\nLegacy T0 packet.\n' >"$packet"
cat >"$t0_artifact" <<EOF
T0 fast path: this reversible, non-identity-critical proposal skips council review and remains subject to the Sho human gate.

- 2026-07-20T00:00:00Z alpha COUNCIL→PENDING_SHO — auto-adopt path (T0), council skipped
EOF
cp "$record" "$tmp/t0.legacy-proposal"
cp "$t0_artifact" "$tmp/t0.legacy-artifact"
"$reconcile" --vault "$vault" --topic "$topic" --workspace "$workspace" --now 2026-07-21T00:00:00Z \
  >"$tmp/t0.out" || fail "legacy T0 reconcile failed"
assert_v2 1 PENDING_OWNER
grep -q '^sgl-t0-skip/v1$' "$t0_artifact" || fail "legacy T0 evidence was not sealed"
t0_backup=$(backup_for)
[ -f "$t0_backup" ] || fail "T0 backup missing"
t0_relative=${t0_backup#"$vault/"}
expected_members=$(printf '%s\n%s' \
  "45_ai-systems/self-growth/proposals/$topic.md" \
  "45_ai-systems/self-growth/council/$topic/$task.t0-skip.md" | sort)
[ "$(tar -tzf "$t0_backup" | sort)" = "$expected_members" ] || fail "T0 backup member set is not exact"
tar -xOzf "$t0_backup" "45_ai-systems/self-growth/proposals/$topic.md" >"$tmp/t0.archived-proposal"
tar -xOzf "$t0_backup" "45_ai-systems/self-growth/council/$topic/$task.t0-skip.md" >"$tmp/t0.archived-artifact"
cmp -s "$tmp/t0.archived-proposal" "$tmp/t0.legacy-proposal" || fail "T0 proposal backup bytes differ"
cmp -s "$tmp/t0.archived-artifact" "$tmp/t0.legacy-artifact" || fail "T0 artifact backup bytes differ"

# Simulate a crash after the sealed artifact publish but before proposal publish.
cp "$tmp/t0.legacy-proposal" "$record"
"$reconcile" --vault "$vault" --topic "$topic" --workspace "$workspace" --now 2026-07-22T00:00:00Z \
  >"$tmp/t0.repair" || fail "T0 crash repair failed"
grep -Eq 'REPAIRED|RECONCILED' "$tmp/t0.repair" || fail "T0 crash repair was not reported"
assert_v2 1 PENDING_OWNER
[ "$(backup_for | wc -l | tr -d ' ')" -eq 1 ] || fail "T0 repair created a duplicate backup"

cp "$record" "$tmp/t0.before-drift"
printf drift >>"$bundle/run.log"
if "$reconcile" --vault "$vault" --topic "$topic" --workspace "$workspace" --now 2026-07-23T00:00:00Z \
  >"$tmp/t0.drift.out" 2>"$tmp/t0.drift.err"; then
  fail "T0 workspace evidence drift accepted"
fi
grep -q 'legacy-t0-evidence-mismatch' "$tmp/t0.drift.err" || fail "T0 evidence mismatch token missing"
cmp -s "$record" "$tmp/t0.before-drift" || fail "T0 evidence mismatch changed proposal"
printf 'fixture run.log\n' >"$bundle/run.log"

cp "$record" "$tmp/t0.reconciled-proposal"
cp "$tmp/t0.archived-artifact" "$t0_artifact"
"$reconcile" --vault "$vault" --topic "$topic" --restore-backup "$t0_relative" >"$tmp/t0.restore" || fail "T0 restore from crash intermediate failed"
cmp -s "$record" "$tmp/t0.legacy-proposal" || fail "T0 restore did not recover proposal"
cmp -s "$t0_artifact" "$tmp/t0.legacy-artifact" || fail "T0 restore did not recover legacy evidence"
[ -f "$t0_backup" ] || fail "T0 restore deleted backup"
cp "$record" "$tmp/t0.after-restore.proposal"
cp "$t0_artifact" "$tmp/t0.after-restore.artifact"
"$reconcile" --vault "$vault" --topic "$topic" --restore-backup "$t0_relative" >"$tmp/t0.restore.rerun" || fail "T0 restore rerun failed"
cmp -s "$record" "$tmp/t0.after-restore.proposal" || fail "T0 restore rerun changed proposal"
cmp -s "$t0_artifact" "$tmp/t0.after-restore.artifact" || fail "T0 restore rerun changed legacy evidence"

# Renamed v1 T0 prose remains readable too, and its exact bytes survive backup
# validation and restore.
new_case t0-current; topic=current-t0__tool; write_legacy "$topic" PENDING_OWNER T0
workspace="$tmp/t0-current/workspace"
bundle="$workspace/loop/artifacts/$task/out/bundle"
packet="$vault/45_ai-systems/self-growth/trial-packets/$task.md"
t0_artifact="$vault/45_ai-systems/self-growth/council/$topic/$task.t0-skip.md"
mkdir -p "$bundle" "$(dirname "$packet")" "$(dirname "$t0_artifact")"
for file in $files; do printf 'fixture %s\n' "$file" >"$bundle/$file"; done
printf '# Packet\n\nCurrent-form T0 packet.\n' >"$packet"
cat >"$t0_artifact" <<EOF
T0 fast path: this reversible, non-identity-critical proposal skips council review and remains subject to the Sho human gate.

- 2026-07-20T00:00:00Z alpha COUNCIL→PENDING_OWNER — auto-adopt path (T0), council skipped
EOF
cp "$record" "$tmp/t0-current.proposal"
cp "$t0_artifact" "$tmp/t0-current.artifact"
"$reconcile" --vault "$vault" --topic "$topic" --workspace "$workspace" --now 2026-07-21T00:00:00Z \
  >"$tmp/t0-current.out" || fail "current-form T0 reconcile failed"
assert_v2 1 PENDING_OWNER
grep -q '^sgl-t0-skip/v1$' "$t0_artifact" || fail "current-form T0 evidence was not sealed"
t0_backup=$(backup_for)
t0_relative=${t0_backup#"$vault/"}
"$reconcile" --vault "$vault" --topic "$topic" --restore-backup "$t0_relative" >"$tmp/t0-current.restore" || fail "current-form T0 restore failed"
cmp -s "$record" "$tmp/t0-current.proposal" || fail "current-form T0 proposal restore differed"
cmp -s "$t0_artifact" "$tmp/t0-current.artifact" || fail "current-form T0 artifact restore differed"

echo "test-adopt-reconcile.sh: PASS"
