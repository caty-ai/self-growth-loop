#!/usr/bin/env bash
# Reconcile terminal engine trial tasks into the proposal ledger. macOS Bash 3.2 compatible.

set -u
if ! command -v ruby >/dev/null 2>&1; then
  echo "trial-poll.sh: ruby not found on PATH; install ruby to use this repo's scripts" >&2
  exit 127
fi

# Inline Ruby needs a UTF-8 locale (event lines contain multibyte arrows/dashes);
# launchd and other minimal environments provide none.
if [ -z "${LC_ALL:-}" ]; then LC_ALL=en_US.UTF-8; export LC_ALL; fi

usage() {
  cat >&2 <<'EOF'
Usage: trial-poll.sh --vault <root> --workspace <engine-workspace> \
  [--now <ISO8601Z>] [--dry-run]
EOF
}

fail() { echo "trial-poll.sh: $*" >&2; exit 2; }
file_mtime() { ruby -e 'print File.mtime(ARGV.fetch(0)).to_i' "$1"; }

vault=''
workspace=''
now_override=''
dry_run=0

need_value() {
  [ "$#" -ge 2 ] || { usage; exit 2; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --vault|--workspace|--now)
      need_value "$@"
      case "$1" in
        --vault) vault=$2 ;;
        --workspace) workspace=$2 ;;
        --now) now_override=$2 ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=1; shift ;;
    --help) usage; exit 0 ;;
    *) fail "unknown or incomplete option: $1" ;;
  esac
done

[ -n "$vault" ] && [ -n "$workspace" ] || { usage; exit 2; }
[ -d "$workspace" ] || fail "workspace directory not found: $workspace"

ledger_dir="$vault/45_ai-systems/self-growth/proposals"
lock_dir="$ledger_dir/.lock"
[ -d "$ledger_dir" ] || fail "proposal ledger directory not found"

if [ -n "$now_override" ]; then
  timestamp=$(ruby -rtime -e '
    value = ARGV[0]
    abort "invalid" unless value =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
    puts Time.iso8601(value).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  ' "$now_override" 2>/dev/null) || fail "--now must be ISO8601Z (YYYY-MM-DDTHH:MM:SSZ)"
else
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
fi
today=${timestamp%%T*}

lock_held=0
lock_identity=''

release_lock() {
  if [ "$lock_held" -eq 1 ] && [ -f "$lock_dir/owner" ]; then
    current_owner=$(cat "$lock_dir/owner" 2>/dev/null || true)
    if [ "$current_owner" = "$lock_identity" ]; then
      rm -f "$lock_dir/owner" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
    fi
  fi
  lock_held=0
}
on_int() { release_lock; exit 130; }
on_term() { release_lock; exit 143; }
on_hup() { release_lock; exit 129; }
trap release_lock EXIT
trap on_hup HUP
trap on_int INT
trap on_term TERM

acquire_lock() {
  attempt=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    current_epoch=$(date +%s)
    lock_mtime=$(file_mtime "$lock_dir" 2>/dev/null || printf 0)
    if [ $((current_epoch - lock_mtime)) -gt 300 ]; then
      break_stale=0
      owner=$(cat "$lock_dir/owner" 2>/dev/null || true)
      owner_pid=''; owner_host=''; owner_tool=''; owner_extra=''
      IFS=' ' read -r owner_pid owner_host owner_tool owner_extra <<EOF
$owner
EOF
      if [ -n "$owner_extra" ] || [ -z "$owner_pid" ] || [ -z "$owner_host" ] || [ -z "$owner_tool" ]; then
        break_stale=1
      elif [ "$owner_host" = "$(hostname)" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
        break_stale=1
      fi
      if [ "$break_stale" -eq 1 ]; then
        quarantine="$lock_dir.stale.$$.$attempt"
        if mv "$lock_dir" "$quarantine" 2>/dev/null; then
          quarantined_owner=$(cat "$quarantine/owner" 2>/dev/null || true)
          if [ "$quarantined_owner" = "$owner" ]; then
            rm -rf "$quarantine"
            echo "STALE_LOCK_BROKEN $lock_dir"
          else
            mv "$quarantine" "$lock_dir" 2>/dev/null || true
          fi
        fi
        continue
      fi
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt 10 ] || fail "lock busy after 10 retries: $lock_dir"
    sleep 0.5
  done
  lock_identity="$$ $(hostname) trial-poll.sh"
  owner_tmp="$lock_dir/.owner.$$"
  if ! printf '%s\n' "$lock_identity" > "$owner_tmp" || ! mv "$owner_tmp" "$lock_dir/owner"; then
    rm -f "$owner_tmp"
    fail "cannot write lock owner"
  fi
  lock_held=1
}

[ "$dry_run" -eq 1 ] || acquire_lock

DRY_RUN="$dry_run" LEDGER="$ledger_dir" WORKSPACE="$workspace" NOW="$timestamp" TODAY="$today" ruby -rjson -ryaml -rtime -e '
  def load_record(path)
    raw = File.binread(path)
    raise "invalid UTF-8" unless raw.force_encoding("UTF-8").valid_encoding?
    return nil if raw.match?(/\AMERGED_INTO:/)
    lines = raw.lines
    raise "frontmatter missing" unless lines.first == "---\n"
    finish = lines[1, 200].to_a.index("---\n")
    raise "frontmatter unbounded or missing terminator" unless finish
    finish += 1
    data = YAML.respond_to?(:unsafe_load) ? YAML.unsafe_load(lines[0..finish].join) : YAML.load(lines[0..finish].join)
    raise "frontmatter is not a mapping" unless data.is_a?(Hash)
    [lines, finish, data]
  end

  def damaged(path, message)
    warn "DAMAGED_EVIDENCE #{File.basename(path, ".md")}: #{message}"
  end

  def terminal_dir(root, task_id)
    path = File.join(root, task_id)
    File.directory?(path) ? path : nil
  end

  def evidence_for(path, data, delivered_root, dlq_root, workspace)
    topic = data["topic_key"].to_s
    raise "topic_key is missing" if topic.empty?
    prefix = "sgl-trial-#{topic}-"
    bundle = data.dig("links", "trial_bundle").to_s
    task_id = File.basename(bundle.sub(%r{/+\z}, ""))
    raise "links.trial_bundle has no task id" if task_id.empty? || task_id == "."
    raise "task id #{task_id.inspect} does not match #{prefix.inspect}" unless task_id.start_with?(prefix)
    expected_bundle = "loop/artifacts/#{task_id}/"
    raise "links.trial_bundle must equal #{expected_bundle.inspect}" unless bundle == expected_bundle

    delivered = terminal_dir(delivered_root, task_id)
    dlq = terminal_dir(dlq_root, task_id)
    raise "task #{task_id} exists in both delivered and dlq" if delivered && dlq
    return nil unless delivered || dlq

    terminal_status = delivered ? "delivered" : "dlq"
    state_path = File.join(workspace, "loop", "artifacts", task_id, "state.json")
    raise "missing artifact state.json for task #{task_id}" unless File.file?(state_path)
    state = JSON.parse(File.read(state_path))
    raise "artifact state.json is not an object for task #{task_id}" unless state.is_a?(Hash)
    raise "artifact status #{state["status"].inspect} does not match #{terminal_status}" unless state["status"] == terminal_status
    [task_id, bundle, delivered ? "COUNCIL" : "DLQ"]
  end

  def prepare(path, lines, finish, target, timestamp, today, task_id, bundle)
    seen = {}
    output = []
    lines.each_with_index do |line, index|
      if index <= finish
        case line
        when /^state:/
          output << "state: #{target}\n"; seen["state"] = true
        when /^state_entered_at:/
          output << "state_entered_at: #{timestamp}\n"; seen["state_entered_at"] = true
        when /^updated:/
          output << "updated: #{today}\n"; seen["updated"] = true
        else
          output << line
        end
      else
        output << line
      end
    end
    missing = %w[state state_entered_at updated].reject { |key| seen[key] }
    raise "missing literal keys: #{missing.join(", ")}" unless missing.empty?
    rationale = if target == "COUNCIL"
      "task #{task_id} delivered; trial bundle at #{bundle}"
    else
      "task #{task_id} abandoned to engine DLQ"
    end
    output << "- #{timestamp} alpha TRIALING→#{target} — #{rationale}\n"
    temp = File.join(File.dirname(path), ".#{File.basename(path)}.trial-poll.#{$$}.#{rand(1_000_000)}")
    mode = File.stat(path).mode & 07777
    File.open(temp, "w", mode) { |file| file.write(output.join); file.flush; file.fsync }
    File.chmod(mode, temp)
    parsed = YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(temp) : YAML.load_file(temp)
    raise "semantic postcondition failed for state" unless parsed["state"].to_s == target
    entered = parsed["state_entered_at"]
    entered = entered.iso8601 if entered.respond_to?(:iso8601)
    raise "semantic postcondition failed for state_entered_at" unless Time.iso8601(entered.to_s).utc == Time.iso8601(timestamp).utc
    raise "semantic postcondition failed for updated" unless parsed["updated"].to_s == today
    temp
  rescue StandardError
    File.delete(temp) if defined?(temp) && temp && File.exist?(temp)
    raise
  end

  dry_run = ENV.fetch("DRY_RUN") == "1"
  delivered_root = File.join(ENV.fetch("WORKSPACE"), "loop", "tasks", "delivered")
  dlq_root = File.join(ENV.fetch("WORKSPACE"), "loop", "tasks", "dlq")
  plans = []
  damaged_records = false
  begin
    Dir.glob(File.join(ENV.fetch("LEDGER"), "*.md")).sort.each do |path|
      begin
      loaded = load_record(path)
      next unless loaded
      lines, finish, data = loaded
      next unless data["state"].to_s == "TRIALING"
      evidence = evidence_for(path, data, delivered_root, dlq_root, ENV.fetch("WORKSPACE"))
      next unless evidence
      task_id, bundle, target = evidence
      if dry_run
        puts "PLAN #{File.basename(path, ".md")}: TRIALING→#{target} task #{task_id}"
      else
        plans << [path, prepare(path, lines, finish, target, ENV.fetch("NOW"), ENV.fetch("TODAY"), task_id, bundle), target, task_id]
      end
      rescue StandardError => error
        damaged_records = true
        damaged(path, error.message)
      end
    end
    plans.each do |path, temp, target, task_id|
      File.rename(temp, path)
      puts "TRANSITION #{File.basename(path, ".md")}: TRIALING→#{target} task #{task_id}"
    end
  ensure
    plans.each do |_path, temp, _target, _task_id|
      File.delete(temp) if File.exist?(temp)
    end
  end
  exit 1 if damaged_records
' || fail "poll sweep failed; inspect the ledger and workspace"
