#!/usr/bin/env bash
# Enforce proposal-ledger SLA transitions and render the human review queue.
# Compatible with macOS Bash 3.2; strict parsing and UTC arithmetic use Ruby.
set -u
if ! command -v ruby >/dev/null 2>&1; then
  echo "growth-lint.sh: ruby not found on PATH; install ruby to use this repo's scripts" >&2
  exit 127
fi
# shellcheck disable=SC2034 # consumed by sourced shared lock helper
ADOPT_TOOL=growth-lint.sh
# shellcheck disable=SC1091
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lib-adopt.sh"

usage() {
  cat >&2 <<'EOF'
Usage: growth-lint.sh --vault <vault-root> [--now <ISO8601Z>] [--sense-status <file>] [--sensors mine,...] [--dry-run]

Sensing is opt-in via --sensors or --sense-status.
Exit codes (also in --dry-run; reports are published/printed before 3 or 4):
  0   clean: no DAMAGED, sensing OK or not requested
  1   lock busy: skipped without writes
  2   usage / bad option / bad --now / precondition failure (ledger dir, lock identity)
  3   DAMAGED: damaged records or failed actions (takes precedence over 4)
  4   SENSE BROKEN while sensors were requested
  5   report publication failed
  6   internal error (uncaught interpreter failure)
  7   lock-conflict (lock quarantine conflict)
  127 ruby missing
EOF
}
fail() { echo "growth-lint.sh: $*" >&2; exit 2; }
file_mtime() { ruby -e 'print File.mtime(ARGV.fetch(0)).to_i' "$1"; }

vault=''; now_override=''; sense_status=''; sensors=''; dry_run=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --vault|--now|--sense-status|--sensors)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      case "$1" in
        --vault) vault=$2 ;; --now) now_override=$2 ;; --sense-status) sense_status=$2 ;; --sensors) sensors=$2 ;;
      esac
      shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --help) usage; exit 0 ;;
    *) fail "unknown or incomplete option: $1" ;;
  esac
done
[ -n "$vault" ] || { usage; exit 2; }

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ledger="$vault/45_ai-systems/self-growth/proposals"
report="$vault/25_review-pending/self-growth-queue.md"

adopt_lock_busy() {
  echo "growth-lint.sh: lock busy; skipped without writes: $1" >&2
  exit 1
}

adopt_policy_fail() { echo "${ADOPT_TOOL:-adopt}: $*" >&2; exit 7; }

adopt_lock_report_stale() {
  if [ "${2:-0}" -eq 1 ]; then
    echo "STALE_LOCK_BROKEN (ownerless) $1"
  else
    echo "STALE_LOCK_BROKEN $1"
  fi
}

run() {
  VAULT="$vault" LEDGER="$ledger" REPORT="$report" TEMPLATE="$root/templates/self-growth-queue.tmpl.md" NOW_OVERRIDE="$now_override" \
  SENSE_STATUS="$sense_status" SENSORS="$sensors" DRY_RUN="$dry_run" ruby "$root/scripts/growth-lint.rb"
  ruby_status=$?
  if [ "$ruby_status" -eq 1 ]; then
    echo "growth-lint.sh: exit 6 — internal error (ruby exited 1); see output above" >&2
    ruby_status=6
  fi
  return "$ruby_status"
}

if [ "$dry_run" -eq 0 ]; then
  mkdir -p "$ledger" || fail 'cannot create vault directories'
  adopt_with_lock "$vault" run
else
  run
fi
