#!/usr/bin/env bash
set -u
# shellcheck disable=SC2034 # consumed by the sourced shared helper
ADOPT_TOOL=adopt-watch.sh
# shellcheck disable=SC1091
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lib-adopt.sh"
usage() { echo 'Usage: adopt-watch.sh --vault <root> --topic <key> --authorization-ref <canonical reference> --reason <text> [--now <ISO8601Z>]' >&2; }
vault=''; topic=''; auth_ref=''; reason=''; now=''
seen_vault=0; seen_topic=0; seen_auth_ref=0; seen_backup=0; seen_metric=0; seen_due=0; seen_reason=0; seen_now=0
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
      shift 2
      ;;
    --effect-metric)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_metric" -eq 0 ] || adopt_fail 'duplicate option: --effect-metric'
      seen_metric=1
      shift 2
      ;;
    --report-due)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_due" -eq 0 ] || adopt_fail 'duplicate option: --report-due'
      seen_due=1
      shift 2
      ;;
    --reason)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_reason" -eq 0 ] || adopt_fail 'duplicate option: --reason'
      seen_reason=1
      reason=$2
      shift 2
      ;;
    --now)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_now" -eq 0 ] || adopt_fail 'duplicate option: --now'
      seen_now=1
      now=$2
      shift 2
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
[ -n "$vault" ] && [ -n "$topic" ] && [ -n "$auth_ref" ] && [ -n "$reason" ] || { usage; exit 2; }
[ "$seen_backup" -eq 0 ] || adopt_fail '--backup-ref is irrelevant to non-GO decisions'
[ "$seen_metric" -eq 0 ] || adopt_fail '--effect-metric is irrelevant to non-GO decisions'
[ "$seen_due" -eq 0 ] || adopt_fail '--report-due is irrelevant to non-GO decisions'
[ -n "$now" ] || now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
adopt_validate_topic "$topic"
record="$vault/45_ai-systems/self-growth/proposals/$topic.md"; run() { adopt_run_worker watch "$record" "$now" 0 "$auth_ref" "$reason"; }; adopt_with_lock "$vault" run
