#!/usr/bin/env bash
# Enqueue an approved proposal as an isolated engine trial. macOS Bash 3.2 compatible.

set -u
if ! command -v ruby >/dev/null 2>&1; then
  echo "trial-enqueue.sh: ruby not found on PATH; install ruby to use this repo's scripts" >&2
  exit 127
fi

# locale-select begin
case "${LC_ALL:-}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*)
    ;;
  *)
    sgl_locale_output=$(locale -a 2>/dev/null || printf '')
    sgl_selected_locale=''
    while IFS= read -r sgl_locale_name; do
      case "$sgl_locale_name" in
        [Ee][Nn]_[Uu][Ss].[Uu][Tt][Ff]-8|[Ee][Nn]_[Uu][Ss].[Uu][Tt][Ff]8)
          sgl_selected_locale=en_US.UTF-8
          break
          ;;
      esac
    done <<EOF
$sgl_locale_output
EOF
    if [ -z "$sgl_selected_locale" ]; then
      while IFS= read -r sgl_locale_name; do
        case "$sgl_locale_name" in
          [Cc].[Uu][Tt][Ff]-8|[Cc].[Uu][Tt][Ff]8)
            sgl_selected_locale=C.UTF-8
            break
            ;;
        esac
      done <<EOF
$sgl_locale_output
EOF
    fi
    LC_ALL=${sgl_selected_locale:-C.UTF-8}
    export LC_ALL
    ;;
esac
# locale-select end

usage() {
  cat >&2 <<'EOF'
Usage: trial-enqueue.sh --vault <root> --topic <topic_key> \
  --executor-agent <slug> --executor-model <name> \
  --workspace <engine-workspace> --engine <engine-repo-or-pinned-checkout> \
  [--retry-from <prior-task-id>] [--sho-approved] [--now <ISO8601Z>] [--dry-run]
EOF
}

fail() { echo "trial-enqueue.sh: $*" >&2; exit 2; }
policy_fail() { echo "trial-enqueue.sh: $*" >&2; exit 3; }
utc_timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
file_mtime() { ruby -e 'print File.mtime(ARGV.fetch(0)).to_i' "$1"; }
yaml_check() { ruby -ryaml -rdate -rtime -e '
  path = ARGV.fetch(0)
  abort "YAML too large" if File.size(path) > 1_048_576
  YAML.safe_load(File.binread(path), permitted_classes: [Date, Time], aliases: false)
' "$1" >/dev/null 2>&1; }

reject_control_chars() {
  if ruby -e 'exit(ARGV[0].bytes.any? { |b| b <= 31 || b == 127 } ? 0 : 1)' "$1"; then
    fail "$2 must not contain control characters"
  fi
}

reject_fence_token() {
  case "$1" in
    *'```'*) fail "$2 must not contain a code fence token" ;;
  esac
}

vault=''
topic_key=''
executor_agent=''
executor_model=''
workspace=''
engine=''
now_override=''
sho_approved=0
dry_run=0
retry_from=''

need_value() {
  [ "$#" -ge 2 ] || { usage; exit 2; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --vault|--topic|--executor-agent|--executor-model|--workspace|--engine|--now|--retry-from)
      need_value "$@"
      case "$1" in
        --vault) vault=$2 ;;
        --topic) topic_key=$2 ;;
        --executor-agent) executor_agent=$2 ;;
        --executor-model) executor_model=$2 ;;
        --workspace) workspace=$2 ;;
        --engine) engine=$2 ;;
        --now) now_override=$2 ;;
        --retry-from) retry_from=$2 ;;
      esac
      shift 2
      ;;
    --sho-approved) sho_approved=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --help) usage; exit 0 ;;
    *) fail "unknown or incomplete option: $1" ;;
  esac
done

[ -n "$vault" ] && [ -n "$topic_key" ] && [ -n "$executor_agent" ] && \
  [ -n "$executor_model" ] && [ -n "$workspace" ] && [ -n "$engine" ] || {
  usage
  exit 2
}

topic_re='^[a-z0-9]+(-[a-z0-9]+)*__[a-z0-9]+(-[a-z0-9]+)*(__v[0-9]+)?$'
agent_re='^[a-z0-9_-]+$'
printf '%s\n' "$topic_key" | grep -Eq "$topic_re" || fail "invalid topic key: $topic_key"
printf '%s\n' "$executor_agent" | grep -Eq "$agent_re" || fail "invalid executor-agent slug"
reject_control_chars "$executor_model" executor-model
reject_control_chars "$vault" vault
reject_fence_token "$vault" vault
reject_control_chars "$workspace" workspace
reject_fence_token "$workspace" workspace

[ -d "$workspace" ] || fail "workspace directory not found: $workspace"
[ -r "$engine/templates/TASK.tmpl.md" ] || fail "engine task template not readable"
[ -x "$engine/scripts/tr-enqueue" ] || fail "engine tr-enqueue not executable"

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd) || exit 2
packet_template="$repo_root/templates/TRIAL-PACKET.tmpl.md"
[ -r "$packet_template" ] || fail "trial packet template not readable"

ledger_dir="$vault/45_ai-systems/self-growth/proposals"
record="$ledger_dir/$topic_key.md"
council_dir="$vault/45_ai-systems/self-growth/council/$topic_key"
packet_dir="$vault/45_ai-systems/self-growth/trial-packets"
lock_dir="$ledger_dir/.lock"
[ -d "$ledger_dir" ] || fail "proposal ledger directory not found"
[ -r "$record" ] || fail "proposal record not readable: $topic_key"

retry_mode=0
retry_plan=''
retry_plan_file=''
if [ -n "$retry_from" ]; then
  retry_mode=1
  task_re="^sgl-trial-$topic_key-[0-9]{8}t[0-9]{6}$"
  reject_control_chars "$retry_from" retry-from
  printf '%s\n' "$retry_from" | grep -Eq "$task_re" || fail "invalid prior task id: $retry_from"
  retry_plan_file="$council_dir/$retry_from.retry-plan.md"
fi

if [ -n "$now_override" ]; then
  timestamp=$(ruby -rtime -e '
    value = ARGV[0]
    abort "invalid" unless value =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
    puts Time.iso8601(value).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  ' "$now_override" 2>/dev/null) || fail "--now must be ISO8601Z (YYYY-MM-DDTHH:MM:SSZ)"
else
  timestamp=$(utc_timestamp)
fi
today=${timestamp%%T*}
task_stamp=$(printf '%s' "$timestamp" | sed 's/-//g; s/T/t/; s/://g; s/Z$//')
task_id="sgl-trial-$topic_key-$task_stamp"
[ "${#task_id}" -le 128 ] || fail "task id exceeds engine limit after topic sanitization"

lock_held=0
lock_identity=''
temp_dir=''
task_file=''
packet_temp=''
ledger_temp=''
packet_path=''
packet_installed=0
ledger_committed=0
keep_temp=0
retry_count=''

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

cleanup() {
  release_lock
  if [ "$packet_installed" -eq 1 ] && [ "$ledger_committed" -eq 0 ]; then
    rm -f "$packet_path" 2>/dev/null || true
  fi
  if [ -n "$ledger_temp" ]; then rm -f "$ledger_temp" 2>/dev/null || true; fi
  if [ "$keep_temp" -eq 0 ] && [ -n "$temp_dir" ]; then
    if [ -n "$task_file" ]; then rm -f "$task_file" 2>/dev/null || true; fi
    if [ -n "$packet_temp" ]; then rm -f "$packet_temp" 2>/dev/null || true; fi
    rmdir "$temp_dir" 2>/dev/null || true
  fi
}
on_int() { cleanup; exit 130; }
on_term() { cleanup; exit 143; }
on_hup() { cleanup; exit 129; }
trap cleanup EXIT
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
            if ! mv "$quarantine" "$lock_dir" 2>/dev/null; then
              echo "WARNING: stale lock quarantine could not be restored: $quarantine" >&2
            fi
          fi
        fi
        continue
      fi
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt 10 ] || fail "lock busy after 10 retries: $lock_dir"
    sleep 0.5
  done
  lock_identity="$$ $(hostname) trial-enqueue.sh"
  owner_tmp="$lock_dir/.owner.$$"
  if ! printf '%s\n' "$lock_identity" > "$owner_tmp" || ! mv "$owner_tmp" "$lock_dir/owner"; then
    rm -f "$owner_tmp"
    fail "cannot write lock owner"
  fi
  lock_held=1
}

append_retry_violation() {
  violation_file="$council_dir/$retry_from.violations.md"
  [ "$lock_held" -eq 1 ] || acquire_lock
  mkdir -p "$council_dir" || fail "cannot create council directory for violation log"
  violation_temp=$(mktemp "$council_dir/.${retry_from}.violations.XXXXXX") || fail "cannot create violation log temporary file"
  if ! VIOLATION_FILE="$violation_file" OUT="$violation_temp" LINE="$1" ruby -e '
    prior = File.exist?(ENV.fetch("VIOLATION_FILE")) ? File.binread(ENV.fetch("VIOLATION_FILE")) : ""
    File.open(ENV.fetch("OUT"), "wb") { |file| file.write(prior); file.write(ENV.fetch("LINE")); file.write("\n"); file.flush; file.fsync }
  ' || ! mv "$violation_temp" "$violation_file"; then
    rm -f "$violation_temp"
    fail "cannot atomically append violation log"
  fi
}

retry_violation() {
  code=$1
  detail=$2
  [ "$dry_run" -eq 1 ] || append_retry_violation "- $timestamp trial-enqueue.sh $code — $detail"
  policy_fail "$code — $detail"
}

[ "$dry_run" -eq 1 ] || acquire_lock

record_title=''
risk_tier=''
identity_critical='false'
reversibility=''
state_entered_at=''
trial_bundle=''
preimage_executor_agent=''
preimage_executor_model=''
preimage_updated=''
metadata=$(RECORD="$record" LEDGER="$ledger_dir" EXECUTOR="$executor_agent" NOW="$timestamp" RETRY_MODE="$retry_mode" ruby -ryaml -rtime -rdate -rshellwords -e '
  def load_record(path)
    raw = File.binread(path)
    raise "record too large" if raw.bytesize > 1_048_576
    raise "invalid UTF-8" unless raw.force_encoding("UTF-8").valid_encoding?
    return nil if raw.match?(/\AMERGED_INTO:/)
    lines = raw.lines
    raise "frontmatter missing" unless lines.first == "---\n"
    finish = lines[1, 200].to_a.index("---\n")
    raise "frontmatter unbounded or missing terminator" unless finish
    finish += 1
    data = YAML.safe_load(lines[0..finish].join, permitted_classes: [Date, Time], aliases: false)
    raise "frontmatter is not a mapping" unless data.is_a?(Hash)
    [lines, finish, data]
  end
  begin
    lines, finish, data = load_record(ENV.fetch("RECORD"))
    expected_state = ENV.fetch("RETRY_MODE") == "1" ? "COUNCIL" : "PROPOSED"
    if ENV.fetch("RETRY_MODE") == "1"
      exit 14 unless data["state"].to_s == expected_state
    else
      raise "state must be #{expected_state}" unless data["state"].to_s == expected_state
    end
    retry_count = data["retry_count"]
    if ENV.fetch("RETRY_MODE") == "1"
      exit 13 unless retry_count.is_a?(Integer) && retry_count.between?(0, 2)
      exit 15 if retry_count >= 2
    end
    title = data["title"].to_s
    risk = data["risk_tier"].to_s
    identity_value = data["identity_critical"]
    unless identity_value == true || identity_value == false
      raise "identity_critical must be a YAML boolean"
    end
    identity = identity_value
    reversibility = data["reversibility"].to_s
    raise "title is missing" if title.empty?
    raise "title contains control characters" if title.bytes.any? { |b| b <= 31 || b == 127 }
    raise "risk_tier must be T0, T1, or T2" unless %w[T0 T1 T2].include?(risk)
    if identity && risk != "T2"
      raise "invalid record per spec §2: identity_critical true requires risk_tier T2; fix the record first"
    end
    now = Time.iso8601(ENV.fetch("NOW")).utc
    concurrent = 0
    weekly = 0
    newest_trial_entry = nil
    Dir.glob(File.join(ENV.fetch("LEDGER"), "*.md")).sort.each do |path|
      loaded = load_record(path)
      next unless loaded
      other_lines, other_finish, other = loaded
      concurrent += 1 if other["state"].to_s == "TRIALING" && other["executor_agent"].to_s == ENV.fetch("EXECUTOR")
      other_lines[(other_finish + 1)..-1].to_a.each do |line|
        match = line.match(/^-\s+(\S+)/)
        next unless match && line.match?(/(?:→|->)\s*TRIALING\b/)
        next if line.match?(/\(retry [12]\/2, parent sgl-trial-/)
        begin
          event_time = Time.iso8601(match[1]).utc
        rescue ArgumentError
          next
        end
        newest_trial_entry = event_time if newest_trial_entry.nil? || event_time > newest_trial_entry
        weekly += 1 if event_time <= now && event_time > now - (7 * 86_400)
      end
    end
    if newest_trial_entry && now < newest_trial_entry
      raise "--now must not backdate the ledger"
    end
    if concurrent >= 1
      puts "executor #{ENV.fetch("EXECUTOR")} already has a TRIALING record (max 1)"
      exit 10
    end
    if ENV.fetch("RETRY_MODE") != "1" && weekly >= 3
      puts "family already has 3 TRIALING-entry events in the trailing 7 days"
      exit 11
    end
    values = {
      "record_title" => title,
      "risk_tier" => risk,
      "identity_critical" => identity ? "true" : "false",
      "reversibility" => reversibility,
      "state_entered_at" => (data["state_entered_at"].respond_to?(:iso8601) ? data["state_entered_at"].utc.iso8601 : data["state_entered_at"].to_s),
      "trial_bundle" => data.dig("links", "trial_bundle").to_s,
      "retry_count" => retry_count.to_s,
      "preimage_executor_agent" => data["executor_agent"].to_s,
      "preimage_executor_model" => data["executor_model"].to_s,
      "preimage_updated" => (data["updated"].respond_to?(:iso8601) ? data["updated"].iso8601 : data["updated"].to_s)
    }
    values.each { |key, value| puts "#{key}=#{Shellwords.escape(value)}" }
  rescue StandardError => e
    warn "trial-enqueue.sh: damaged record: #{e.message}"
    exit 12
  end
')
metadata_rc=$?
case "$metadata_rc" in
  0) eval "$metadata" ;;
  10|11) [ "$retry_mode" -eq 1 ] && retry_violation RETRY_BLOCKED_QUOTA "$metadata"; policy_fail "$metadata" ;;
  13) retry_violation RETRY_LIMIT "retry_count must be an integer from 0 to 2" ;;
  14) retry_violation RETRY_NOT_ORDERED "record state must be COUNCIL for a retry" ;;
  15) retry_violation RETRY_LIMIT "retry_count is already 2" ;;
  *) fail "could not validate proposal record" ;;
esac

if [ "$retry_mode" -eq 1 ]; then
  quorum_file="$council_dir/$retry_from.quorum.md"
  manifest_file="$council_dir/$retry_from.convene.yaml"
  if [ "$trial_bundle" != "loop/artifacts/$retry_from/" ]; then
    retry_violation RETRY_NOT_ORDERED "retry-from is not the record's current trial round"
  fi
  if [ ! -r "$quorum_file" ] || [ ! -r "$manifest_file" ] || ! QUORUM="$quorum_file" MANIFEST="$manifest_file" RETRY_FROM="$retry_from" ruby -ryaml -rdate -rtime -e '
    def safe_yaml(path)
      raw = File.binread(path)
      raise "file too large" if raw.bytesize > 1_048_576
      raise "invalid UTF-8" unless raw.force_encoding("UTF-8").valid_encoding?
      YAML.safe_load(raw, permitted_classes: [Date, Time], aliases: false)
    end
    quorum_raw = File.binread(ENV.fetch("QUORUM"))
    raise "quorum too large" if quorum_raw.bytesize > 1_048_576
    lines = quorum_raw.lines
    raise "quorum frontmatter missing" unless lines.first == "---\n"
    finish = lines[1, 200].to_a.index("---\n")
    raise "quorum frontmatter unbounded or missing terminator" unless finish
    quorum = YAML.safe_load(lines[0..finish + 1].join, permitted_classes: [Date, Time], aliases: false)
    manifest = safe_yaml(ENV.fetch("MANIFEST"))
    abort unless quorum.is_a?(Hash) && quorum["schema"].to_s == "sgl-council-quorum/v1" && quorum["task_id"].to_s == ENV.fetch("RETRY_FROM") && quorum["decision"].to_s == "RETRY"
    abort unless manifest.is_a?(Hash) && manifest["sealed"] == true && manifest["decision"].to_s == "RETRY"
  '; then
    retry_violation RETRY_NOT_ORDERED "sealed RETRY quorum evidence is missing for $retry_from"
  fi
  [ -s "$retry_plan_file" ] || retry_violation RETRY_PLAN_MISSING "retry plan is missing or empty: $retry_plan_file"
  retry_plan=$retry_plan_file
fi

if { [ "$risk_tier" = T2 ] || [ "$identity_critical" = true ]; } && [ "$sho_approved" -ne 1 ]; then
  policy_fail "risk_tier T2 or identity_critical true requires --sho-approved"
fi

case "$risk_tier" in
  T0) isolation_level='T0: dedicated git worktree or disposable scratch directory' ;;
  T1) isolation_level='T1: worktree/scratch; secrets-clean environment for a new tool, SDK, or MCP server' ;;
  T2) isolation_level='T2: collection-controls prerequisite closed and explicit Sho plan approval required' ;;
esac
[ -n "$reversibility" ] || reversibility='QUALITATIVE-ONLY — no quantitative rollback criterion was recorded; executor must resolve before acting'

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/sgl-trial-enqueue.XXXXXX") || fail "could not create temporary directory"
task_file="$temp_dir/$task_id.task.md"
packet_temp="$temp_dir/$task_id.packet.md"
packet_path="$packet_dir/$task_id.md"
reject_control_chars "$packet_path" packet_path
reject_fence_token "$packet_path" packet_path
sho_approved_text=false
[ "$sho_approved" -eq 0 ] || sho_approved_text=true

# shellcheck disable=SC2016,SC2034 # Ruby reads these intentional environment values.
TEMPLATE="$packet_template" OUT="$packet_temp" TITLE="$record_title" TOPIC_KEY="$topic_key" \
TASK_ID="$task_id" CREATED_AT="$timestamp" RISK_TIER="$risk_tier" REVERSIBILITY="$reversibility" \
IDENTITY_CRITICAL="$identity_critical" SHO_APPROVED="$sho_approved_text" ISOLATION_LEVEL="$isolation_level" \
EXECUTOR_AGENT="$executor_agent" EXECUTOR_MODEL="$executor_model" RETRY_MODE="$retry_mode" \
RETRY_FROM="$retry_from" RETRY_COUNT="$retry_count" RETRY_PLAN="$retry_plan" ruby -e '
  text = File.read(ENV.fetch("TEMPLATE"))
  values = {
    "TITLE" => ENV.fetch("TITLE"), "TOPIC_KEY" => ENV.fetch("TOPIC_KEY"),
    "TASK_ID" => ENV.fetch("TASK_ID"), "CREATED_AT" => ENV.fetch("CREATED_AT"),
    "RUBRIC" => "- [ ] Execute the approved trial scope without modifying the live checkout.\n- [ ] Produce every required artifact and a delivery receipt.\n- [ ] Demonstrate the recorded rollback criterion without data loss.",
    "RISK_TIER" => ENV.fetch("RISK_TIER"), "REVERSIBILITY" => ENV.fetch("REVERSIBILITY"),
    "IDENTITY_CRITICAL" => ENV.fetch("IDENTITY_CRITICAL"), "SHO_APPROVED" => ENV.fetch("SHO_APPROVED"),
    "ISOLATION_LEVEL" => ENV.fetch("ISOLATION_LEVEL"), "TIME_BUDGET_MIN" => "30",
    "STEP_BUDGET" => "8 attempts", "COST_BUDGET" => "no paid use unless the approved plan states a ceiling",
    "EXECUTOR_AGENT" => ENV.fetch("EXECUTOR_AGENT"), "EXECUTOR_MODEL" => ENV.fetch("EXECUTOR_MODEL")
  }
  values.each { |key, value| text.gsub!("{{#{key}}}", value) }
  if ENV.fetch("RETRY_MODE") == "1"
    metadata = "- Parent task: #{ENV.fetch("RETRY_FROM")}\n- Retry: #{ENV.fetch("RETRY_COUNT").to_i + 1} of 2\n"
    marker = "- Created: `#{ENV.fetch("CREATED_AT")}`\n"
    raise "packet metadata marker missing" unless text.include?(marker)
    text.sub!(marker, marker + metadata)
    plan_path = ENV.fetch("RETRY_PLAN")
    plan = File.binread(plan_path)
    raise "retry plan is invalid UTF-8" unless plan.force_encoding("UTF-8").valid_encoding?
    provenance = "council/#{ENV.fetch("TOPIC_KEY")}/#{ENV.fetch("RETRY_FROM")}.retry-plan.md"
    text << "\n## Retry plan\n\n- Provenance: `#{provenance}`\n\n#{plan}"
    text << "\n" unless text.end_with?("\n")
  end
  File.open(ENV.fetch("OUT"), "w") { |file| file.write(text) }
' || fail "could not render trial packet"

# The Ruby renderer intentionally writes the literal engine variable into donecheck.
# shellcheck disable=SC2016
ENGINE_TEMPLATE="$engine/templates/TASK.tmpl.md" OUT="$task_file" TASK_ID="$task_id" \
TITLE="$record_title" CREATED_AT="$timestamp" PACKET_PATH="$packet_path" ruby -rjson -e '
  text = File.read(ENV.fetch("ENGINE_TEMPLATE"))
  values = {
    "TASK_ID" => ENV.fetch("TASK_ID"),
    "TITLE" => ENV.fetch("TITLE").to_json,
    "CREATED_UTC" => ENV.fetch("CREATED_AT"),
    "GOAL" => "Execute the approved self-growth trial packet at `#{ENV.fetch("PACKET_PATH")}` and produce its complete artifact bundle.",
    "STEP_1" => "read the trial packet, verify its preconditions, execute the bounded trial, and write the full bundle",
    "RESOURCE_PATH_OR_ENV_NAME" => ENV.fetch("PACKET_PATH"),
    "NON_GOAL" => "production rollout, adoption, or work outside the approved trial packet"
  }
  values.each { |key, value| text.gsub!("{{#{key}}}", value) }
  marker = "```donecheck\n"
  raise "donecheck marker missing from engine template" unless text.include?(marker)
  bundle = %w[run.log env-manifest.txt config-diff.txt permissions.md cost.txt attempts.md repro.md rollback-test.md]
  checks = bundle.map { |name| "test -s \"$ARTIFACT_DIR/out/bundle/#{name}\" || { echo \"FAIL: bundle/#{name} missing or empty\"; exit 1; }" }.join("\n") + "\n"
  text.sub!(marker, marker + checks)
  pairs = text.scan(/^```donecheck[ \t]*\n.*?^```[ \t]*$/m)
  raise "rendered task must contain exactly one donecheck fence pair" unless pairs.length == 1
  File.open(ENV.fetch("OUT"), "w") { |file| file.write(text) }
' || fail "could not render engine task"

if [ "$dry_run" -eq 1 ]; then
  keep_temp=1
  printf '%s\n' "$task_file"
  exit 0
fi

mkdir -p "$packet_dir" || fail "cannot create trial packet directory"
[ ! -e "$packet_path" ] || fail "trial packet already exists: $packet_path"
mv "$packet_temp" "$packet_path" || fail "could not install trial packet"
packet_installed=1

ledger_temp="$ledger_dir/.$topic_key.trial-enqueue.$$"
RECORD="$record" OUT="$ledger_temp" STATE_ENTERED_AT="$timestamp" UPDATED="$today" \
EXECUTOR_AGENT="$executor_agent" EXECUTOR_MODEL="$executor_model" TRIAL_BUNDLE="loop/artifacts/$task_id/" \
RISK_TIER="$risk_tier" TASK_ID="$task_id" RETRY_MODE="$retry_mode" RETRY_COUNT="$retry_count" \
RETRY_FROM="$retry_from" ruby -ryaml -rjson -rtime -rdate -e '
  lines = File.readlines(ENV.fetch("RECORD"))
  finish = lines[1, 200].to_a.index("---\n")
  raise "frontmatter unbounded or missing terminator" unless finish
  finish += 1
  seen = {}
  in_links = false
  output = []
  lines.each_with_index do |line, index|
    if index <= finish
      case line
      when /^state:/
        output << "state: TRIALING\n"; seen["state"] = true
      when /^retry_count:/
        if ENV.fetch("RETRY_MODE") == "1"
          output << "retry_count: #{ENV.fetch("RETRY_COUNT").to_i + 1}\n"; seen["retry_count"] = true
        else
          output << line
        end
      when /^state_entered_at:/
        output << "state_entered_at: #{ENV.fetch("STATE_ENTERED_AT")}\n"; seen["state_entered_at"] = true
      when /^risk_tier:/
        output << "risk_tier: #{ENV.fetch("RISK_TIER")}\n"; seen["risk_tier"] = true
      when /^executor_agent:/
        output << "executor_agent: #{ENV.fetch("EXECUTOR_AGENT").to_json}\n"; seen["executor_agent"] = true
      when /^executor_model:/
        output << "executor_model: #{ENV.fetch("EXECUTOR_MODEL").to_json}\n"; seen["executor_model"] = true
      when /^updated:/
        output << "updated: #{ENV.fetch("UPDATED")}\n"; seen["updated"] = true
      when /^links:/
        output << line; in_links = true
      when /^\S/
        in_links = false
        output << line
      when /^  trial_bundle:/
        raise "trial_bundle is outside links" unless in_links
        output << "  trial_bundle: #{ENV.fetch("TRIAL_BUNDLE").to_json}\n"; seen["trial_bundle"] = true
      else
        output << line
      end
    else
      output << line
    end
  end
  required = %w[state state_entered_at risk_tier executor_agent executor_model updated trial_bundle]
  required << "retry_count" if ENV.fetch("RETRY_MODE") == "1"
  missing = required.reject { |key| seen[key] }
  raise "missing literal keys: #{missing.join(", ")}" unless missing.empty?
  if ENV.fetch("RETRY_MODE") == "1"
    output << "- #{ENV.fetch("STATE_ENTERED_AT")} alpha COUNCIL→TRIALING — task #{ENV.fetch("TASK_ID")} (retry #{ENV.fetch("RETRY_COUNT").to_i + 1}/2, parent #{ENV.fetch("RETRY_FROM")}) enqueued; trial bundle at #{ENV.fetch("TRIAL_BUNDLE")}\n"
  else
    output << "- #{ENV.fetch("STATE_ENTERED_AT")} alpha PROPOSED→TRIALING — task #{ENV.fetch("TASK_ID")} enqueued; trial bundle at #{ENV.fetch("TRIAL_BUNDLE")}\n"
  end
  mode = File.stat(ENV.fetch("RECORD")).mode & 07777
  File.open(ENV.fetch("OUT"), "w", mode) { |file| file.write(output.join); file.flush; file.fsync }
  File.chmod(mode, ENV.fetch("OUT"))
  raw = File.binread(ENV.fetch("OUT"))
  raise "output too large" if raw.bytesize > 1_048_576
  parsed = YAML.safe_load(raw, permitted_classes: [Date, Time], aliases: false)
  expected = {
    "state" => "TRIALING", "risk_tier" => ENV.fetch("RISK_TIER"), "executor_agent" => ENV.fetch("EXECUTOR_AGENT"),
    "executor_model" => ENV.fetch("EXECUTOR_MODEL"), "updated" => ENV.fetch("UPDATED")
  }
  expected.each { |key, value| raise "semantic postcondition failed for #{key}" unless parsed[key].to_s == value }
  entered = parsed["state_entered_at"]
  entered = entered.iso8601 if entered.respond_to?(:iso8601)
  raise "semantic postcondition failed for state_entered_at" unless Time.iso8601(entered.to_s).utc == Time.iso8601(ENV.fetch("STATE_ENTERED_AT")).utc
  raise "semantic postcondition failed for links.trial_bundle" unless parsed.dig("links", "trial_bundle").to_s == ENV.fetch("TRIAL_BUNDLE")
  if ENV.fetch("RETRY_MODE") == "1"
    raise "semantic postcondition failed for retry_count" unless parsed["retry_count"] == ENV.fetch("RETRY_COUNT").to_i + 1
  end
' || fail "could not prepare ledger transition"
yaml_check "$ledger_temp" || fail "YAML validation failed; no ledger change committed"
trap '' HUP INT TERM
mv "$ledger_temp" "$record" || fail "could not commit ledger transition before engine enqueue: $record"
ledger_temp=''
ledger_committed=1

enqueue_status=0
"$engine/scripts/tr-enqueue" "$task_file" "$workspace" || enqueue_status=$?
if [ "$enqueue_status" -ne 0 ]; then
  if [ "$enqueue_status" -eq 3 ]; then
    echo "trial-enqueue.sh: tr-enqueue exit 3: engine workspace paused or uninitialized (no STATE.md/loop/); check pause state, or initialize with $engine/scripts/loop-init --workspace $workspace" >&2
  fi
  revert_temp="$ledger_dir/.$topic_key.trial-revert.$$"
  if RECORD="$record" OUT="$revert_temp" UPDATED="$preimage_updated" TASK_ID="$task_id" TIMESTAMP="$timestamp" STATE_ENTERED_AT="$state_entered_at" TRIAL_BUNDLE="$trial_bundle" \
EXECUTOR_AGENT="$preimage_executor_agent" EXECUTOR_MODEL="$preimage_executor_model" RETRY_MODE="$retry_mode" RETRY_COUNT="$retry_count" ruby -rjson -rtime -rdate -ryaml -e '
    lines = File.readlines(ENV.fetch("RECORD"))
    finish = lines[1, 200].to_a.index("---\n")
    raise "frontmatter unbounded or missing terminator" unless finish
    finish += 1
    output = []
    in_links = false
    lines.each_with_index do |line, index|
      if index <= finish
        case line
        when /^state:/ then output << "state: #{ENV.fetch("RETRY_MODE") == "1" ? "COUNCIL" : "PROPOSED"}\n"
        when /^retry_count:/
          output << (ENV.fetch("RETRY_MODE") == "1" ? "retry_count: #{ENV.fetch("RETRY_COUNT")}\n" : line)
        when /^state_entered_at:/ then output << "state_entered_at: #{ENV.fetch("STATE_ENTERED_AT")}\n"
        when /^executor_agent:/ then output << "executor_agent: #{ENV.fetch("EXECUTOR_AGENT").to_json}\n"
        when /^executor_model:/ then output << "executor_model: #{ENV.fetch("EXECUTOR_MODEL").to_json}\n"
        when /^updated:/ then output << "updated: #{ENV.fetch("UPDATED")}\n"
        when /^links:/ then in_links = true; output << line
        when /^\S/ then in_links = false; output << line
        when /^  trial_bundle:/
          raise "trial_bundle is outside links" unless in_links
          output << "  trial_bundle: #{ENV.fetch("TRIAL_BUNDLE").to_json}\n"
        else output << line
        end
      else
        forward_event = /\A- #{Regexp.escape(ENV.fetch("TIMESTAMP"))} alpha (?:PROPOSED|COUNCIL)→TRIALING — task #{Regexp.escape(ENV.fetch("TASK_ID"))}(?:\s|$)/
        output << line unless line.match?(forward_event)
      end
    end
    prior_state = ENV.fetch("RETRY_MODE") == "1" ? "COUNCIL" : "PROPOSED"
    output << "- #{ENV.fetch("TIMESTAMP")} alpha TRIALING→#{prior_state} — compensating transition after engine enqueue failed for task #{ENV.fetch("TASK_ID")}\n"
    mode = File.stat(ENV.fetch("RECORD")).mode & 07777
    File.open(ENV.fetch("OUT"), "w", mode) { |file| file.write(output.join); file.flush; file.fsync }
    File.chmod(mode, ENV.fetch("OUT"))
    raw = File.binread(ENV.fetch("OUT"))
    raise "output too large" if raw.bytesize > 1_048_576
    parsed = YAML.safe_load(raw, permitted_classes: [Date, Time], aliases: false)
    prior_state = ENV.fetch("RETRY_MODE") == "1" ? "COUNCIL" : "PROPOSED"
    raise "semantic postcondition failed for state" unless parsed["state"].to_s == prior_state
    entered = parsed["state_entered_at"]
    entered = entered.iso8601 if entered.respond_to?(:iso8601)
    raise "semantic postcondition failed for state_entered_at" unless Time.iso8601(entered.to_s).utc == Time.iso8601(ENV.fetch("STATE_ENTERED_AT")).utc
    raise "semantic postcondition failed for links.trial_bundle" unless parsed.dig("links", "trial_bundle").to_s == ENV.fetch("TRIAL_BUNDLE")
    raise "semantic postcondition failed for executor_agent" unless parsed["executor_agent"].to_s == ENV.fetch("EXECUTOR_AGENT")
    raise "semantic postcondition failed for executor_model" unless parsed["executor_model"].to_s == ENV.fetch("EXECUTOR_MODEL")
    updated = parsed["updated"]
    updated = updated.iso8601 if updated.respond_to?(:iso8601)
    raise "semantic postcondition failed for updated" unless updated.to_s == ENV.fetch("UPDATED")
    if ENV.fetch("RETRY_MODE") == "1"
      raise "semantic postcondition failed for retry_count" unless parsed["retry_count"] == ENV.fetch("RETRY_COUNT").to_i
    end
  ' && yaml_check "$revert_temp" && mv "$revert_temp" "$record"; then
    rm -f "$packet_path" || fail "engine enqueue failed; ledger reverted but could not remove trial packet"
    packet_installed=0
    ledger_committed=0
    trap on_hup HUP; trap on_int INT; trap on_term TERM
    prior_state=PROPOSED
    [ "$retry_mode" -eq 0 ] || prior_state=COUNCIL
    fail "engine enqueue failed; ledger reverted to $prior_state for task $task_id"
  fi
  rm -f "$revert_temp" 2>/dev/null || true
  trap on_hup HUP; trap on_int INT; trap on_term TERM
  fail "ENGINE ENQUEUE FAILED; ledger revert also failed, leaving TRIALING for task $task_id"
fi
trap on_hup HUP; trap on_int INT; trap on_term TERM
printf '%s\n' "$workspace/loop/tasks/queue/$task_id.task.md"
