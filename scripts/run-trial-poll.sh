#!/usr/bin/env bash
# Cron/launchd entrypoint for trial-poll with logging and dead-man heartbeat.
# Compatible with macOS Bash 3.2.
set -u

PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin
export PATH
# launchd provides no locale; without UTF-8 the inline Ruby in the lint/poll
# tooling parses as US-ASCII and dies on multibyte event-line characters.
LC_ALL=en_US.UTF-8
export LC_ALL

if [ -z "${HOME:-}" ]; then
  echo "run-trial-poll.sh: HOME must be set" >&2
  exit 2
fi

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
vault=${SGL_VAULT:-"$HOME/SharedHub/family-vault"}
workspace=${SGL_ENGINE_WORKSPACE:-"$HOME/claude-workspace/sgl-engine-workspace"}
poll=${SGL_TRIAL_POLL:-"$root/scripts/trial-poll.sh"}
heartbeat_tool=${SGL_HEARTBEAT_TOOL:-}
log_dir=${SGL_LOG_DIR:-"$HOME/.claude/logs/self-growth"}

if ! mkdir -p "$log_dir"; then
  echo "run-trial-poll.sh: cannot create log directory: $log_dir" >&2
  exit 2
fi

timestamp=$(date -u '+%Y%m%d-%H%M%S')
logfile="$log_dir/trial-poll-$timestamp.log"
start_seconds=$(date +%s)

log_setup_failed() {
  { exec 3>&-; } 2>/dev/null || :
  echo "run-trial-poll.sh: log setup failed: $logfile" >&2
  end_seconds=$(date +%s)
  duration_ms=$(((end_seconds - start_seconds) * 1000))
  if [ -x "$heartbeat_tool" ]; then
    if ! "$heartbeat_tool" self-growth-trial-poll fail --reason 'log setup failed' --duration-ms "$duration_ms"; then
      echo "run-trial-poll.sh: warning: heartbeat update failed" >&2
    fi
  else
    echo "run-trial-poll.sh: warning: heartbeat tool missing or not executable: $heartbeat_tool" >&2
  fi
  exit 2
}

if ! : >"$logfile"; then
  log_setup_failed
fi
if ! exec 3>>"$logfile"; then
  log_setup_failed
fi
if ! printf '# run-trial-poll start %s tz=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(date '+%z')" >&3; then
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
"$poll" --vault "$vault" --workspace "$workspace" >&3 2>&1 &
child_pid=$!
set +m
poll_status=0
while :; do
  if wait "$child_pid"; then poll_status=0; else poll_status=$?; fi
  kill -0 "$child_pid" 2>/dev/null || break
done
exec 3>&-

if [ "$signal_number" -ne 0 ]; then
  poll_status=$((128 + signal_number))
fi

end_seconds=$(date +%s)
duration_ms=$(((end_seconds - start_seconds) * 1000))

if ! find "$log_dir" -maxdepth 1 -type f -name 'trial-poll-*.log' -mtime +30 -delete; then
  echo "run-trial-poll.sh: warning: could not prune old trial-poll logs" >&2
fi

log_basename=$(basename -- "$logfile")
if [ -x "$heartbeat_tool" ]; then
  if [ -n "$signal_name" ]; then
    reason="signal $signal_name; see $log_basename"
    if ! "$heartbeat_tool" self-growth-trial-poll fail --reason "$reason" --duration-ms "$duration_ms"; then
      echo "run-trial-poll.sh: warning: heartbeat update failed" >&2
    fi
  elif [ "$poll_status" -eq 0 ]; then
    if ! "$heartbeat_tool" self-growth-trial-poll ok --duration-ms "$duration_ms"; then
      echo "run-trial-poll.sh: warning: heartbeat update failed" >&2
    fi
  else
    reason="exit $poll_status; see $log_basename"
    if ! "$heartbeat_tool" self-growth-trial-poll fail --reason "$reason" --duration-ms "$duration_ms"; then
      echo "run-trial-poll.sh: warning: heartbeat update failed" >&2
    fi
  fi
else
  echo "run-trial-poll.sh: warning: heartbeat tool missing or not executable: $heartbeat_tool" >&2
fi

trap - TERM INT HUP
exit "$poll_status"
