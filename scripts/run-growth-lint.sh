#!/usr/bin/env bash
# Cron/launchd entrypoint for growth-lint with logging and dead-man heartbeat.
# Compatible with macOS Bash 3.2.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin
export PATH
if ! command -v ruby >/dev/null 2>&1; then
  echo "run-growth-lint.sh: ruby not found on PATH; install ruby to use this repo's scripts" >&2
  exit 127
fi

# launchd provides no locale; without UTF-8 the inline Ruby in the lint/poll
# tooling parses as US-ASCII and dies on multibyte event-line characters.
LC_ALL=en_US.UTF-8
export LC_ALL

if [ -z "${HOME:-}" ]; then
  echo "run-growth-lint.sh: HOME must be set" >&2
  exit 2
fi

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
vault=${SGL_VAULT:-"$HOME/SharedHub/family-vault"}
sensors=${SGL_SENSORS:-mine}
lint=${SGL_LINT:-"$root/scripts/growth-lint.sh"}
heartbeat_tool=${SGL_HEARTBEAT_TOOL:-}
log_dir=${SGL_LOG_DIR:-"$HOME/.claude/logs/self-growth"}

if ! mkdir -p "$log_dir"; then
  echo "run-growth-lint.sh: cannot create log directory: $log_dir" >&2
  exit 2
fi

timestamp=$(date -u '+%Y%m%d-%H%M%S')
logfile="$log_dir/growth-lint-$timestamp.log"
start_seconds=$(date +%s)

log_setup_failed() {
  { exec 3>&-; } 2>/dev/null || :
  echo "run-growth-lint.sh: log setup failed: $logfile" >&2
  end_seconds=$(date +%s)
  duration_ms=$(((end_seconds - start_seconds) * 1000))
  if [ -x "$heartbeat_tool" ]; then
    if ! "$heartbeat_tool" self-growth-lint fail --reason 'log setup failed' --duration-ms "$duration_ms"; then
      echo "run-growth-lint.sh: warning: heartbeat update failed" >&2
    fi
  else
    echo "run-growth-lint.sh: warning: heartbeat tool missing or not executable: $heartbeat_tool" >&2
  fi
  exit 2
}

if ! : >"$logfile"; then
  log_setup_failed
fi
if ! exec 3>>"$logfile"; then
  log_setup_failed
fi
if ! printf '# run-growth-lint start %s tz=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(date '+%z')" >&3; then
  log_setup_failed
fi

child_pid=''
signal_name=''
signal_number=0
# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
forward_signal() {
  signal_name=$1
  signal_number=$2
  [ -n "$child_pid" ] || return 0
  kill -"$signal_name" -- "-$child_pid" 2>/dev/null || kill -"$signal_name" "$child_pid" 2>/dev/null || :
  deadline=$(( $(date +%s) + 30 ))
  while kill -0 -- "-$child_pid" 2>/dev/null || kill -0 "$child_pid" 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || {
      kill -KILL -- "-$child_pid" 2>/dev/null || kill -KILL "$child_pid" 2>/dev/null || :
      break
    }
    sleep 1
  done
}
trap 'forward_signal TERM 15' TERM
trap 'forward_signal INT 2' INT
trap 'forward_signal HUP 1' HUP

set -m
"$lint" --vault "$vault" --sensors "$sensors" >&3 2>&1 &
child_pid=$!
set +m
lint_status=0
while :; do
  if wait "$child_pid"; then lint_status=0; else lint_status=$?; fi
  kill -0 "$child_pid" 2>/dev/null || break
done
exec 3>&-

if [ "$signal_number" -ne 0 ]; then
  lint_status=$((128 + signal_number))
fi

end_seconds=$(date +%s)
duration_ms=$(((end_seconds - start_seconds) * 1000))

if ! find "$log_dir" -maxdepth 1 -type f -name 'growth-lint-*.log' -mtime +30 -delete; then
  echo "run-growth-lint.sh: warning: could not prune old growth-lint logs" >&2
fi

log_basename=$(basename -- "$logfile")
if [ -x "$heartbeat_tool" ]; then
  if [ -n "$signal_name" ]; then
    reason="signal $signal_name; see $log_basename"
    if ! "$heartbeat_tool" self-growth-lint fail --reason "$reason" --duration-ms "$duration_ms"; then
      echo "run-growth-lint.sh: warning: heartbeat update failed" >&2
    fi
  elif [ "$lint_status" -eq 0 ] || [ "$lint_status" -eq 1 ]; then
    if ! "$heartbeat_tool" self-growth-lint ok --duration-ms "$duration_ms"; then
      echo "run-growth-lint.sh: warning: heartbeat update failed" >&2
    fi
  else
    reason="exit $lint_status; see $log_basename"
    if ! "$heartbeat_tool" self-growth-lint fail --reason "$reason" --duration-ms "$duration_ms"; then
      echo "run-growth-lint.sh: warning: heartbeat update failed" >&2
    fi
  fi
else
  echo "run-growth-lint.sh: warning: heartbeat tool missing or not executable: $heartbeat_tool" >&2
fi

if [ "$lint_status" -eq 1 ]; then
  echo "run-growth-lint.sh: lock busy: skipped (heartbeat ok)" >&2
fi

trap - TERM INT HUP
exit "$lint_status"
