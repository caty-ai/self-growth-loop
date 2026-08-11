#!/usr/bin/env bash
set -u
# shellcheck disable=SC2034 # consumed by the sourced shared helper
ADOPT_TOOL=adopt-complete.sh
# shellcheck disable=SC1091
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lib-adopt.sh"
usage() { echo 'Usage: adopt-complete.sh --vault <root> --topic <key> --smoke-result <path> [--actor <slug>] [--where <text>] [--now <ISO8601Z>] [--dry-run]' >&2; }
vault=''; topic=''; smoke=''; actor=alpha; where=''; early=''; now=''; dry=0
while [ "$#" -gt 0 ]; do case "$1" in
  --vault|--topic|--smoke-result|--actor|--where|--now) [ "$#" -ge 2 ] || { usage; exit 2; }; case "$1" in --vault) vault=$2;; --topic) topic=$2;; --smoke-result) smoke=$2;; --actor) actor=$2;; --where) where=$2;; --now) now=$2;; esac; shift 2;;
  --early-authorized-by) [ "$#" -ge 2 ] || { usage; exit 2; }; adopt_fail '--early-authorized-by is no longer supported';;
  --dry-run) dry=1; shift;; --help) usage; exit 0;; *) adopt_fail "unknown option: $1";; esac; done
[ -n "$vault" ] && [ -n "$topic" ] && [ -n "$smoke" ] || { usage; exit 2; }; [ -n "$now" ] || now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
adopt_validate_topic "$topic"
record="$vault/45_ai-systems/self-growth/proposals/$topic.md"
run() { adopt_run_worker complete "$record" "$now" "$dry" "$smoke" "$actor" "$where" "$vault" "$early"; }
if [ "$dry" -eq 1 ]; then run; else adopt_with_lock "$vault" run; fi
