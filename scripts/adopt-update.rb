#!/usr/bin/env ruby
require "time"
require "yaml"

require File.expand_path("lib-owner-confirmation", __dir__)

COMMANDS = %w[approve complete abort rollback reject watch].freeze

command, record_path, now_raw, dry_flag, *args = ARGV
abort "missing command" unless COMMANDS.include?(command)
abort "missing record" unless record_path && File.file?(record_path)

def dry_run?(value)
  value.to_s == "1"
end

def effective_time(now_raw)
  return Time.at(Time.now.to_i).utc if now_raw.to_s.empty?

  Time.at(OwnerConfirmation.parse_utc_timestamp(now_raw).to_i).utc
end

def policy_fail(message)
  warn message
  exit 3
end

def usage_fail(message)
  warn message
  exit 2
end

def safe_line(value, name)
  OwnerConfirmation.actual_string!(value.to_s, name, min_bytes: 1, max_bytes: 8192, control_free: true)
end

def actor_slug(value)
  safe = safe_line(value, "actor")
  OwnerConfirmation.fail_closed("record-damaged", "actor must be a slug") unless safe.match?(/\A[a-z][a-z0-9-]*\z/)
  safe
end

def record_root(path)
  canonical = File.realpath(path)
  marker = "/45_ai-systems/self-growth/proposals/"
  index = canonical.b.index(marker.b)
  OwnerConfirmation.fail_closed("root-invalid", "proposal path does not match vault layout") unless index
  canonical.byteslice(0, index)
end

def owner_config_for(root)
  OwnerConfirmation.load_owner_config(vault_root: root)
end

def consume_evidence(record, root)
  if record.fetch("risk_tier") == "T0"
    OwnerConfirmation.derive_t0_evidence(vault_root: root, workspace_root: nil, record: record)
  else
    OwnerConfirmation.derive_council_evidence(vault_root: root, record: record)
  end
end

def load_current_artifact(reference:, record:, root:, owner_config:)
  parsed_reference = OwnerConfirmation.parse_owner_confirmation_reference(
    reference,
    topic_key: record.fetch("topic_key"),
    proposal_attempt: record.fetch("proposal_attempt"),
  )
  path = OwnerConfirmation.canonical_contained_path(
    root: root,
    relative_path: parsed_reference.fetch("path"),
    max_bytes: OwnerConfirmation::MAX_CONFIRMATION_BYTES,
    label: "authorization-artifact",
  )
  bytes = OwnerConfirmation.read_regular_file(
    path,
    max_bytes: OwnerConfirmation::MAX_CONFIRMATION_BYTES,
    label: "authorization-artifact",
    utf8: true,
  )
  OwnerConfirmation.fail_closed("authorization-reference-stale") unless OwnerConfirmation.sha256_hex(bytes) == parsed_reference.fetch("sha256")
  artifact = OwnerConfirmation.parse_owner_confirmation_artifact(
    bytes,
    topic_key: record.fetch("topic_key"),
    proposal_attempt: record.fetch("proposal_attempt"),
  )
  header = artifact.fetch("header")
  unless header["principal"] == owner_config.fetch("principal") &&
         header["repository-id"] == owner_config.fetch("repository_id") &&
         header["assurance"] == owner_config.fetch("default_assurance")
    OwnerConfirmation.fail_closed("authorization-artifact-damaged", "owner config correlation mismatch")
  end
  artifact.merge("reference" => reference, "path" => path)
end

def build_snapshot(record:, owner_config:, decision:, issued_inputs:, root:)
  OwnerConfirmation.build_decision_snapshot(
    record: record,
    owner_config: owner_config,
    decision: decision,
    issued_inputs: issued_inputs,
    evidence: consume_evidence(record, root),
  )
end

def append_event(record, event_line)
  body = record.body_bytes.to_s.dup.force_encoding(Encoding::UTF_8)
  event = event_line.dup.force_encoding(Encoding::UTF_8)
  OwnerConfirmation.fail_closed("record-damaged", "proposal body is not valid UTF-8") unless body.valid_encoding?
  body << "\n" unless body.empty? || body.end_with?("\n")
  record.body_bytes = (body + event).b
end

def consume_event_line(verified_at:, decision:, reference:, proposal_digest:, principal:, raw_value:)
  case decision
  when "GO"
    "- #{verified_at} alpha PENDING_OWNER→ADOPTING — Sho GO; authorization-ref=#{reference}; proposal-digest=#{proposal_digest}; principal=#{principal}; assurance=standard; backup_ref=#{raw_value}\n"
  when "REJECT"
    "- #{verified_at} alpha PENDING_OWNER→REJECTED — Sho REJECT; authorization-ref=#{reference}; proposal-digest=#{proposal_digest}; principal=#{principal}; assurance=standard; operator_reason=#{raw_value}\n"
  when "WATCH"
    "- #{verified_at} alpha PENDING_OWNER→WATCH — Sho WATCH; authorization-ref=#{reference}; proposal-digest=#{proposal_digest}; principal=#{principal}; assurance=standard; operator_reason=#{raw_value}\n"
  else
    OwnerConfirmation.fail_closed("record-damaged", "unknown decision")
  end
end

def require_exactly_one_event!(body_bytes, expected_line)
  body = body_bytes.to_s.dup.force_encoding(Encoding::UTF_8)
  event = expected_line.dup.force_encoding(Encoding::UTF_8)
  OwnerConfirmation.fail_closed("record-damaged", "proposal body is not valid UTF-8") unless body.valid_encoding?
  count = body.each_line.count { |line| line == event }
  OwnerConfirmation.fail_closed("authorization-target-state-changed") unless count == 1
end

def assert_target_state!(condition)
  OwnerConfirmation.fail_closed("authorization-target-state-changed") unless condition
end

def proposal_timestamp_string(value, label)
  case value
  when Time
    OwnerConfirmation.utc_timestamp(value)
  when String
    OwnerConfirmation.utc_timestamp(OwnerConfirmation.parse_utc_timestamp(value))
  else
    OwnerConfirmation.fail_closed("record-damaged", "#{label} must be a UTC timestamp string")
  end
end

def reject_present_rollout!(record)
  assert_target_state!(record["backup_ref"].to_s.empty?)
  assert_target_state!(record["effect_metric"].to_s.empty?)
  assert_target_state!(record["report_due"].to_s.empty?)
end

def validate_existing_adoption_record!(bytes)
  text = bytes.dup.force_encoding(Encoding::UTF_8)
  OwnerConfirmation.fail_closed("record-damaged", "adoption record is not valid UTF-8") unless text.valid_encoding?
  decision_count = text.scan(/^## Decision basis\n/).length
  observation_count = text.scan(/^## Observation contract\n/).length
  OwnerConfirmation.fail_closed("record-damaged", "adoption record heading count mismatch") unless decision_count == 1 && observation_count == 1
  decision_offset = text.index("## Decision basis\n")
  observation_offset = text.index("## Observation contract\n")
  OwnerConfirmation.fail_closed("record-damaged", "adoption record heading order mismatch") unless decision_offset && observation_offset && decision_offset < observation_offset
end

def adoption_record_relative_path(topic:, date:)
  "30_decisions/#{date}-adoption-#{topic}.md"
end

def adoption_record_bytes(record:, root:, smoke:, actor:, where_text:, date:, owner_confirmation:)
  topic = record.fetch("topic_key")
  trial_bundle = record.dig("links", "trial_bundle").to_s
  council_record = record.dig("links", "council_verdicts").to_s
  rollback_evidence =
    if record.fetch("risk_tier") == "T0"
      "not required for T0"
    else
      OwnerConfirmation.fail_closed("record-damaged", "trial bundle missing for rollback-test evidence") if trial_bundle.empty?
      rollback_path = File.join(root, trial_bundle, "rollback-test.md")
      OwnerConfirmation.fail_closed("record-damaged", "rollback-test evidence is required for T1+") unless File.file?(rollback_path)
      rollback_path
    end
  template = File.binread(File.expand_path("../templates/ADOPTION-RECORD.tmpl.md", __dir__))
  values = {
    "TOPIC_KEY" => topic,
    "TITLE" => record.fetch("title").to_s,
    "DATE" => date,
    "OWNER" => actor,
    "WHERE" => where_text.empty? ? "record field not supplied" : where_text,
    "COUNCIL_RECORD" => council_record.empty? ? "T0 fast path" : council_record,
    "TRIAL_BUNDLE" => trial_bundle,
    "CHANGE_SUMMARY" => record.fetch("title").to_s,
    "REVERSIBILITY" => record.fetch("reversibility").to_s,
    "SMOKE_EVIDENCE" => smoke,
    "ROLLBACK_EVIDENCE" => rollback_evidence,
    "EARLY_AUTHORIZED_BY" => "not used",
    "OWNER_CONFIRMATION_REFERENCE" => owner_confirmation.fetch("reference"),
    "PROPOSAL_DIGEST" => owner_confirmation.fetch("proposal_digest"),
    "OWNER_CONFIRMATION_PRINCIPAL" => owner_confirmation.fetch("principal"),
    "OWNER_CONFIRMED_AT" => owner_confirmation.fetch("verified_at"),
    "EFFECT_METRIC" => record.fetch("effect_metric").to_s,
    "REPORT_DUE" => record.fetch("report_due").to_s,
  }
  values.each do |key, value|
    template.gsub!("{{#{key}}}", safe_line(value, key))
  end
  OwnerConfirmation.fail_closed("record-damaged", "adoption template residue") if template.include?("{{")
  validate_existing_adoption_record!(template)
  template
end

def adoption_record_destination!(root:, relative_path:, create_parent:)
  canonical_root = OwnerConfirmation.canonicalize_root(root)
  unless File.expand_path(root.to_s) == canonical_root
    OwnerConfirmation.fail_closed("record-damaged", "vault root is not canonical")
  end
  components = relative_path.to_s.split("/", -1)
  unless components.length == 2 &&
         components.fetch(0) == "30_decisions" &&
         !components.fetch(1).empty? &&
         components.fetch(1) != "." &&
         components.fetch(1) != ".."
    OwnerConfirmation.fail_closed("record-damaged", "adoption record path is noncanonical")
  end

  root_stat = File.lstat(canonical_root)
  unless !root_stat.symlink? && root_stat.directory?
    OwnerConfirmation.fail_closed("record-damaged", "vault root is not a real directory")
  end
  directory = File.join(canonical_root, components.fetch(0))
  target = File.join(directory, components.fetch(1))
  root_prefix = canonical_root.end_with?(File::SEPARATOR) ? canonical_root : "#{canonical_root}#{File::SEPARATOR}"
  unless directory.start_with?(root_prefix) && target.start_with?("#{directory}#{File::SEPARATOR}")
    OwnerConfirmation.fail_closed("record-damaged", "adoption record path escapes vault")
  end

  begin
    directory_stat = File.lstat(directory)
  rescue Errno::ENOENT
    OwnerConfirmation.fail_closed("record-damaged", "adoption record directory missing") unless create_parent
    current_root_stat = File.lstat(canonical_root)
    unless !current_root_stat.symlink? &&
           current_root_stat.directory? &&
           current_root_stat.dev == root_stat.dev &&
           current_root_stat.ino == root_stat.ino
      OwnerConfirmation.fail_closed("record-damaged", "vault root identity changed")
    end
    created = false
    begin
      Dir.mkdir(directory, 0o700)
      File.chmod(0o700, directory)
      created = true
      OwnerConfirmation.fsync_directory(canonical_root)
    rescue Errno::EEXIST
      OwnerConfirmation.fsync_directory(canonical_root)
    rescue SystemCallError => e
      OwnerConfirmation.fail_closed("record-damaged", "cannot create adoption record directory: #{e.message}")
    end
    directory_stat = File.lstat(directory)
    if created && (directory_stat.mode & 0o777) != 0o700
      OwnerConfirmation.fail_closed("record-damaged", "adoption record directory mode mismatch")
    end
  rescue Errno::ENOTDIR
    OwnerConfirmation.fail_closed("record-damaged", "adoption record parent is not a directory")
  rescue SystemCallError => e
    OwnerConfirmation.fail_closed("record-damaged", "cannot inspect adoption record directory: #{e.message}")
  end

  unless !directory_stat.symlink? && directory_stat.directory?
    OwnerConfirmation.fail_closed("record-damaged", "adoption record parent must be a real directory")
  end
  begin
    directory_realpath = File.realpath(directory)
  rescue SystemCallError => e
    OwnerConfirmation.fail_closed("record-damaged", "cannot canonicalize adoption record directory: #{e.message}")
  end
  unless directory_realpath == directory && directory_realpath.start_with?(root_prefix)
    OwnerConfirmation.fail_closed("record-damaged", "adoption record parent escapes vault")
  end
  [directory, target, directory_stat]
end

def assert_adoption_directory_identity!(directory, expected_stat)
  current = File.lstat(directory)
  unless !current.symlink? &&
         current.directory? &&
         current.dev == expected_stat.dev &&
         current.ino == expected_stat.ino &&
         File.realpath(directory) == directory
    OwnerConfirmation.fail_closed("record-damaged", "adoption record directory identity changed")
  end
rescue SystemCallError => e
  OwnerConfirmation.fail_closed("record-damaged", "cannot revalidate adoption record directory: #{e.message}")
end

def validate_adoption_record_at!(directory:, target:, directory_stat:, expected_bytes:)
  assert_adoption_directory_identity!(directory, directory_stat)
  existing = OwnerConfirmation.read_regular_file(
    target,
    max_bytes: expected_bytes.bytesize,
    label: "adoption-record",
  )
  validate_existing_adoption_record!(existing)
  OwnerConfirmation.fail_closed("record-damaged", "adoption record differs from retry content") unless existing == expected_bytes.b
  existing
end

def read_existing_adoption_record!(root:, relative_path:, expected_bytes:, create_parent:)
  directory, target, directory_stat = adoption_record_destination!(
    root: root,
    relative_path: relative_path,
    create_parent: create_parent,
  )
  validate_adoption_record_at!(
    directory: directory,
    target: target,
    directory_stat: directory_stat,
    expected_bytes: expected_bytes,
  )
end

def publish_adoption_record!(root:, relative_path:, bytes:)
  directory, target, directory_stat = adoption_record_destination!(
    root: root,
    relative_path: relative_path,
    create_parent: true,
  )
  basename = File.basename(target)
  stale_prefix = ".#{basename}.adopt.tmp."
  begin
    stale = Dir.children(directory).find { |entry| entry.start_with?(stale_prefix) }
  rescue SystemCallError => e
    OwnerConfirmation.fail_closed("record-damaged", "cannot inspect adoption temporary entries: #{e.message}")
  end
  OwnerConfirmation.fail_closed("stale-adoption-temp", stale) if stale

  if OwnerConfirmation.path_entry_exists?(target)
    validate_adoption_record_at!(
      directory: directory,
      target: target,
      directory_stat: directory_stat,
      expected_bytes: bytes,
    )
    return :identical
  end

  temp = File.join(directory, "#{stale_prefix}#{Process.pid}.#{SecureRandom.hex(8)}")
  temp_identity = nil
  begin
    assert_adoption_directory_identity!(directory, directory_stat)
    File.open(temp, File::RDWR | File::CREAT | File::EXCL, 0o600) do |file|
      held_before = file.stat
      temp_identity = [held_before.dev, held_before.ino]
      OwnerConfirmation.fail_closed("record-damaged", "adoption temporary is not regular") unless held_before.file?
      file.chmod(0o600)
      OwnerConfirmation.fail_closed("record-damaged", "adoption temporary mode mismatch") unless (file.stat.mode & 0o777) == 0o600
      file.write(bytes)
      file.flush
      file.fsync
      file.rewind
      held_bytes = file.read(bytes.bytesize + 1)
      held_after = file.stat
      unless held_bytes == bytes.b &&
             held_after.file? &&
             held_after.dev == held_before.dev &&
             held_after.ino == held_before.ino
        OwnerConfirmation.fail_closed("record-damaged", "adoption temporary held-byte validation failed")
      end
    end
    staged = OwnerConfirmation.read_regular_file(
      temp,
      max_bytes: bytes.bytesize,
      label: "adoption-record-temporary",
    )
    validate_existing_adoption_record!(staged)
    OwnerConfirmation.fail_closed("record-damaged", "adoption temporary postcondition failed") unless staged == bytes.b
    assert_adoption_directory_identity!(directory, directory_stat)
    begin
      File.link(temp, target)
      assert_adoption_directory_identity!(directory, directory_stat)
      OwnerConfirmation.fsync_directory(directory)
      published = OwnerConfirmation.read_regular_file(
        target,
        max_bytes: bytes.bytesize,
        label: "adoption-record",
      )
      validate_existing_adoption_record!(published)
      OwnerConfirmation.fail_closed("record-damaged", "adoption record publication mismatch") unless published == bytes.b
      :created
    rescue Errno::EEXIST
      validate_adoption_record_at!(
        directory: directory,
        target: target,
        directory_stat: directory_stat,
        expected_bytes: bytes,
      )
      :identical
    end
  rescue SystemCallError => e
    OwnerConfirmation.fail_closed("record-damaged", "adoption record publication failed: #{e.message}")
  ensure
    begin
      if temp_identity
        assert_adoption_directory_identity!(directory, directory_stat)
        unless OwnerConfirmation.path_entry_exists?(temp)
          OwnerConfirmation.fail_closed("record-damaged", "adoption temporary disappeared before cleanup")
        end
        cleanup_stat = File.lstat(temp)
        unless !cleanup_stat.symlink? &&
               cleanup_stat.file? &&
               temp_identity == [cleanup_stat.dev, cleanup_stat.ino]
          OwnerConfirmation.fail_closed("record-damaged", "adoption temporary identity changed")
        end
        File.delete(temp)
        OwnerConfirmation.fsync_directory(directory)
      end
    rescue SystemCallError => e
      OwnerConfirmation.fail_closed("record-damaged", "adoption temporary cleanup failed: #{e.message}")
    end
  end
end

def handle_consume(command:, record_path:, dry:, args:)
  decision =
    case command
    when "approve" then "GO"
    when "reject" then "REJECT"
    when "watch" then "WATCH"
    else OwnerConfirmation.fail_closed("record-damaged", "unknown consume command")
    end
  parsed =
    case decision
    when "GO"
      OwnerConfirmation.fail_closed("record-damaged", "consume argv mismatch") unless args.length == 4
      {
        "authorization_ref" => args.fetch(0),
        "backup_ref" => safe_line(args.fetch(1), "backup_ref"),
        "effect_metric" => safe_line(args.fetch(2), "effect_metric"),
        "report_due" => safe_line(args.fetch(3), "report_due"),
      }
    else
      OwnerConfirmation.fail_closed("record-damaged", "consume argv mismatch") unless args.length == 2
      {
        "authorization_ref" => args.fetch(0),
        "reason" => safe_line(args.fetch(1), "reason"),
      }
    end

  record = OwnerConfirmation.load_proposal_record(path: record_path)
  OwnerConfirmation.fail_closed("record-damaged", "proposal must be v2") unless record["schema"] == "sgl-proposal/v2"
  root = record_root(record.path)
  owner_config = owner_config_for(root)
  issued_inputs = decision == "GO" ? parsed.slice("backup_ref", "effect_metric", "report_due") : parsed.slice("reason")
  artifact = load_current_artifact(
    reference: parsed.fetch("authorization_ref"),
    record: record,
    root: root,
    owner_config: owner_config,
  )
  snapshot = build_snapshot(
    record: record,
    owner_config: owner_config,
    decision: decision,
    issued_inputs: issued_inputs,
    root: root,
  )
  OwnerConfirmation.fail_closed("authorization-artifact-damaged", "decision mismatch") unless artifact.dig("header", "decision") == decision
  OwnerConfirmation.fail_closed("authorization-artifact-damaged", "snapshot mismatch") unless artifact.fetch("snapshot_bytes") == snapshot

  if record.dig("owner_confirmation", "status") == "pending"
    OwnerConfirmation.fail_closed("authorization-target-state-changed") unless record["state"] == "PENDING_OWNER"
    sampled = Time.at(Time.now.to_i).utc
    unless artifact.fetch("issued_time").to_i <= sampled.to_i && sampled.to_i < artifact.fetch("expires_time").to_i
      OwnerConfirmation.fail_closed("authorization-artifact-expired")
    end
    verified_at = OwnerConfirmation.utc_timestamp(sampled)
    record["owner_confirmation"] = OwnerConfirmation.verified_owner_confirmation(
      reference: parsed.fetch("authorization_ref"),
      proposal_digest: artifact.dig("header", "proposal-digest"),
      decision: decision,
      principal: owner_config.fetch("principal"),
      verified_at: verified_at,
    )
    case decision
    when "GO"
      record["state"] = "ADOPTING"
      record["backup_ref"] = parsed.fetch("backup_ref")
      record["effect_metric"] = parsed.fetch("effect_metric")
      record["report_due"] = parsed.fetch("report_due")
      raw_event_value = parsed.fetch("backup_ref")
    when "REJECT"
      reject_present_rollout!(record)
      record["state"] = "REJECTED"
      record["cooldown_until"] = OwnerConfirmation.utc_timestamp(Time.at(sampled.to_i + (30 * 86_400)).utc)
      raw_event_value = parsed.fetch("reason")
    when "WATCH"
      reject_present_rollout!(record)
      record["state"] = "WATCH"
      raw_event_value = parsed.fetch("reason")
    end
    record["state_entered_at"] = verified_at
    record["updated"] = verified_at.split("T").first
    append_event(
      record,
      consume_event_line(
        verified_at: verified_at,
        decision: decision,
        reference: parsed.fetch("authorization_ref"),
        proposal_digest: artifact.dig("header", "proposal-digest"),
        principal: owner_config.fetch("principal"),
        raw_value: raw_event_value,
      ),
    )
    if dry
      puts "DRY-RUN #{record.fetch('topic_key')}: PENDING_OWNER→#{record.fetch('state')}"
    else
      OwnerConfirmation.validate_and_rewrite_proposal_v2!(record: record, path: record.path)
    end
    return
  end

  persisted = record.fetch("owner_confirmation")
  verified_at = persisted.fetch("verified_at")
  verified_time = OwnerConfirmation.parse_utc_timestamp(verified_at)
  assert_target_state!(artifact.fetch("issued_time").to_i <= verified_time.to_i && verified_time.to_i < artifact.fetch("expires_time").to_i)
  expected_confirmation = OwnerConfirmation.verified_owner_confirmation(
    reference: parsed.fetch("authorization_ref"),
    proposal_digest: artifact.dig("header", "proposal-digest"),
    decision: decision,
    principal: owner_config.fetch("principal"),
    verified_at: verified_at,
  )
  assert_target_state!(persisted == expected_confirmation)
  updated = verified_at.split("T").first
  raw_event_value = decision == "GO" ? parsed.fetch("backup_ref") : parsed.fetch("reason")
  expected_event = consume_event_line(
    verified_at: verified_at,
    decision: decision,
    reference: parsed.fetch("authorization_ref"),
    proposal_digest: artifact.dig("header", "proposal-digest"),
    principal: owner_config.fetch("principal"),
    raw_value: raw_event_value,
  )
  case decision
  when "GO"
    assert_target_state!(record["state"] == "ADOPTING")
    assert_target_state!(record["backup_ref"] == parsed.fetch("backup_ref"))
    assert_target_state!(record["effect_metric"] == parsed.fetch("effect_metric"))
    assert_target_state!(record["report_due"] == parsed.fetch("report_due"))
  when "REJECT"
    assert_target_state!(record["state"] == "REJECTED")
    reject_present_rollout!(record)
    expected_cooldown = OwnerConfirmation.utc_timestamp(Time.at(verified_time.to_i + (30 * 86_400)).utc)
    assert_target_state!(proposal_timestamp_string(record["cooldown_until"], "cooldown_until") == expected_cooldown)
  when "WATCH"
    assert_target_state!(record["state"] == "WATCH")
    reject_present_rollout!(record)
  end
  assert_target_state!(proposal_timestamp_string(record["state_entered_at"], "state_entered_at") == verified_at)
  assert_target_state!(record["updated"] == updated)
  require_exactly_one_event!(record.body_bytes, expected_event)
  puts "DRY-RUN #{record.fetch('topic_key')}: retry verified" if dry
end

def handle_complete(record_path:, now_raw:, dry:, args:)
  OwnerConfirmation.fail_closed("record-damaged", "complete argv mismatch") unless args.length == 5
  smoke = safe_line(args.fetch(0), "smoke-result")
  actor = actor_slug(args.fetch(1))
  where_text = args.fetch(2).to_s
  wrapper_root = OwnerConfirmation.canonicalize_root(args.fetch(3))
  early = args.fetch(4).to_s
  OwnerConfirmation.fail_closed("record-damaged", "early authorization unsupported") unless early.empty?

  record = OwnerConfirmation.load_proposal_record(path: record_path)
  OwnerConfirmation.fail_closed("record-damaged", "proposal must be v2") unless record["schema"] == "sgl-proposal/v2"
  root = record_root(record.path)
  OwnerConfirmation.fail_closed("record-damaged", "wrapper vault mismatch") unless root == wrapper_root
  OwnerConfirmation.fail_closed("record-damaged", "smoke-result must be an existing non-empty file") unless File.file?(smoke) && File.size?(smoke)
  owner_confirmation = record.fetch("owner_confirmation")
  OwnerConfirmation.fail_closed("record-damaged", "owner confirmation must be verified GO") unless owner_confirmation["status"] == "verified" && owner_confirmation["decision"] == "GO"

  now = effective_time(now_raw)
  case record.fetch("state")
  when "ADOPTING"
    entered = OwnerConfirmation.parse_utc_timestamp(proposal_timestamp_string(record.fetch("state_entered_at"), "state_entered_at"))
    OwnerConfirmation.fail_closed("record-damaged", "completion requires a 7-day observation window") if now.to_i < entered.to_i + (7 * 86_400)
    day = now.strftime("%Y-%m-%d")
    relative = adoption_record_relative_path(topic: record.fetch("topic_key"), date: day)
    bytes = adoption_record_bytes(
      record: record,
      root: root,
      smoke: smoke,
      actor: actor,
      where_text: where_text,
      date: day,
      owner_confirmation: owner_confirmation,
    )
    publish_adoption_record!(root: root, relative_path: relative, bytes: bytes) unless dry
    record["links"] = {} unless record["links"].is_a?(Hash)
    record["links"]["adoption_entry"] = relative
    record["state"] = "ADOPTED"
    now_s = OwnerConfirmation.utc_timestamp(now)
    record["state_entered_at"] = now_s
    record["updated"] = now.strftime("%Y-%m-%d")
    append_event(
      record,
      "- #{now_s} #{actor} ADOPTING→ADOPTED — adoption recorded; smoke_result=#{smoke}; effect report owner=#{actor}\n",
    )
    if dry
      puts "DRY-RUN #{record.fetch('topic_key')}: ADOPTING→ADOPTED"
    else
      OwnerConfirmation.validate_and_rewrite_proposal_v2!(record: record, path: record.path)
    end
  when "ADOPTED"
    state_day = proposal_timestamp_string(record.fetch("state_entered_at"), "state_entered_at").split("T").first
    expected_relative = adoption_record_relative_path(topic: record.fetch("topic_key"), date: state_day)
    actual_relative = record.dig("links", "adoption_entry").to_s
    OwnerConfirmation.fail_closed("record-damaged", "adoption_entry missing") if actual_relative.empty?
    OwnerConfirmation.fail_closed("record-damaged", "adoption_entry mismatch") unless actual_relative == expected_relative
    bytes = adoption_record_bytes(
      record: record,
      root: root,
      smoke: smoke,
      actor: actor,
      where_text: where_text,
      date: state_day,
      owner_confirmation: owner_confirmation,
    )
    read_existing_adoption_record!(
      root: root,
      relative_path: actual_relative,
      expected_bytes: bytes,
      create_parent: false,
    )
    puts "DRY-RUN #{record.fetch('topic_key')}: completion retry verified" if dry
  else
    OwnerConfirmation.fail_closed("record-damaged", "state must be ADOPTING or ADOPTED")
  end
end

def legacy_yaml_record(path)
  raw = File.binread(path).force_encoding(Encoding::UTF_8)
  abort "record is not UTF-8" unless raw.valid_encoding?
  lines = raw.lines
  abort "frontmatter missing" unless lines.first == "---\n" && (end_at = lines[1..-1].index("---\n"))
  end_at += 1
  data = YAML.safe_load(lines[0..end_at].join, permitted_classes: [Date, Time], aliases: false)
  abort "frontmatter is not a mapping" unless data.is_a?(Hash)
  [raw, lines, end_at, data]
end

def legacy_timestamp(value)
  policy_fail("timestamp must be ISO8601Z") unless value.to_s.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/)
  Time.iso8601(value).utc
rescue ArgumentError
  policy_fail("timestamp must be ISO8601Z")
end

def legacy_required_state!(state, expected)
  policy_fail("state must be #{expected}; found #{state}") unless state == expected
end

def write_legacy_record(path:, lines:, end_at:, data:, body:, event:, dry:)
  frontmatter = YAML.dump(data)
  output = frontmatter + "---\n" + body + (body.end_with?("\n") ? "" : "\n") + event + "\n"
  if dry
    puts "DRY-RUN #{data['topic_key']}: #{data['state']}"
    return
  end
  temp = "#{path}.adopt.#{$$}"
  File.open(temp, "w") { |file| file.write(output); file.flush; file.fsync }
  YAML.safe_load(File.binread(temp), permitted_classes: [Date, Time], aliases: false)
  File.rename(temp, path)
end

def handle_legacy_abort_or_rollback(command:, record_path:, now_raw:, dry:, args:, lines:, end_at:, data:)
  body = lines[(end_at + 1)..-1].join
  state = data["state"].to_s
  now_time = effective_time(now_raw)
  now = now_time.strftime("%Y-%m-%dT%H:%M:%SZ")

  case command
  when "abort"
    reason = safe_line(args.fetch(0), "reason")
    legacy_required_state!(state, "ADOPTING")
    data["state"] = "DLQ"
    rollback = data["reversibility"].to_s
    event = "- #{now} alpha ADOPTING→DLQ — rollback_required: #{rollback.empty? ? 'declared reversibility missing' : rollback}; reason=#{reason}"
  when "rollback"
    evidence = safe_line(args.fetch(0), "evidence")
    legacy_required_state!(state, "DLQ")
    policy_fail("evidence must be an existing non-empty file") unless File.file?(evidence) && File.size?(evidence)
    origin = body.each_line.to_a.reverse.find { |line| line.match?(/^\-\s+\S+\s+\S+\s+\S+→DLQ\b/) }.to_s
    policy_fail("DLQ was not reached from ADOPTING with rollback_required") unless origin.match?(/\bADOPTING→DLQ\b/) && origin.include?("rollback_required")
    data["state"] = "REJECTED"
    data["cooldown_until"] = (now_time + (30 * 86_400)).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    event = "- #{now} alpha DLQ→REJECTED — rollback verified — #{evidence}"
  else
    policy_fail("unsupported legacy command")
  end

  data["state_entered_at"] = now
  data["updated"] = now.split("T").first
  write_legacy_record(
    path: record_path,
    lines: lines,
    end_at: end_at,
    data: data,
    body: body,
    event: event,
    dry: dry,
  )
end

def handle_v2_abort_or_rollback(command:, record_path:, now_raw:, dry:, args:)
  OwnerConfirmation.fail_closed("record-damaged", "#{command} argv mismatch") unless args.length == 1

  record = OwnerConfirmation.load_proposal_record(path: record_path)
  OwnerConfirmation.fail_closed("record-damaged", "proposal must be v2") unless record["schema"] == "sgl-proposal/v2"

  body = record.body_bytes.to_s.dup.force_encoding(Encoding::UTF_8)
  OwnerConfirmation.fail_closed("record-damaged", "proposal body is not valid UTF-8") unless body.valid_encoding?

  now_time = effective_time(now_raw)
  now = OwnerConfirmation.utc_timestamp(now_time)

  case command
  when "abort"
    reason = safe_line(args.fetch(0), "reason")
    OwnerConfirmation.fail_closed("record-damaged", "state must be ADOPTING; found #{record['state']}") unless record["state"] == "ADOPTING"
    record["state"] = "DLQ"
    rollback = record["reversibility"].to_s
    event = "- #{now} alpha ADOPTING→DLQ — rollback_required: #{rollback.empty? ? 'declared reversibility missing' : rollback}; reason=#{reason}\n"
  when "rollback"
    evidence = safe_line(args.fetch(0), "evidence")
    OwnerConfirmation.fail_closed("record-damaged", "state must be DLQ; found #{record['state']}") unless record["state"] == "DLQ"
    OwnerConfirmation.fail_closed("record-damaged", "evidence must be an existing non-empty file") unless File.file?(evidence) && File.size?(evidence)
    origin = body.each_line.to_a.reverse.find { |line| line.match?(/^\-\s+\S+\s+\S+\s+\S+→DLQ\b/) }.to_s
    unless origin.match?(/\bADOPTING→DLQ\b/) && origin.include?("rollback_required")
      OwnerConfirmation.fail_closed("record-damaged", "DLQ was not reached from ADOPTING with rollback_required")
    end
    record["state"] = "REJECTED"
    record["cooldown_until"] = OwnerConfirmation.utc_timestamp(Time.at(now_time.to_i + (30 * 86_400)).utc)
    event = "- #{now} alpha DLQ→REJECTED — rollback verified — #{evidence}\n"
  else
    OwnerConfirmation.fail_closed("record-damaged", "unsupported v2 command")
  end

  record["state_entered_at"] = now
  record["updated"] = now.split("T").first
  append_event(record, event)

  if dry
    puts "DRY-RUN #{record.fetch('topic_key')}: #{record.fetch('state')}"
  else
    OwnerConfirmation.validate_and_rewrite_proposal_v2!(record: record, path: record.path)
  end
end

def handle_abort_or_rollback(command:, record_path:, now_raw:, dry:, args:)
  _raw, lines, end_at, data = legacy_yaml_record(record_path)
  if data["schema"] == "sgl-proposal/v2"
    handle_v2_abort_or_rollback(
      command: command,
      record_path: record_path,
      now_raw: now_raw,
      dry: dry,
      args: args,
    )
    return
  end

  handle_legacy_abort_or_rollback(
    command: command,
    record_path: record_path,
    now_raw: now_raw,
    dry: dry,
    args: args,
    lines: lines,
    end_at: end_at,
    data: data,
  )
end

begin
  case command
  when "approve", "reject", "watch"
    handle_consume(command: command, record_path: record_path, dry: dry_run?(dry_flag), args: args)
  when "complete"
    handle_complete(record_path: record_path, now_raw: now_raw, dry: dry_run?(dry_flag), args: args)
  when "abort", "rollback"
    handle_abort_or_rollback(
      command: command,
      record_path: record_path,
      now_raw: now_raw,
      dry: dry_run?(dry_flag),
      args: args,
    )
  end
rescue OwnerConfirmation::Error => e
  warn e.code
  exit 3
end
