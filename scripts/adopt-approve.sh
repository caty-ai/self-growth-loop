#!/usr/bin/env bash
set -u
# shellcheck disable=SC2034 # consumed by the sourced shared helper
ADOPT_TOOL=adopt-approve.sh
# shellcheck disable=SC1091
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lib-adopt.sh"
usage() { echo 'Usage: adopt-approve.sh --vault <root> --topic <key> --authorization-ref <canonical reference> --backup-ref <ref> --effect-metric <text> --report-due <ISO8601Z> [--now <ISO8601Z>] [--dry-run]' >&2; }
vault=''; topic=''; auth_ref=''; backup=''; metric=''; due=''; now=''; dry=0
seen_vault=0; seen_topic=0; seen_auth_ref=0; seen_backup=0; seen_metric=0; seen_due=0; seen_reason=0; seen_now=0; seen_dry=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --vault)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_vault" -eq 0 ] || adopt_fail 'duplicate option: --vault'
      seen_vault=1
      vault=$2
      shift 2
      ;;
    --topic)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_topic" -eq 0 ] || adopt_fail 'duplicate option: --topic'
      seen_topic=1
      topic=$2
      shift 2
      ;;
    --authorization-ref)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_auth_ref" -eq 0 ] || adopt_fail 'duplicate option: --authorization-ref'
      seen_auth_ref=1
      auth_ref=$2
      shift 2
      ;;
    --backup-ref)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_backup" -eq 0 ] || adopt_fail 'duplicate option: --backup-ref'
      seen_backup=1
      backup=$2
      shift 2
      ;;
    --effect-metric)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_metric" -eq 0 ] || adopt_fail 'duplicate option: --effect-metric'
      seen_metric=1
      metric=$2
      shift 2
      ;;
    --report-due)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_due" -eq 0 ] || adopt_fail 'duplicate option: --report-due'
      seen_due=1
      due=$2
      shift 2
      ;;
    --reason)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_reason" -eq 0 ] || adopt_fail 'duplicate option: --reason'
      seen_reason=1
      shift 2
      ;;
    --now)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_now" -eq 0 ] || adopt_fail 'duplicate option: --now'
      seen_now=1
      now=$2
      shift 2
      ;;
    --dry-run)
      [ "$seen_dry" -eq 0 ] || adopt_fail 'duplicate option: --dry-run'
      seen_dry=1
      dry=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      adopt_fail "unknown option: $1"
      ;;
  esac
done
[ -n "$vault" ] && [ -n "$topic" ] && [ -n "$auth_ref" ] && [ -n "$backup" ] && [ -n "$metric" ] && [ -n "$due" ] || { usage; exit 2; }
[ "$seen_reason" -eq 0 ] || adopt_fail '--reason is irrelevant to GO'
[ -n "$now" ] || now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
adopt_validate_topic "$topic"
record="$vault/45_ai-systems/self-growth/proposals/$topic.md"
run() { adopt_run_worker approve "$record" "$now" "$dry" "$auth_ref" "$backup" "$metric" "$due"; }
if [ "$dry" -eq 1 ]; then run; else adopt_with_lock "$vault" run; fi
