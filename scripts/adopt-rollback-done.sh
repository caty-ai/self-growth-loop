#!/usr/bin/env bash
set -u
if ! command -v ruby >/dev/null 2>&1; then
  echo "adopt-rollback-done.sh: ruby not found on PATH; install ruby to use this repo's scripts" >&2
  exit 127
fi
# shellcheck disable=SC2034 # consumed by the sourced shared helper
ADOPT_TOOL=adopt-rollback-done.sh
# shellcheck disable=SC1091
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lib-adopt.sh"
usage() { echo 'Usage: adopt-rollback-done.sh --vault <root> --topic <key> --evidence <path> [--now <ISO8601Z>] [--dry-run]' >&2; }
vault=''; topic=''; evidence=''; now=''; dry=0
while [ "$#" -gt 0 ]; do case "$1" in
  --vault|--topic|--evidence|--now) [ "$#" -ge 2 ] || { usage; exit 2; }; case "$1" in --vault) vault=$2;; --topic) topic=$2;; --evidence) evidence=$2;; --now) now=$2;; esac; shift 2;;
  --dry-run) dry=1; shift;; --help) usage; exit 0;; *) adopt_fail "unknown option: $1";; esac; done
[ -n "$vault" ] && [ -n "$topic" ] && [ -n "$evidence" ] || { usage; exit 2; }; [ -n "$now" ] || now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
adopt_validate_topic "$topic"
record="$vault/45_ai-systems/self-growth/proposals/$topic.md"
run() { adopt_run_worker rollback "$record" "$now" "$dry" "$evidence"; }
if [ "$dry" -eq 1 ]; then run; else adopt_with_lock "$vault" run; fi
