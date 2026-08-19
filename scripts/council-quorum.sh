#!/usr/bin/env bash
# Close a council ballot and, when requested, apply its permitted disposition.
# macOS Bash 3.2 compatible; YAML and frontmatter handling stays in Ruby.

set -u
if ! command -v ruby >/dev/null 2>&1; then
  echo "council-quorum.sh: ruby not found on PATH; install ruby to use this repo's scripts" >&2
  exit 127
fi
# shellcheck disable=SC2034 # consumed by sourced lock helper
ADOPT_TOOL=council-quorum.sh
# shellcheck disable=SC1091
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lib-adopt.sh"
case "${LC_ALL:-}" in *UTF-8*|*utf8*) ;; *) LC_ALL=en_US.UTF-8; export LC_ALL ;; esac

usage() {
  cat >&2 <<'EOF'
Usage: council-quorum.sh --vault <root> --topic <topic_key> --workspace <engine-workspace> \
  [--apply] [--sho-override <ref>] [--now <ISO8601Z>]

--apply seals rows 1/3/4/5/6.  RETRY only prints the trial-enqueue.sh
--retry-from command: the caller supplies its engine and executor arguments.
EOF
}
fail() { echo "council-quorum.sh: $*" >&2; exit 2; }
policy_fail() { echo "council-quorum.sh: $*" >&2; exit 3; }
utc_timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
reject_control_chars() { ruby -e 'exit(ARGV[0].bytes.any? { |b| b <= 31 || b == 127 } ? 0 : 1)' "$1" && fail "$2 must not contain control characters"; }
reject_fence_token() { case "$1" in *'```'*) fail "$2 must not contain a code fence token";; esac; }

vault=''; topic_key=''; workspace=''; now_override=''; apply=0; sho_override=''; sho_override_seen=0
need_value() { [ "$#" -ge 2 ] || { usage; exit 2; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --vault|--topic|--workspace|--sho-override|--now)
      need_value "$@"
      case "$1" in
        --vault) vault=$2 ;; --topic) topic_key=$2 ;; --workspace) workspace=$2 ;;
        --sho-override) sho_override_seen=1; sho_override=$2 ;; --now) now_override=$2 ;;
      esac
      shift 2 ;;
    --apply) apply=1; shift ;;
    --help) usage; exit 0 ;;
    *) fail "unknown or incomplete option: $1" ;;
  esac
done
[ -n "$vault" ] && [ -n "$topic_key" ] && [ -n "$workspace" ] || { usage; exit 2; }
printf '%s\n' "$topic_key" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*__[a-z0-9]+(-[a-z0-9]+)*(__v[0-9]+)?$' || fail "invalid topic key: $topic_key"
reject_control_chars "$vault" vault; reject_fence_token "$vault" vault
reject_control_chars "$workspace" workspace; reject_fence_token "$workspace" workspace
if [ "$sho_override_seen" -eq 1 ]; then reject_control_chars "$sho_override" sho-override; reject_fence_token "$sho_override" sho-override; fi
[ -d "$workspace" ] || fail "workspace directory not found: $workspace"
if [ -n "$now_override" ]; then
  timestamp=$(ruby -rtime -e 'v=ARGV[0]; abort unless v =~ /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/; puts Time.iso8601(v).utc.strftime("%Y-%m-%dT%H:%M:%SZ")' "$now_override" 2>/dev/null) || fail "--now must be ISO8601Z (YYYY-MM-DDTHH:MM:SSZ)"
else timestamp=$(utc_timestamp); fi

ledger_dir="$vault/45_ai-systems/self-growth/proposals"
[ -d "$ledger_dir" ] || fail "proposal ledger directory not found"
if [ "$sho_override_seen" -eq 1 ]; then
  fail "new --sho-override is disabled; use the owner confirmation artifact flow"
fi

run_quorum() {
  VAULT="$vault" TOPIC="$topic_key" WORKSPACE="$workspace" NOW="$timestamp" APPLY="$apply" REPO_ROOT="$(adopt_repo_root)" ruby -ryaml -rtime -rdigest -e '
  require "fileutils"
  require File.join(ENV.fetch("REPO_ROOT"), "scripts", "lib-owner-confirmation")
  vault, topic, workspace, now, apply = ENV.values_at("VAULT", "TOPIC", "WORKSPACE", "NOW", "APPLY")
  apply = apply == "1"; now_t = Time.iso8601(now).utc
  ledger = File.join(vault, "45_ai-systems/self-growth/proposals")
  record_path = File.join(ledger, "#{topic}.md")
  council_dir = File.join(vault, "45_ai-systems/self-growth/council", topic)
  abort "council-quorum.sh: proposal record not readable: #{topic}" unless File.file?(record_path)
  abort "council-quorum.sh: council directory not found: #{topic}" unless File.directory?(council_dir)

  def load_md_yaml(path)
    raise "file exceeds 1 MB" if File.size(path) > 1_048_576
    raw = File.binread(path); raise "invalid UTF-8" unless raw.force_encoding("UTF-8").valid_encoding?
    lines = raw.lines; raise "frontmatter missing" unless lines.first == "---\n"
    close = lines[1, 200].to_a.index("---\n"); raise "frontmatter terminator missing" unless close
    idx = close + 1; data = YAML.safe_load(lines[0..idx].join, permitted_classes: [Date, Time], aliases: false); raise "frontmatter is not a mapping" unless data.is_a?(Hash)
    [lines, idx, data]
  end
  def load_yaml(path)
    raise "file exceeds 1 MB" if File.size(path) > 1_048_576
    raw = File.binread(path); raise "invalid UTF-8" unless raw.force_encoding("UTF-8").valid_encoding?
    data = YAML.safe_load(raw, permitted_classes: [Date, Time], aliases: false)
    raise "YAML is not a mapping" unless data.is_a?(Hash)
    data
  end
  def write_atomic(path, content)
    tmp = File.join(File.dirname(path), ".#{File.basename(path)}.quorum.#{$$}.#{rand(1_000_000)}")
    mode = File.exist?(path) ? File.stat(path).mode & 07777 : 0644
    File.open(tmp, "w", mode) { |f| f.write(content); f.flush; f.fsync }
    File.chmod(mode, tmp)
    yield(tmp) if block_given?
    File.rename(tmp, path)
  ensure
    File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
  end
  def iso8601_value(value)
    value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
  end
  def canonical_timestamp_value(value, label)
    time =
      case value
      when Time
        value.utc
      when String
        Time.parse(value).utc
      else
        raise "#{label} invalid"
      end
    time.strftime("%Y-%m-%dT%H:%M:%SZ")
  rescue ArgumentError
    raise "#{label} invalid"
  end
  def violation(dir, task, now, code, detail)
    line = "- #{now} council-quorum.sh #{code} — #{detail}\n"; path = File.join(dir, "#{task}.violations.md")
    prior = File.exist?(path) ? File.binread(path) : ""
    write_atomic(path, prior + line)
    warn line.strip; exit 3
  end
  def transition_record(path, lines, finish, now, now_t, target, event, transition_at = now)
    transition_at = canonical_timestamp_value(transition_at, "transition_at")
    state_entered_t = Time.iso8601(transition_at).utc
    seen = {}; output = []
    lines.each_with_index do |line, index|
      if index <= finish
        case line
        when /^state:/ then output << "state: #{target}\n"; seen["state"] = true
        when /^state_entered_at:/ then output << "state_entered_at: #{transition_at}\n"; seen["state_entered_at"] = true
        when /^updated:/ then output << "updated: #{now[0,10]}\n"; seen["updated"] = true
        when /^cooldown_until:/
          if target == "REJECTED"
            output << "cooldown_until: \"#{(state_entered_t + 30*24*3600).strftime("%Y-%m-%dT%H:%M:%SZ")}\"\n"
            seen["cooldown_until"] = true
          else
            output << line
          end
        else output << line
        end
      else
        output << line
      end
    end
    required = %w[state state_entered_at updated]; required << "cooldown_until" if target == "REJECTED"
    missing = required.reject { |key| seen[key] }; raise "missing literal keys: #{missing.join(", ")}" unless missing.empty?
    output << "\n" unless output.last.to_s.end_with?("\n")
    output << "- #{now} alpha COUNCIL→#{target} — #{event}\n"
    content = output.join
    write_atomic(path, content) do |tmp|
      _, _, parsed = load_md_yaml(tmp)
      raise "record postcondition failed" unless parsed["state"].to_s == target && Time.iso8601(iso8601_value(parsed["state_entered_at"])).utc == state_entered_t && parsed["updated"].to_s == now[0,10]
    end
  end
  def append_event(body, event)
    bytes = body.to_s.b
    bytes += "\n".b unless bytes.empty? || bytes.end_with?("\n".b)
    bytes + event.b
  end
  def attempt_namespace_path(vault_root, topic_key, proposal_attempt)
    relative = OwnerConfirmation.owner_confirmation_relative_path(
      topic_key: topic_key,
      proposal_attempt: proposal_attempt,
    )
    File.join(vault_root, File.dirname(relative))
  end
  def assert_attempt_namespace_absent!(vault_root, topic_key, proposal_attempt)
    path = attempt_namespace_path(vault_root, topic_key, proposal_attempt)
    File.lstat(path)
    raise OwnerConfirmation::Error.new("attempt-namespace-occupied", path)
  rescue Errno::ENOENT, Errno::ENOTDIR
    nil
  end
  def transition_fresh_pending_sho!(record_path:, vault_root:, expected_state:, now:, transition_at:, event:)
    proposal = OwnerConfirmation.load_proposal_record(path: record_path)
    next_record = OwnerConfirmation.build_next_proposal_v2(record: proposal, expected_state: expected_state)
    assert_attempt_namespace_absent!(vault_root, next_record.fetch("topic_key"), next_record.fetch("proposal_attempt"))
    next_record["state_entered_at"] = canonical_timestamp_value(transition_at, "transition_at")
    next_record["updated"] = now[0, 10]
    next_record.body_bytes = append_event(proposal.body_bytes, "- #{now} alpha COUNCIL→PENDING_SHO — #{event}\n")
    OwnerConfirmation.validate_and_rewrite_proposal_v2!(record: next_record, path: proposal.path)
    next_record
  end
  begin
    record_lines, record_end, record = load_md_yaml(record_path)
  rescue => e
    abort "council-quorum.sh: damaged record: #{e.message}"
  end
  bundle_link = record.dig("links", "trial_bundle").to_s.sub(%r{/+$}, "")
  task = File.basename(bundle_link)
  if task.empty? || task == "." || task == "/"
    violation(council_dir, "unknown", now, "MANIFEST_AMBIGUOUS", "record links.trial_bundle has no task id")
  end
  manifest_path = File.join(council_dir, "#{task}.convene.yaml")
  unless File.file?(manifest_path)
    violation(council_dir, task, now, "MANIFEST_AMBIGUOUS", "current task manifest is missing") if record["state"].to_s == "COUNCIL"
    abort "council-quorum.sh: current task manifest is missing: #{task}"
  end
  begin
    manifest = load_yaml(manifest_path)
  rescue => e
    violation(council_dir, task, now, "MANIFEST_AMBIGUOUS", "cannot parse current manifest: #{e.message}")
  end
  violation(council_dir, task, now, "MANIFEST_AMBIGUOUS", "manifest task_id does not match current task") unless manifest["task_id"].to_s == task
  if manifest["sealed"] == true
    decision = manifest["decision"].to_s
    if record["state"].to_s == "COUNCIL"
      target = if decision == "GO" || decision == "GO (Sho override of security veto)"
        "PENDING_SHO"
      elsif decision.start_with?("NO-GO")
        "REJECTED"
      end
      if target
        repair_entered_at = now
        repair_note = ""
        begin
          record_entered_at = Time.iso8601(canonical_timestamp_value(record["state_entered_at"], "record state_entered_at")).utc
          decision_at = Time.iso8601(canonical_timestamp_value(manifest["decision_at"], "manifest decision_at")).utc
          raise "decision_at predates COUNCIL entry" if decision_at < record_entered_at
          raise "decision_at is in the future" if decision_at > now_t
          repair_entered_at = decision_at.strftime("%Y-%m-%dT%H:%M:%SZ")
        rescue
          repair_note = "; state_entered_at fallback to repair time (missing, invalid, pre-COUNCIL, or future decision_at)"
        end
        if target == "PENDING_SHO"
          proposal = OwnerConfirmation.load_proposal_record(path: record_path)
          OwnerConfirmation.derive_council_evidence(vault_root: vault, record: proposal)
          transition_fresh_pending_sho!(
            record_path: record_path,
            vault_root: vault,
            expected_state: "COUNCIL",
            now: now,
            transition_at: repair_entered_at,
            event: "repair: transition replay after interrupted apply#{repair_note}",
          )
        else
          transition_record(record_path, record_lines, record_end, now, now_t, target, "repair: transition replay after interrupted apply#{repair_note}", repair_entered_at)
        end
        puts "REPAIRED #{decision}"; exit 0
      end
    end
    puts "SEALED #{decision}"; exit 0
  end
  unless record["state"].to_s == "COUNCIL"
    report_path = File.join(council_dir, "#{task}.quorum.md")
    unless File.file?(report_path)
      puts "WAITING"; exit 0
    end
    begin
      _, _, report = load_md_yaml(report_path)
      decision = report["decision"].to_s
      raise "report task_id does not match current task" unless report["task_id"].to_s == task
      raise "report decision is empty" if decision.empty?
      manifest["sealed"] = true; manifest["decision"] = decision; manifest["decision_at"] = canonical_timestamp_value(report["decision_at"], "report decision_at")
      write_atomic(manifest_path, YAML.dump(manifest)) { |tmp| d = load_yaml(tmp); raise "manifest repair postcondition failed" unless d["sealed"] == true && d["decision"].to_s == decision }
      puts "SEALED #{decision}"; exit 0
    rescue => e
      violation(council_dir, task, now, "MANIFEST_AMBIGUOUS", "cannot complete seal from quorum report: #{e.message}")
    end
  end
  seats = manifest["seats"]; unless seats.is_a?(Array)
    violation(council_dir, task, now, "MANIFEST_AMBIGUOUS", "seats is not an array")
  end
  %w[utility cost security].each { |lens| violation(council_dir, task, now, "MANIFEST_AMBIGUOUS", "missing #{lens} seat") unless seats.any? { |s| s["lens"].to_s == lens } }
  # Active means the latest attempt that has not been marked timed_out.
  active = {}; %w[utility cost security].each do |lens|
    candidates = seats.select { |s| s["lens"].to_s == lens && s["status"].to_s != "timed_out" }
    violation(council_dir, task, now, "MANIFEST_AMBIGUOUS", "no active #{lens} attempt") if candidates.empty?
    active[lens] = candidates.max_by { |s| s["attempt"].to_i }
  end
  if apply
    digests = manifest.dig("digests", "bundle")
    unless digests.is_a?(Hash) && digests.keys.length == 8
      violation(council_dir, task, now, "MANIFEST_AMBIGUOUS", "bundle digest manifest is incomplete")
    end
    digests.each do |name, expected|
      # The engine writes bundle files under out/bundle/ — the manifest bundle
      # field is the record trial_bundle root, NOT the bundle file directory.
      path = File.join(workspace, "loop", "artifacts", task, "out", "bundle", name.to_s)
      actual = File.file?(path) ? Digest::SHA256.file(path).hexdigest : "missing"
      violation(council_dir, task, now, "DIGEST_DRIFT", "#{name}: expected #{expected}, got #{actual}") unless actual == expected.to_s
    end
  end
  roster = %w[glm codex claude kimi] # fugu is explicitly DOWN in the current roster.
  used = seats.map { |s| s["evaluator_family"].to_s }.reject(&:empty?).uniq
  executor = manifest["executor_family"].to_s
  begin
    sla_end = Time.iso8601(iso8601_value(record["state_entered_at"])).utc + 3*24*3600
  rescue
    violation(council_dir, task, now, "RECORD_DAMAGED", "bad state_entered_at")
  end
  results = {}; any_pending = false; fallback = []
  active.each do |lens, seat|
    attempt = seat["attempt"].to_i; base = File.join(council_dir, "#{task}.#{lens}.a#{attempt}.verdict.md"); sup = base.sub(/\.md$/, ".2.md")
    path = File.file?(sup) ? sup : (File.file?(base) ? base : nil)
    verdict = nil
    if path
      begin
        _, _, data = load_md_yaml(path)
        valid = data["task_id"].to_s == task && data["lens"].to_s == lens && data["seat"].to_s == "#{lens}-a#{attempt}" && %w[GO NO-GO RETRY].include?(data["verdict"].to_s)
        if !valid
          code = File.file?(sup) ? "SUPERSESSION_INVALID" : "VERDICT_FILE_DAMAGED"
          violation(council_dir, task, now, code, "#{File.basename(path)} does not match the active #{lens} attempt")
        end
        verdict = data["verdict"].to_s if valid
      rescue => e
        code = File.file?(sup) ? "SUPERSESSION_INVALID" : "VERDICT_FILE_DAMAGED"
        violation(council_dir, task, now, code, "#{File.basename(path)} is malformed: #{e.message}")
      end
    end
    if verdict
      results[lens] = { state: "resolved", verdict: verdict, path: path, attempt: attempt, seat: seat }
    elsif Time.iso8601(seat["deadline"].to_s).utc > now_t
      results[lens] = { state: "pending", attempt: attempt, seat: seat }; any_pending = true
    else
      eligible = roster.any? do |family|
        family != executor && family != seat["evaluator_family"].to_s &&
          (!used.include?(family) || seats.any? { |other| other["evaluator_family"].to_s == family && other["lens"].to_s != lens })
      end
      if eligible && now_t < sla_end
        results[lens] = { state: "overdue", attempt: attempt, seat: seat }; fallback << lens
      else
        results[lens] = { state: "exhausted", attempt: attempt, seat: seat }
      end
    end
  end
  results.each { |lens, r| puts "SEAT #{lens} a#{r[:attempt]} #{r[:seat]["evaluator_model"]} #{r[:state]}#{r[:verdict] ? " #{r[:verdict]}" : ""}" }
  unless fallback.empty?
    puts "FALLBACK_REQUIRED #{fallback.first}"; exit 0
  end
  if any_pending
    puts "WAITING"; exit 0
  end
  votes = results.values.map { |r| r[:verdict] }.compact; go = votes.count("GO"); nogo = votes.count("NO-GO"); retry_n = votes.count("RETRY")
  tier = record["identity_critical"] == true ? "T2" : record["risk_tier"].to_s
  sec = results["security"][:verdict]; retries = record["retry_count"].to_i
  row, decision, reason = if go >= 2 && (tier == "T1" || sec == "GO") then [1, "GO", ""]
    elsif tier == "T2" && sec == "NO-GO" && go >= 2 then [2, "BLOCKED_SECURITY_VETO", "security veto"]
    elsif nogo >= 2 then [3, "NO-GO", ""]
    elsif retry_n >= 1 && retries < 2 then [4, "RETRY", ""]
    elsif retry_n >= 1 && retries >= 2 then [5, "NO-GO", "retries_exhausted"]
    else [6, "DLQ_RECOMMENDED", "closed ballot does not satisfy a disposition"] end
  puts "DECISION #{decision} row=#{row}#{reason.empty? ? "" : " #{reason}"}"
  if !apply
    exit 0
  end
  # Row 2 is deliberately a refreshable, unsealed report. All other applied rows seal.
  sealed = row != 2
  report_decision = decision
  report = "---\n"
  report << "schema: sgl-council-quorum/v1\n"
  report << "task_id: #{task}\n"
  report << "decision: #{report_decision}\n"
  report << "decision_at: #{now}\n"
  report << "sealed: #{sealed}\n"
  report << "counted_attempt_ids:\n"
  results.each { |lens, r| report << "  - #{lens}-a#{r[:attempt]}\n" }
  report << "---\n\n# Council quorum\n\n"
  report << "## Banners\n\n- identity_critical: #{record["identity_critical"] == true}\n- correlated_panel: #{manifest["correlated_panel"] == true}\n- writer_correlated: #{manifest["writer_correlated"] == true}\n"
  report << "\n## Vote table\n\n| Lens | Attempt | Model | State | Verdict |\n|---|---:|---|---|---|\n"
  results.each { |lens, r| report << "| #{lens} | a#{r[:attempt]} | #{r[:seat]["evaluator_model"]} | #{r[:state]} | #{r[:verdict].to_s} |\n" }
  report << "\n## Dissents / reservations\n"
  results.each do |lens, r|
    next unless r[:path]
    body = File.read(r[:path]).split(/^---\s*$\n?/, 3)[2].to_s
    dissent = body[/^## Dissent \/ reservations\s*\n(.*?)(?=^## |\z)/m, 1].to_s[0, 4000]
    report << "\n### #{lens} (raw: #{File.basename(r[:path])})\n\n    #{dissent.gsub("\n", "\n    ").rstrip}\n"
  end
  report_path = File.join(council_dir, "#{task}.quorum.md")
  write_atomic(report_path, report) { |tmp| _, _, d = load_md_yaml(tmp); raise "quorum report postcondition failed" unless d["decision"].to_s == report_decision && d["sealed"] == sealed }
  if sealed
    manifest["sealed"] = true; manifest["decision"] = report_decision; manifest["decision_at"] = canonical_timestamp_value(now, "decision_at")
    write_atomic(manifest_path, YAML.dump(manifest)) { |tmp| d = load_yaml(tmp); raise "manifest postcondition failed" unless d["sealed"] == true && d["decision"].to_s == report_decision }
  end
  target = row == 1 ? "PENDING_SHO" : (row == 3 || row == 5 ? "REJECTED" : nil)
  if target
    event = if row == 1 then "council GO — quorum #{go}/3, task #{task}#{votes.any? { |v| v != "GO" } ? "; with dissent" : ""}"
      elsif row == 5 then "council RETRY with retries_exhausted → REJECTED"
      else "council NO-GO — quorum #{nogo}/3, task #{task}" end
    if target == "PENDING_SHO"
      proposal = OwnerConfirmation.load_proposal_record(path: record_path)
      OwnerConfirmation.derive_council_evidence(vault_root: vault, record: proposal)
      transition_fresh_pending_sho!(
        record_path: record_path,
        vault_root: vault,
        expected_state: "COUNCIL",
        now: now,
        transition_at: now,
        event: event,
      )
    else
      transition_record(record_path, record_lines, record_end, now, now_t, target, event)
    end
  end
  puts "RETRY_READY run: trial-enqueue.sh --retry-from #{task} ..." if row == 4
  puts "#{decision} #{reason}" if row == 6
' || exit $?
}

# A report-only invocation can still append a violation. Hold the shared ledger
# lock for the whole run so every violation write stays serialized.
adopt_with_lock "$vault" run_quorum
