#!/usr/bin/env bash
# Record a validated evaluator verdict. macOS Bash 3.2 compatible.

set -u
if ! command -v ruby >/dev/null 2>&1; then
  echo "council-record.sh: ruby not found on PATH; install ruby to use this repo's scripts" >&2
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
Usage: council-record.sh --vault <root> --topic <topic_key> --lens <lens> \
  --workspace <engine-workspace> --verdict-body <path> [--task-id <id>] \
  [--supersede] [--now <ISO8601Z>] [--dry-run]
EOF
}
fail() { echo "council-record.sh: $*" >&2; exit 2; }
utc_timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
file_mtime() { ruby -e 'print File.mtime(ARGV.fetch(0)).to_i' "$1"; }

reject_control_chars() {
  if ruby -e 'exit(ARGV[0].bytes.any? { |b| b <= 31 || b == 127 } ? 0 : 1)' "$1"; then
    fail "$2 must not contain control characters"
  fi
}

vault=''
topic_key=''
lens=''
body_path=''
workspace=''
requested_task_id=''
now_override=''
supersede=0
dry_run=0

need_value() { [ "$#" -ge 2 ] || { usage; exit 2; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --vault|--topic|--lens|--verdict-body|--workspace|--task-id|--now)
      need_value "$@"
      case "$1" in
        --vault) vault=$2 ;;
        --topic) topic_key=$2 ;;
        --lens) lens=$2 ;;
        --verdict-body) body_path=$2 ;;
        --workspace) workspace=$2 ;;
        --task-id) requested_task_id=$2 ;;
        --now) now_override=$2 ;;
      esac
      shift 2 ;;
    --supersede) supersede=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --help) usage; exit 0 ;;
    *) fail "unknown or incomplete option: $1" ;;
  esac
done

[ -n "$vault" ] && [ -n "$topic_key" ] && [ -n "$lens" ] && [ -n "$body_path" ] && [ -n "$workspace" ] || { usage; exit 2; }
topic_re='^[a-z0-9]+(-[a-z0-9]+)*__[a-z0-9]+(-[a-z0-9]+)*(__v[0-9]+)?$'
lens_re='^(utility|cost|security)$'
printf '%s\n' "$topic_key" | grep -Eq "$topic_re" || fail "invalid topic key: $topic_key"
printf '%s\n' "$lens" | grep -Eq "$lens_re" || fail "invalid lens: $lens"
reject_control_chars "$vault" vault
reject_control_chars "$topic_key" topic
reject_control_chars "$lens" lens
reject_control_chars "$body_path" verdict-body
reject_control_chars "$workspace" workspace
[ -d "$workspace" ] || fail "workspace directory not found: $workspace"
[ -f "$body_path" ] && [ -r "$body_path" ] || fail "verdict body not readable: $body_path"

if [ -n "$now_override" ]; then
  timestamp=$(ruby -rtime -e '
    value = ARGV[0]
    abort "invalid" unless value =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
    puts Time.iso8601(value).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  ' "$now_override" 2>/dev/null) || fail "--now must be ISO8601Z (YYYY-MM-DDTHH:MM:SSZ)"
else
  timestamp=$(utc_timestamp)
fi

ledger_dir="$vault/45_ai-systems/self-growth/proposals"
council_dir="$vault/45_ai-systems/self-growth/council/$topic_key"
record_path="$ledger_dir/$topic_key.md"
lock_dir="$ledger_dir/.lock"
[ -d "$ledger_dir" ] || fail "proposal ledger directory not found"
[ -d "$council_dir" ] || fail "council directory not found: $topic_key"
[ -r "$record_path" ] || fail "proposal record not readable: $topic_key"
if [ -n "$requested_task_id" ]; then
  task_re="^sgl-trial-${topic_key}-[0-9]{8}t[0-9]{6}$"
  printf '%s\n' "$requested_task_id" | grep -Eq "$task_re" || fail "invalid task id: $requested_task_id"
fi

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
trap release_lock EXIT
trap 'release_lock; exit 129' HUP
trap 'release_lock; exit 130' INT
trap 'release_lock; exit 143' TERM

acquire_lock() {
  attempt=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    current_epoch=$(date +%s)
    if lock_mtime=$(file_mtime "$lock_dir" 2>/dev/null); then
      case "$lock_mtime" in
        ''|*[!0-9]*) lock_mtime_valid=0 ;;
        *) lock_mtime_valid=1 ;;
      esac
      if [ "$lock_mtime_valid" -eq 1 ] && [ $((current_epoch - lock_mtime)) -gt 300 ]; then
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
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt 10 ] || fail "lock busy after 10 retries: $lock_dir"
    sleep 0.5
  done
  lock_identity="$$ $(hostname) council-record.sh"
  owner_tmp="$lock_dir/.owner.$$"
  if ! printf '%s\n' "$lock_identity" > "$owner_tmp" || ! mv "$owner_tmp" "$lock_dir/owner"; then
    rm -f "$owner_tmp"; fail "cannot write lock owner"
  fi
  lock_held=1
}

[ "$dry_run" -eq 1 ] || acquire_lock

COUNCIL_DIR="$council_dir" TOPIC="$topic_key" LENS="$lens" BODY="$body_path" WORKSPACE="$workspace" RECORD="$record_path" TASK_ID="$requested_task_id" \
NOW="$timestamp" SUPERSEDE="$supersede" DRY_RUN="$dry_run" ruby -EUTF-8:UTF-8 -ryaml -rjson -rdigest -rdate -rtime -e '
  BUNDLE_FILES = %w[run.log env-manifest.txt config-diff.txt permissions.md cost.txt attempts.md repro.md rollback-test.md].freeze
  def safe_yaml(path)
    raise "file exceeds 1MB" if File.size(path) > 1_048_576
    raw = File.binread(path).force_encoding("UTF-8")
    raise "invalid UTF-8" unless raw.valid_encoding?
    data = YAML.safe_load(raw, permitted_classes: [Date, Time], aliases: false)
    raise "YAML is not a mapping" unless data.is_a?(Hash)
    data
  end
  def frontmatter(path)
    raise "file exceeds 1MB" if File.size(path) > 1_048_576
    raw = File.binread(path).force_encoding("UTF-8")
    raise "invalid UTF-8" unless raw.valid_encoding?
    lines = raw.lines; raise "frontmatter missing" unless lines.first == "---\n"
    close = lines[1, 200].to_a.index("---\n"); raise "frontmatter missing" unless close
    YAML.safe_load(lines[0..close + 1].join, permitted_classes: [Date, Time], aliases: false).tap { |d| raise "frontmatter is not a mapping" unless d.is_a?(Hash) }
  end
  def violation(dir, task_id, now, code, detail, dry)
    line = "- #{now} council-record.sh #{code} — #{detail}\n"; warn line.strip
    return if dry
    safe = task_id.to_s.match?(/\Asgl-trial-[a-z0-9][a-z0-9_-]*-[0-9]{8}t[0-9]{6}\z/) ? task_id : "_malformed"
    path = File.join(dir, "#{safe}.violations.md"); temp = File.join(dir, ".#{File.basename(path)}.council-record.#{$$}.#{rand(1_000_000)}")
    begin
      prior = File.exist?(path) ? File.binread(path) : "".b
      expected = prior + line.b
      File.open(temp, "wb", 0600) { |f| f.write(expected); f.flush; f.fsync }
      raise "violation postcondition failed" unless File.binread(temp) == expected
      File.rename(temp, path)
    ensure
      File.delete(temp) if File.exist?(temp)
    end
  end
  def die(dir, task_id, now, code, detail, dry); violation(dir, task_id, now, code, detail, dry); exit 3; end
  def normalize_body(bytes)
    text = bytes.dup.force_encoding("UTF-8"); raise "invalid UTF-8" unless text.valid_encoding?
    text = text.gsub("\r\n", "\n")
    raise "disallowed control character" if text.each_codepoint.any? { |c| (c < 32 && c != 9 && c != 10) || c == 127 || c == 0x2028 || c == 0x2029 }
    text
  end
  def task_ok?(id, topic); id.match?(%r{\Asgl-trial-#{Regexp.escape(topic)}-[0-9]{8}t[0-9]{6}\z}); end
  def manifest_for(path, topic)
    # Selection metadata is validated once for every candidate and again for
    # an explicitly selected path.  Detailed manifest fields are validated by
    # the operations that consume them below.
    manifest_candidate(path, topic)
  end
  def manifest_candidate(path, topic)
    base = File.basename(path, ".convene.yaml")
    raise "basename invalid" unless task_ok?(base, topic)
    data = safe_yaml(path)
    raise "task_id does not equal filename" unless data["task_id"].to_s == base
    raise "topic_key mismatch" unless data["topic_key"].to_s == topic
    raise "schema mismatch" unless data["schema"].to_s == "sgl-council-convene/v1"
    raise "sealed must be boolean" unless data["sealed"] == true || data["sealed"] == false
    [base, data]
  end
  def attributable_sealed_candidate(path, id, manifest, now_t)
    decision_at = Time.iso8601(manifest["decision_at"].to_s).utc
    raise "decision_at is in the future" if decision_at > now_t
    [path, id, manifest, decision_at]
  end
  def digest_ok?(manifest, workspace, task_id)
    bundle = manifest.dig("digests", "bundle")
    return [false, "digests.bundle is not the eight-file mapping"] unless bundle.is_a?(Hash) && bundle.keys.sort == BUNDLE_FILES.sort
    root = File.join(workspace, "loop", "artifacts", task_id, "out", "bundle")
    BUNDLE_FILES.each do |name|
      path = File.join(root, name)
      return [false, "missing #{name}"] unless File.file?(path)
      return [false, "digest mismatch #{name}"] unless Digest::SHA256.hexdigest(File.binread(path)) == bundle[name].to_s
    end
    [true, nil]
  end

  dir, now, dry, topic = ENV.fetch("COUNCIL_DIR"), ENV.fetch("NOW"), ENV.fetch("DRY_RUN") == "1", ENV.fetch("TOPIC")
  now_t = Time.iso8601(now).utc
  requested = ENV.fetch("TASK_ID")
  manifests = []
  skipped = []
  Dir.glob(File.join(dir, "*.convene.yaml")).sort.each do |path|
    base = File.basename(path, ".convene.yaml")
    begin
      id, data = manifest_candidate(path, topic); manifests << [path, id, data]
    rescue StandardError => e
      skipped << [path, task_ok?(base, topic) ? base : nil, e]
    end
  end
  emit_skipped = lambda do
    skipped.each { |path, skipped_id, error| violation(dir, skipped_id, now, "MANIFEST_SKIPPED", "#{File.basename(path)}: #{error.message}", dry) }
  end
  attributed_latest_sealed = false
  if !requested.empty?
    selected_path = File.join(dir, "#{requested}.convene.yaml")
    die(dir, requested, now, "MANIFEST_AMBIGUOUS", "requested task manifest not found", dry) unless File.file?(selected_path)
    begin
      task_id, manifest = manifest_for(selected_path, topic)
    rescue StandardError => e
      die(dir, requested, now, "MANIFEST_INVALID", "#{File.basename(selected_path)}: #{e.message}", dry)
    end
  else
    selected = manifests.select { |_p, _id, m| m["sealed"] == false }
    if selected.length == 1
      selected_path, _selected_id, _selected_manifest = selected.first
      begin
        task_id, manifest = manifest_for(selected_path, topic)
      rescue StandardError => e
        die(dir, nil, now, "MANIFEST_INVALID", "#{File.basename(selected_path)}: #{e.message}", dry)
      end
    elsif !manifests.empty? && manifests.all? { |_p, _id, m| m["sealed"] == true }
      attributable = []
      manifests.each do |path, id, candidate|
        begin
          attributable << attributable_sealed_candidate(path, id, candidate, now_t)
        rescue StandardError => e
          skipped << [path, id, e]
        end
      end
      if attributable.empty?
        emit_skipped.call
        die(dir, nil, now, "MANIFEST_AMBIGUOUS", "no sealed manifest has an attributable decision_at", dry)
      end
      selected_path, _selected_id, _selected_manifest, _decision_at = attributable.max_by { |_p, id, _m, decision_at| [decision_at, id] }
      begin
        task_id, manifest = manifest_for(selected_path, topic)
      rescue StandardError => e
        die(dir, nil, now, "MANIFEST_INVALID", "#{File.basename(selected_path)}: #{e.message}", dry)
      end
      attributed_latest_sealed = true
    else
      emit_skipped.call
      die(dir, nil, now, "MANIFEST_AMBIGUOUS", "expected one unsealed manifest, found #{selected.length}", dry)
    end
  end
  skipped.reject { |path, _skipped_id, _error| !requested.empty? && path == selected_path }.each do |path, skipped_id, error|
    violation(dir, skipped_id, now, "MANIFEST_SKIPPED", "#{File.basename(path)}: #{error.message}", dry)
  end
  if requested.empty? && !attributed_latest_sealed
    begin
      record = frontmatter(ENV.fetch("RECORD")); bundle_link = record.dig("links", "trial_bundle").to_s
      current = File.basename(bundle_link.sub(%r{/+\z}, ""))
      raise "record trial bundle mismatch" unless bundle_link == "loop/artifacts/#{current}/" && current == task_id
    rescue StandardError => e
      die(dir, task_id, now, "MANIFEST_AMBIGUOUS", e.message, dry)
    end
  end
  body_bytes = File.binread(ENV.fetch("BODY")); die(dir, task_id, now, "BODY_OVERSIZE", "verdict body exceeds 64KB", dry) if body_bytes.bytesize > 65_536
  begin; body = normalize_body(body_bytes); rescue StandardError => e; die(dir, task_id, now, e.message == "invalid UTF-8" ? "BODY_INVALID_UTF8" : "BODY_CONTROL_CHARS", e.message, dry); end
  seats = manifest["seats"]
  die(dir, task_id, now, "MANIFEST_INVALID", "seats missing", dry) unless seats.is_a?(Array)
  candidates = seats.select { |s| s.is_a?(Hash) && s["lens"].to_s == ENV.fetch("LENS") }
  die(dir, task_id, now, "SEAT_NOT_ACTIVE", "no seat for lens #{ENV.fetch("LENS")}", dry) if candidates.empty?
  latest = candidates.max_by { |s| s["attempt"].to_i }
  latest_attempt = latest["attempt"].to_i
  die(dir, task_id, now, "SEAT_NOT_ACTIVE", "invalid attempt for lens #{ENV.fetch("LENS")}", dry) if latest_attempt < 1

  active = candidates.reject { |s| s["status"].to_s == "timed_out" }.max_by { |s| s["attempt"].to_i }
  if manifest["sealed"] == true || active.nil?
    late = File.join(dir, "#{task_id}.#{ENV.fetch("LENS")}.a#{latest_attempt}.late.md")
    die(dir, task_id, now, "DUPLICATE_LATE", "late delivery already exists", dry) if File.exist?(late)
    unless dry
      temp = File.join(dir, ".#{File.basename(late)}.council-record.#{$$}.#{rand(1_000_000)}")
      File.open(temp, "wb", 0600) { |f| f.write(body); f.flush; f.fsync }
      File.rename(temp, late)
    end
    detail = "#{ENV.fetch("LENS")}-a#{latest_attempt} is sealed or timed out"
    detail += "; attributed=latest-sealed task_id=#{task_id}" if attributed_latest_sealed
    violation(dir, task_id, now, "LATE_DELIVERY", detail, dry)
    exit 3
  end
  attempt = active["attempt"].to_i

  die(dir, task_id, now, "PLACEHOLDER_REMAINS", "body contains {{...}}", dry) if body.match?(/\{\{.*?\}\}/m)
  verdicts = body.lines.select { |l| l.match?(/^\s*VERDICT\s*:/i) }
  die(dir, task_id, now, "VERDICT_INVALID", "expected one canonical VERDICT line", dry) unless verdicts.length == 1 && verdicts.first.match?(/\AVERDICT: (GO|NO-GO|RETRY)\n?\z/)
  verdict = verdicts.first[/\AVERDICT: (GO|NO-GO|RETRY)\n?\z/, 1]
  headings = body.lines.grep(/\A## (Reasons|Bundle evidence|Dissent \/ reservations|Retry instructions)\s*\z/).map { |l| l.strip.sub(/\A## /, "") }
  required = ["Reasons", "Bundle evidence", "Dissent / reservations"]
  die(dir, task_id, now, "SECTION_DUPLICATE", "duplicate section heading", dry) unless headings.uniq.length == headings.length
  die(dir, task_id, now, "SECTION_MISSING", "required verdict sections missing", dry) unless required.all? { |h| headings.include?(h) }
  sections = {}
  lines = body.lines
  all_headings = lines.each_with_index.select { |line, _i| line.match?(/\A## /) }
  all_heading_names = all_headings.map { |line, _i| line.strip }
  die(dir, task_id, now, "SECTION_DUPLICATE", "duplicate section heading", dry) unless all_heading_names.uniq.length == all_heading_names.length
  all_headings.each_with_index do |(line, start), index|
    name = line.strip.sub(/\A## /, "")
    next unless (required + ["Retry instructions"]).include?(name)
    finish = all_headings[index + 1] ? all_headings[index + 1][1] : body.lines.length
    sections[name] = lines[(start + 1)...finish].join
  end
  die(dir, task_id, now, "REASONS_MISSING", "Reasons must be non-whitespace", dry) if sections["Reasons"].to_s.strip.empty?
  retry_text = sections["Retry instructions"]
  if verdict == "RETRY"
    die(dir, task_id, now, "RETRY_INSTRUCTIONS_MISSING", "Retry instructions must be non-whitespace", dry) if retry_text.to_s.strip.empty?
  elsif !retry_text.nil? && retry_text.strip != "None"
    die(dir, task_id, now, "RETRY_INSTRUCTIONS_INVALID", "Retry instructions must be absent or exactly None", dry)
  end
  evidence = sections["Bundle evidence"].to_s.lines
  bundle = manifest.dig("digests", "bundle")
  die(dir, task_id, now, "MANIFEST_INVALID", "digests.bundle missing", dry) unless bundle.is_a?(Hash)
  citations = 0
  evidence.each do |line|
    if line.match?(/^\s*- file:/)
      match = line.match(/\A\s*- file: ([^;]+); observation: (.*?)\s*\z/)
      die(dir, task_id, now, "CITATION_MALFORMED", "citation is malformed", dry) unless match
      observation = match[2]
      die(dir, task_id, now, "CITATION_MALFORMED", "citation observation is blank", dry) unless observation.each_codepoint.any? { |c| c != 0x00a0 && c != 0x20 && c != 9 && c >= 33 && c != 0x7f }
    else
      next
    end
    name = match[1].strip
    die(dir, task_id, now, "CITATION_OUT_OF_BUNDLE", "#{name} is not in digests.bundle", dry) unless bundle.key?(name)
    citations += 1
  end
  die(dir, task_id, now, "CITATION_MISSING", "Bundle evidence needs a structured citation", dry) if citations == 0

  ok, drift = digest_ok?(manifest, ENV.fetch("WORKSPACE"), task_id)
  die(dir, task_id, now, "DIGEST_DRIFT", drift, dry) unless ok
  base = File.join(dir, "#{task_id}.#{ENV.fetch("LENS")}.a#{attempt}.verdict.md")
  target = base
  if ENV.fetch("SUPERSEDE") == "1"
    begin
      report = frontmatter(File.join(dir, "#{task_id}.quorum.md"))
      blocked = report["task_id"].to_s == task_id && report["decision"].to_s == "BLOCKED_SECURITY_VETO" && manifest["sealed"] == false
    rescue StandardError
      blocked = false
    end
    begin
      base_no_go = File.exist?(base) && frontmatter(base)["verdict"].to_s == "NO-GO"
    rescue StandardError
      base_no_go = false
    end
    eligible = ENV.fetch("LENS") == "security" && base_no_go && !File.exist?(base.sub(/\.md\z/, ".2.md")) && blocked
    die(dir, task_id, now, "SUPERSEDE_INELIGIBLE", "requires an unsealed BLOCKED_SECURITY_VETO quorum report and active security NO-GO", dry) unless eligible
    target = base.sub(/\.md\z/, ".2.md")
  else
    die(dir, task_id, now, "DUPLICATE_VERDICT", "verdict already exists", dry) if File.exist?(target)
  end
  values = bundle.values.map(&:to_s).sort.join
  frontmatter = {
    "topic_key" => manifest["topic_key"].to_s, "task_id" => task_id,
    "lens" => ENV.fetch("LENS"), "seat" => "#{ENV.fetch("LENS")}-a#{attempt}",
    "evaluator_model" => active["evaluator_model"].to_s,
    "evaluator_family" => active["evaluator_family"].to_s,
    "evaluator_vendor" => active["evaluator_vendor"].to_s,
    "verdict" => verdict, "recorded_at" => now,
    "bundle_digest" => Digest::SHA256.hexdigest(values)
  }
  output = "---\n#{YAML.dump(frontmatter).sub(/\A---\n/, "")}---\n#{body}"
  unless dry
    temp = File.join(dir, ".#{File.basename(target)}.council-record.#{$$}.#{rand(1_000_000)}")
    File.open(temp, "wb", 0600) { |f| f.write(output); f.flush; f.fsync }
    parsed = safe_yaml(temp)
    raise "frontmatter postcondition failed" unless parsed.is_a?(Hash) && parsed["task_id"] == task_id && parsed["verdict"] == verdict
    File.rename(temp, target)
  end
  puts "#{dry ? "PLAN" : "RECORDED"} #{File.basename(target)}"
' 
