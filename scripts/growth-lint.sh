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
EOF
}
fail() { echo "growth-lint.sh: $*" >&2; exit 2; }
file_mtime() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null; }

vault=''; now_override=''; sense_status=''; sensors='mine'; dry_run=0
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
}

if [ "$dry_run" -eq 0 ]; then
  mkdir -p "$ledger" "$(dirname "$report")" || fail 'cannot create vault directories'
  adopt_with_lock "$vault" run
else
  run
fi
