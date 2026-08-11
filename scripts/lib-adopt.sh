#!/usr/bin/env bash
# Shared invocation and lock contract for the adoption transition verbs.
# macOS Bash 3.2 compatible.

set -u

adopt_fail() { echo "${ADOPT_TOOL:-adopt}: $*" >&2; exit 2; }
adopt_policy_fail() { echo "${ADOPT_TOOL:-adopt}: $*" >&2; exit 3; }
adopt_lock_busy() { adopt_fail 'proposal-lock-busy'; }
adopt_lock_report_stale() { :; }
adopt_validate_topic() {
  printf '%s\n' "$1" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*__[a-z0-9]+(-[a-z0-9]+)*(__v[0-9]+)?$' || adopt_fail "invalid topic key: $1"
}

adopt_repo_root() { CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd; }
adopt_hostname() { ruby -rsocket -e 'print Socket.gethostname'; }
adopt_lock_validate_identity() {
  ruby -e '
    pid, host, tool = ARGV
    exit 1 unless pid.to_s.match?(/\A[1-9][0-9]*\z/)
    exit 1 unless host.to_s.match?(/\A[A-Za-z0-9._-]+\z/)
    exit 1 unless tool.to_s.match?(/\A[A-Za-z0-9._-]+\z/)
  ' "$1" "$2" "$3"
}
adopt_lock_identity_b64() { ruby -rbase64 -e 'print Base64.strict_encode64(ARGV[0])' "$1"; }
adopt_lock_owner_base64() {
  ruby -rbase64 -e '
    path = ARGV[0]
    begin
      stat = File.lstat(path)
      exit 0 unless stat.file? && !stat.symlink?
      print Base64.strict_encode64(File.binread(path))
    rescue Errno::ENOENT, Errno::ENOTDIR
      exit 0
    end
  ' "$1"
}
adopt_lock_owner_matches_b64() {
  ruby -rbase64 -e '
    path, encoded = ARGV
    begin
      expected = Base64.strict_decode64(encoded)
      actual = File.binread(path)
      exit(actual == expected ? 0 : 1)
    rescue ArgumentError, Errno::ENOENT, Errno::ENOTDIR
      exit 1
    end
  ' "$1" "$2"
}
adopt_lock_write_owner_exclusive_b64() {
  ruby -rbase64 -e '
    path, encoded = ARGV
    bytes = Base64.strict_decode64(encoded)
    flags = File::WRONLY | File::CREAT | File::EXCL
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    File.open(path, flags, 0600) do |file|
      file.write(bytes)
      file.flush
      file.fsync
    end
  ' "$1" "$2"
}
adopt_lock_lstat_id() { ruby -e 'st = File.lstat(ARGV[0]); print "#{st.dev}:#{st.ino}"' "$1"; }
adopt_lock_parse_owner_b64() {
  ruby -rbase64 -e '
    encoded = ARGV[0]
    exit 0 if encoded.to_s.empty?
    begin
      owner = Base64.strict_decode64(encoded)
    rescue ArgumentError
      exit 0
    end
    match = /\A([1-9][0-9]*) ([A-Za-z0-9._-]+) ([A-Za-z0-9._-]+)\n\z/.match(owner)
    exit 0 unless match
    puts match[1]
    puts match[2]
    puts match[3]
  ' "$1"
}
adopt_lock_pid_dead_same_host() {
  ruby -e '
    pid = Integer(ARGV[0], 10)
    begin
      Process.kill(0, pid)
      exit 1
    rescue Errno::ESRCH
      exit 0
    rescue Errno::EPERM
      exit 1
    end
  ' "$1"
}
adopt_lock_release_dir_if_created() {
  path=$1
  expected_id=$2
  [ -n "${expected_id:-}" ] || return 0
  current_id=$(adopt_lock_lstat_id "$path" 2>/dev/null || true)
  [ "$current_id" = "$expected_id" ] || return 0
  rm -f "$path/owner" 2>/dev/null || true
  rmdir "$path" 2>/dev/null || true
}

# The lock is deliberately the same directory lock used by the existing ledger
# writers.  The Ruby worker owns only record preparation; this shell layer owns
# serialization and the final atomic publish.
adopt_with_lock() {
  vault=$1; shift
  ledger="$vault/45_ai-systems/self-growth/proposals"
  [ -d "$ledger" ] || adopt_fail "proposal ledger directory not found"
  lock_dir="$ledger/.lock"; lock_held=0; lock_identity=''; lock_identity_b64=''; lock_dir_id=''; quarantine_attempt=0
  host=$(adopt_hostname) || adopt_fail 'lock-identity-invalid'
  tool=${ADOPT_TOOL:-adopt}
  adopt_lock_validate_identity "$$" "$host" "$tool" || adopt_fail 'lock-identity-invalid'
  lock_identity="$$ $host $tool
"
  lock_identity_b64=$(adopt_lock_identity_b64 "$lock_identity") || adopt_fail 'lock-identity-invalid'
  # shellcheck disable=SC2329 # called by traps installed below
  release_adopt_lock() {
    if [ "$lock_held" -eq 1 ] && adopt_lock_owner_matches_b64 "$lock_dir/owner" "$lock_identity_b64"; then
      rm -f "$lock_dir/owner" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
    fi
    lock_held=0
  }
  trap release_adopt_lock EXIT
  trap 'release_adopt_lock; exit 130' INT
  trap 'release_adopt_lock; exit 143' TERM
  trap 'release_adopt_lock; exit 129' HUP
  attempt=0
  while :; do
    if mkdir "$lock_dir" 2>/dev/null; then
      lock_dir_id=$(adopt_lock_lstat_id "$lock_dir" 2>/dev/null || true)
      [ -n "$lock_dir_id" ] || adopt_lock_busy "$lock_dir"
      if ! adopt_lock_write_owner_exclusive_b64 "$lock_dir/owner" "$lock_identity_b64"; then
        adopt_lock_release_dir_if_created "$lock_dir" "$lock_dir_id"
        adopt_lock_busy "$lock_dir"
      fi
      current_id=$(adopt_lock_lstat_id "$lock_dir" 2>/dev/null || true)
      if [ "$current_id" != "$lock_dir_id" ] || ! adopt_lock_owner_matches_b64 "$lock_dir/owner" "$lock_identity_b64"; then
        adopt_lock_release_dir_if_created "$lock_dir" "$lock_dir_id"
        adopt_lock_busy "$lock_dir"
      fi
      lock_held=1
      "$@"
      return
    fi
    current_epoch=$(date +%s)
    lock_epoch=$(file_mtime "$lock_dir" 2>/dev/null || printf 0)
    if [ $((current_epoch - lock_epoch)) -gt 300 ]; then
      owner_b64=$(adopt_lock_owner_base64 "$lock_dir/owner" 2>/dev/null || true)
      ownerless=0
      [ -z "$owner_b64" ] && ownerless=1
      breakable=0
      owner_pid=''
      owner_host=''
      if [ "$ownerless" -eq 0 ]; then
        parsed_owner=$(adopt_lock_parse_owner_b64 "$owner_b64")
        if [ -n "$parsed_owner" ]; then
          owner_pid=$(printf '%s\n' "$parsed_owner" | sed -n '1p')
          owner_host=$(printf '%s\n' "$parsed_owner" | sed -n '2p')
          if [ "$owner_host" = "$host" ] && adopt_lock_pid_dead_same_host "$owner_pid"; then
            breakable=1
          fi
        fi
      fi
      if [ "$ownerless" -eq 1 ] || [ "$breakable" -eq 1 ]; then
        quarantine_attempt=$((quarantine_attempt + 1))
        quarantine="${lock_dir}.quarantine.$$.$quarantine_attempt"
        if mv "$lock_dir" "$quarantine" 2>/dev/null; then
          quarantined_owner_b64=$(adopt_lock_owner_base64 "$quarantine/owner" 2>/dev/null || true)
          if [ "$quarantined_owner_b64" = "$owner_b64" ]; then
            rm -rf "$quarantine" 2>/dev/null || true
            adopt_lock_report_stale "$lock_dir" "$ownerless"
          else
            changed_quarantine="${lock_dir}.quarantine-changed.$$.$quarantine_attempt"
            if ! mv "$quarantine" "$changed_quarantine" 2>/dev/null; then
              adopt_policy_fail 'lock-quarantine-conflict'
            fi
            guard_id=''
            if mkdir "$lock_dir" 2>/dev/null; then
              guard_id=$(adopt_lock_lstat_id "$lock_dir" 2>/dev/null || true)
              if [ -z "$guard_id" ] || ! adopt_lock_write_owner_exclusive_b64 "$lock_dir/owner" "$quarantined_owner_b64"; then
                adopt_lock_release_dir_if_created "$lock_dir" "$guard_id"
                adopt_policy_fail 'lock-quarantine-conflict'
              fi
              current_id=$(adopt_lock_lstat_id "$lock_dir" 2>/dev/null || true)
              if [ "$current_id" != "$guard_id" ] || ! adopt_lock_owner_matches_b64 "$lock_dir/owner" "$quarantined_owner_b64"; then
                adopt_lock_release_dir_if_created "$lock_dir" "$guard_id"
                adopt_policy_fail 'lock-quarantine-conflict'
              fi
            else
              adopt_policy_fail 'lock-quarantine-conflict'
            fi
          fi
          continue
        fi
      fi
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt 10 ] || adopt_lock_busy "$lock_dir"
    sleep 0.5
  done
}

file_mtime() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null; }

adopt_run_worker() {
  root=$(adopt_repo_root) || exit 2
  ruby "$root/scripts/adopt-update.rb" "$@"
}
