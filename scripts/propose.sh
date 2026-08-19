#!/usr/bin/env bash
# Create or append a proposal-ledger record. Compatible with macOS bash 3.2.

set -u
if ! command -v ruby >/dev/null 2>&1; then
  echo "propose.sh: ruby not found on PATH; install ruby to use this repo's scripts" >&2
  exit 127
fi

# Inline Ruby renders UTF-8 event text even under minimal launchd-style
# environments, so keep its locale explicit and portable.
case "${LC_ALL:-}" in *UTF-8*|*utf8*) ;; *) LC_ALL=en_US.UTF-8; export LC_ALL ;; esac

usage() {
  cat >&2 <<'EOF'
Usage: propose.sh --vault <vault-root> --topic-key <key> --title <title> \
  --state <PROPOSED|WATCH> --proposer <agent> --url <source-url> \
  --report <report-relpath> [--risk-tier T0|T1|T2] [--identity-critical] \
  [--reversibility <text>] [--judgement <text>] [--actor <name>] \
  [--materially-new <security-fix|human-bump> --evidence <ref>] \
  [--supersedes <old-key>] [--now <ISO8601Z>]
EOF
}

fail() { echo "propose.sh: $*" >&2; exit 2; }
damaged() { echo "DAMAGED $1 $2" >&2; exit 3; }

reject_control_chars() {
  if ruby -e 'exit(ARGV[0].bytes.any? { |b| b <= 31 || b == 127 } ? 0 : 1)' "$1"; then
    fail "$2 must not contain control characters"
  fi
}

utc_timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
utc_date() { date -u '+%Y-%m-%d'; }
file_mtime() { ruby -e 'print File.mtime(ARGV.fetch(0)).to_i' "$1"; }

yaml_check() { ruby -ryaml -e 'YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0])' "$1" >/dev/null 2>&1; }

vault=''; topic_key=''; title=''; state=''; proposer=''; source_url=''; report=''
risk_tier='T0'; risk_tier_explicit=0; identity_critical='false'; reversibility=''
judgement=''; actor='alpha'; materially_new=''; evidence=''; supersedes=''
now_override=''; seen_now=0

need_value() {
  [ "$#" -ge 2 ] || { usage; exit 2; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --vault|--topic-key|--title|--state|--proposer|--url|--report|--risk-tier|--reversibility|--judgement|--actor|--materially-new|--evidence|--supersedes|--now)
      need_value "$@"
      case "$1" in
        --vault) vault=$2 ;; --topic-key) topic_key=$2 ;; --title) title=$2 ;;
        --state) state=$2 ;; --proposer) proposer=$2 ;; --url) source_url=$2 ;;
        --report) report=$2 ;; --risk-tier) risk_tier=$2; risk_tier_explicit=1 ;;
        --reversibility) reversibility=$2 ;; --judgement) judgement=$2 ;;
        --actor) actor=$2 ;; --materially-new) materially_new=$2 ;;
        --evidence) evidence=$2 ;; --supersedes) supersedes=$2 ;;
        --now)
          [ "$seen_now" -eq 0 ] || fail "duplicate option: --now"
          seen_now=1
          now_override=$2
          ;;
      esac
      shift 2 ;;
    --identity-critical) identity_critical='true'; shift ;;
    --help) usage; exit 0 ;;
    *) fail "unknown or incomplete option: $1" ;;
  esac
done

[ -n "$vault" ] && [ -n "$topic_key" ] && [ -n "$title" ] && [ -n "$state" ] && \
  [ -n "$proposer" ] && [ -n "$source_url" ] && [ -n "$report" ] || { usage; exit 2; }

if [ -n "$now_override" ]; then
  pinned_timestamp=$(ruby -rdate -rtime -e '
    value = ARGV[0]
    match = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z\z/.match(value) or abort "invalid"
    year, month, day, hour, minute, second = match.captures.map(&:to_i)
    abort "invalid" unless year.between?(1, 9999) && Date.valid_date?(year, month, day)
    abort "invalid" unless hour < 24 && minute < 60 && second < 60
    puts Time.iso8601(value).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  ' "$now_override" 2>/dev/null) || fail "--now must be ISO8601Z (YYYY-MM-DDTHH:MM:SSZ)"
fi

key_re='^[a-z0-9]+(-[a-z0-9]+)*__[a-z0-9]+(-[a-z0-9]+)*(__v[0-9]+)?$'
printf '%s\n' "$topic_key" | grep -Eq "$key_re" || fail "invalid topic-key: $topic_key"
[ -z "$supersedes" ] || printf '%s\n' "$supersedes" | grep -Eq "$key_re" || fail "invalid supersedes key: $supersedes"
case "$state" in PROPOSED|WATCH) ;; *) fail "state must be PROPOSED or WATCH" ;; esac
case "$risk_tier" in T0|T1|T2) ;; *) fail "risk-tier must be T0, T1, or T2" ;; esac
case "$materially_new" in ''|security-fix|human-bump) ;; *) fail "materially-new must be security-fix or human-bump" ;; esac
if [ -n "$materially_new" ] && [ -z "$evidence" ]; then fail "--evidence is required for materially-new re-entry"; fi
if [ -n "$supersedes" ] && [ -n "$materially_new" ]; then fail "--supersedes cannot be combined with --materially-new"; fi
[ -z "$supersedes" ] || [ "$supersedes" != "$topic_key" ] || fail "new topic-key must differ from --supersedes"

for option_name in title url report reversibility judgement proposer actor evidence; do
  case "$option_name" in
    title) option_value=$title ;; url) option_value=$source_url ;; report) option_value=$report ;;
    reversibility) option_value=$reversibility ;; judgement) option_value=$judgement ;;
    proposer) option_value=$proposer ;; actor) option_value=$actor ;; evidence) option_value=$evidence ;;
  esac
  reject_control_chars "$option_value" "$option_name"
done
agent_re='^[a-z0-9][a-z0-9_-]{0,63}$'
printf '%s\n' "$proposer" | grep -Eq "$agent_re" || fail "invalid proposer"
printf '%s\n' "$actor" | grep -Eq "$agent_re" || fail "invalid actor"

clamp_rationale=''
if [ "$identity_critical" = true ] && [ "$risk_tier" != T2 ]; then
  [ "$risk_tier_explicit" -eq 0 ] || clamp_rationale=' (risk tier clamped to T2 for identity-critical)'
  risk_tier=T2
fi

ledger_dir="$vault/45_ai-systems/self-growth/proposals"
record="$ledger_dir/$topic_key.md"
lock_dir="$ledger_dir/.lock"
template_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
template="$template_dir/templates/PROPOSAL.tmpl.md"
lock_held=0
lock_identity=''
stale_lock_broken=0

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

mkdir -p "$ledger_dir" || { echo "propose.sh: cannot create ledger directory" >&2; exit 1; }

attempt=0
while ! mkdir "$lock_dir" 2>/dev/null; do
  now=$(date +%s); lock_mtime=$(file_mtime "$lock_dir" 2>/dev/null || printf 0)
  if [ $((now - lock_mtime)) -gt 300 ]; then
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
      rm -f "$lock_dir/owner" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || { echo "propose.sh: stale lock could not be removed: $lock_dir" >&2; exit 1; }
      stale_lock_broken=1; echo "STALE_LOCK_BROKEN $lock_dir"; continue
    fi
  fi
  attempt=$((attempt + 1))
  [ "$attempt" -lt 10 ] || { echo "propose.sh: lock busy after 10 retries: $lock_dir" >&2; exit 1; }
  sleep 0.5
done
lock_identity="$$ $(hostname) propose.sh"
owner_tmp="$lock_dir/.owner.$$"
if ! printf '%s\n' "$lock_identity" > "$owner_tmp" || ! mv "$owner_tmp" "$lock_dir/owner"; then
  rm -f "$owner_tmp"; echo "propose.sh: cannot write lock owner" >&2; exit 1
fi
lock_held=1

if [ -n "$now_override" ]; then
  timestamp=$pinned_timestamp
  today=${timestamp%%T*}
else
  timestamp=$(utc_timestamp)
  today=$(utc_date)
fi

validate_record() {
  validation=$(RECORD="$1" ruby -ryaml -e '
    p = ENV["RECORD"]; lines = File.readlines(p)
    abort "frontmatter delimiters" unless lines[0] == "---\n" && (end_i = lines[1..-1].index("---\n"))
    y = YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(p) : YAML.load_file(p); abort "frontmatter is not a mapping" unless y.is_a?(Hash)
    %w[state updated source_items].each { |k| abort "missing required key #{k}" unless y.key?(k) }
    abort "source_items is not a list" unless y["source_items"].is_a?(Array)
  ' 2>&1) || damaged "$1" "$validation"
}

stub_target() {
  sed -n '1,2p' "$1" | ruby -e 's=STDIN.read; puts(Regexp.last_match(1)) if s =~ /\A\s*MERGED_INTO: ([a-z0-9]+(?:-[a-z0-9]+)*__[a-z0-9]+(?:-[a-z0-9]+)*(?:__v[0-9]+)?)\s*\z/'
}

# Construct a complete record in a private temp file, validate YAML, then commit once.
# Arguments: state cooldown add-source transition event rationale [second-event second-rationale]
commit_existing() {
  new_state=$1; new_cooldown=$2; add_source=$3; transition=$4; event_name=$5; rationale=$6
  second_event=${7-}; second_rationale=${8-}
  temp_file="$ledger_dir/.${topic_key}.tmp.$$"
  RECORD="$record" OUT="$temp_file" STATE="$new_state" COOLDOWN="$new_cooldown" ADD_SOURCE="$add_source" \
  TRANSITION="$transition" EVENT_NAME="$event_name" RATIONALE="$rationale" SECOND_EVENT="$second_event" SECOND_RATIONALE="$second_rationale" \
  SOURCE_URL="$source_url" REPORT="$report" TODAY="$today" TIMESTAMP="$timestamp" ACTOR="$actor" \
  IDENTITY_REQUESTED="$identity_critical" ruby -ryaml -rjson -e '
    lines = File.readlines(ENV["RECORD"]); finish = lines[1..-1].index("---\n") + 1
    fm = YAML.respond_to?(:unsafe_load) ? YAML.unsafe_load(lines[0..finish].join) : YAML.load(lines[0..finish].join); requested = ENV["IDENTITY_REQUESTED"] == "true"
    old_identity = fm["identity_critical"] == true; old_risk = fm["risk_tier"]
    force_identity = requested || old_identity; clamp = force_identity && old_risk != "T2"
    out = []; in_items = false; inserted = false
    lines.each_with_index do |line, i|
      if i <= finish
        if line =~ /^state:/ then out << "state: #{ENV["STATE"]}\n"
        elsif line =~ /^state_entered_at:/ then out << "state_entered_at: #{ENV["TRANSITION"] == "true" ? ENV["TIMESTAMP"] : line.split(": ", 2)[1]}"; out << "\n" unless out[-1].end_with?("\n")
        elsif line =~ /^updated:/ then out << "updated: #{ENV["TODAY"]}\n"
        elsif line =~ /^cooldown_until:/ then out << "cooldown_until: #{ENV["COOLDOWN"].to_json}\n"
        elsif line =~ /^identity_critical:/ then out << "identity_critical: #{force_identity}\n"
        elsif line =~ /^risk_tier:/ && force_identity then out << "risk_tier: T2\n"
        elsif line =~ /^source_items:/ then in_items=true; out << line
        elsif in_items && line =~ /^links:/
          if ENV["ADD_SOURCE"] == "true"
            out << "  - url: #{ENV["SOURCE_URL"].to_json}\n    seen: #{ENV["TODAY"]}\n    report: #{ENV["REPORT"].to_json}\n"
          end
          in_items=false; inserted=true; out << line
        else out << line end
      else out << line end
    end
    abort "source_items boundary missing" unless inserted || ENV["ADD_SOURCE"] != "true"
    out << "- #{ENV["TIMESTAMP"]} #{ENV["ACTOR"]} #{ENV["EVENT_NAME"]} — #{ENV["RATIONALE"]}\n"
    if ENV["SECOND_EVENT"] != ""
      out << "- #{ENV["TIMESTAMP"]} #{ENV["ACTOR"]} #{ENV["SECOND_EVENT"]} — #{ENV["SECOND_RATIONALE"]}\n"
    end
    File.open(ENV["OUT"], "w") { |f| f.write(out.join) }
  ' || { rm -f "$temp_file"; echo "propose.sh: could not prepare record update" >&2; exit 1; }
  yaml_check "$temp_file" || { rm -f "$temp_file"; echo "propose.sh: YAML validation failed; no changes committed" >&2; exit 1; }
  mv "$temp_file" "$record" || { rm -f "$temp_file"; echo "propose.sh: could not commit record update" >&2; exit 1; }
}

render_template() {
  TEMPLATE="$template" TOPIC_KEY="$topic_key" TITLE="$title" STATE="$state" RISK_TIER="$risk_tier" \
  IDENTITY_CRITICAL="$identity_critical" PROPOSER="$proposer" SOURCE_URL="$source_url" DATE="$today" REPORT="$report" \
  REVERSIBILITY="$reversibility" JUDGEMENT="$judgement" TIMESTAMP="$timestamp" ACTOR="$actor" CLAMP="$clamp_rationale" ruby -rjson -e '
    s = File.read(ENV["TEMPLATE"]); q = ->(x) { x.to_json }
    values = { "TOPIC_KEY"=>ENV["TOPIC_KEY"], "TITLE"=>q[ENV["TITLE"]], "STATE"=>ENV["STATE"], "RISK_TIER"=>ENV["RISK_TIER"], "IDENTITY_CRITICAL"=>ENV["IDENTITY_CRITICAL"], "PROPOSER"=>ENV["PROPOSER"], "SOURCE_URL"=>q[ENV["SOURCE_URL"]], "DATE"=>ENV["DATE"], "SOURCE_REPORT"=>q[ENV["REPORT"]], "REVERSIBILITY"=>q[ENV["REVERSIBILITY"]], "JUDGEMENT"=>ENV["JUDGEMENT"], "TIMESTAMP"=>ENV["TIMESTAMP"], "ACTOR"=>ENV["ACTOR"], "RATIONALE"=>"intake from #{ENV["REPORT"]}#{ENV["CLAMP"]}" }
    values.each { |k,v| s.gsub!("{{#{k}}}", v) }; print s
  '
}

if [ -n "$supersedes" ]; then
  old_record="$ledger_dir/$supersedes.md"
  [ -f "$old_record" ] || fail "supersedes record does not exist: $supersedes"
  [ ! -f "$record" ] || fail "new version record already exists: $topic_key"
  validate_record "$old_record"
  temp_file="$ledger_dir/.${topic_key}.tmp.$$"
  if ! render_template > "$temp_file" || ! yaml_check "$temp_file" || ! mv "$temp_file" "$record"; then
    rm -f "$temp_file"; echo "propose.sh: could not create superseding proposal" >&2; exit 1
  fi
  # Append the old-file event through the same checked atomic replacement mechanism.
  saved_record=$record; saved_key=$topic_key; record=$old_record; topic_key=$supersedes
  commit_existing "$(ruby -ryaml -e '
    state = (YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]))["state"]
    # legacy-read: PENDING_SHO accepted until v1.0 (issue #10)
    state = "PENDING_OWNER" if state == "PENDING_SHO"
    puts state
  ' "$record")" "$(ruby -ryaml -e 'puts (YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]))["cooldown_until"] || ""' "$record")" false false SUPERSEDED_BY "$saved_key"
  record=$saved_record; topic_key=$saved_key
  echo "CREATED $record"
  exit 0
fi

if [ ! -f "$record" ]; then
  temp_file="$ledger_dir/.${topic_key}.tmp.$$"
  render_template > "$temp_file" || { rm -f "$temp_file"; exit 1; }
  if [ "$stale_lock_broken" -eq 1 ]; then printf '%s\n' "- $timestamp $actor LOCK — stale lock broken before write" >> "$temp_file"; fi
  yaml_check "$temp_file" || { rm -f "$temp_file"; echo "propose.sh: YAML validation failed; no changes committed" >&2; exit 1; }
  mv "$temp_file" "$record" || { rm -f "$temp_file"; echo "propose.sh: could not create proposal" >&2; exit 1; }
  echo "CREATED $record"; exit 0
fi

redirect=$(stub_target "$record")
if [ -n "$redirect" ]; then
  canonical="$ledger_dir/$redirect.md"
  [ -f "$canonical" ] || damaged "$record" "MERGED_INTO target missing"
  [ -z "$(stub_target "$canonical")" ] || damaged "$record" "MERGED_INTO target is also a stub"
  echo "REDIRECTED $topic_key -> $redirect"
  record=$canonical; topic_key=$redirect
fi
validate_record "$record"

existing_state=$(ruby -ryaml -e '
  state = (YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]))["state"]
  # legacy-read: PENDING_SHO accepted until v1.0 (issue #10)
  state = "PENDING_OWNER" if state == "PENDING_SHO"
  puts state
' "$record")
cooldown_until=$(ruby -ryaml -e 'v=(YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]))["cooldown_until"]; puts v unless v.nil?' "$record")
if [ -n "$now_override" ]; then now_iso=$timestamp; else now_iso=$(utc_timestamp); fi
in_cooldown=0
[ -n "$cooldown_until" ] && [[ "$cooldown_until" > "$now_iso" ]] && in_cooldown=1
duplicate=false
SOURCE_URL="$source_url" ruby -ryaml -e 'exit(((YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]))["source_items"] || []).any? { |x| x.is_a?(Hash) && x["url"] == ENV["SOURCE_URL"] } ? 0 : 1)' "$record" && duplicate=true
add_source=true; [ "$duplicate" = true ] && add_source=false

existing_identity=$(ruby -ryaml -e 'puts (YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]))["identity_critical"] == true ? "true" : "false"' "$record")
existing_risk=$(ruby -ryaml -e 'puts (YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]))["risk_tier"]' "$record")
clamp_note=''
if [ "$identity_critical" = true ] || { [ "$existing_identity" = true ] && [ "$existing_risk" != T2 ]; }; then
  clamp_note='IDENTITY_CRITICAL'; clamp_reason='identity-critical routing set/clamped to T2'
fi
lock_event=''; lock_reason=''
if [ "$stale_lock_broken" -eq 1 ]; then lock_event='LOCK'; lock_reason='stale lock broken before write'; fi

second_event=$clamp_note; second_reason=${clamp_reason-}
[ -n "$second_event" ] || { second_event=$lock_event; second_reason=$lock_reason; }

if [ "$existing_state" = ADOPTED ]; then
  commit_existing "$existing_state" "$cooldown_until" "$add_source" false SIGHTING 'already adopted — new sighting' "$second_event" "$second_reason"
  echo "NOTED_ADOPTED $record"; exit 0
fi

if [ "$existing_state" = REJECTED ] || [ "$existing_state" = EXPIRED ] || [ "$existing_state" = DLQ ] || [ "$in_cooldown" -eq 1 ] || { [ "$existing_state" = WATCH ] && [ -n "$materially_new" ]; }; then
  if [ -n "$materially_new" ]; then
    backup_note=''
    if [ "$existing_state" = DLQ ]; then
      backup_dir="$vault/45_ai-systems/self-growth/backups"; mkdir -p "$backup_dir" || exit 1
      if [ -n "$now_override" ]; then
        backup_stamp=$(printf '%s' "$timestamp" | tr -d ':-')
      else
        backup_stamp=$(date -u '+%Y%m%dT%H%M%SZ')
      fi
      backup_path="$backup_dir/proposals-$backup_stamp.tar.gz"
      tar -czf "$backup_path" -C "$vault/45_ai-systems/self-growth" proposals || { echo "propose.sh: DLQ backup failed" >&2; exit 1; }
      backup_note=" backup $backup_path"
    fi
    commit_existing PROPOSED '' "$add_source" true PROPOSED "re-entry ($materially_new) evidence $evidence via $source_url$backup_note" "$second_event" "$second_reason"
    echo "REENTERED $record"
  else
    suppress_reason='SIGHTING (suppressed by cooldown)'; [ "$existing_state" != DLQ ] || suppress_reason='SIGHTING (suppressed by cooldown/DLQ)'
    commit_existing "$existing_state" "$cooldown_until" "$add_source" false SIGHTING "$suppress_reason" "$second_event" "$second_reason"
    echo "SUPPRESSED $record"
  fi
  exit 0
fi

if [ "$duplicate" = true ]; then event_reason='SIGHTING (duplicate url)'; else event_reason="$report (+1 source_item)"; fi
commit_existing "$existing_state" "$cooldown_until" "$add_source" false SIGHTING "$event_reason" "$second_event" "$second_reason"
echo "SIGHTED $record"
