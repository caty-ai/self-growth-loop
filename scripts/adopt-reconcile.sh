#!/usr/bin/env bash
set -u

# shellcheck disable=SC2034 # consumed by sourced helper
ADOPT_TOOL=adopt-reconcile.sh
# shellcheck disable=SC1091
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lib-adopt.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  adopt-reconcile.sh --vault <root> --topic <key> [--workspace <root>] [--now <ISO8601Z>]
  adopt-reconcile.sh --vault <root> --topic <key> --restore-backup <vault-relative path>
EOF
}

fail() { echo "adopt-reconcile.sh: $*" >&2; exit 2; }

need_value() { [ "$#" -ge 2 ] || { usage; exit 2; }; }

vault=''
topic=''
workspace=''
restore_backup=''
now_override=''
seen_vault=0
seen_topic=0
seen_workspace=0
seen_restore_backup=0
seen_now=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --vault|--topic|--workspace|--restore-backup|--now)
      need_value "$@"
      case "$1" in
        --vault)
          [ "$seen_vault" -eq 0 ] || fail 'duplicate option: --vault'
          vault=$2
          seen_vault=1
          ;;
        --topic)
          [ "$seen_topic" -eq 0 ] || fail 'duplicate option: --topic'
          topic=$2
          seen_topic=1
          ;;
        --workspace)
          [ "$seen_workspace" -eq 0 ] || fail 'duplicate option: --workspace'
          workspace=$2
          seen_workspace=1
          ;;
        --restore-backup)
          [ "$seen_restore_backup" -eq 0 ] || fail 'duplicate option: --restore-backup'
          restore_backup=$2
          seen_restore_backup=1
          ;;
        --now)
          [ "$seen_now" -eq 0 ] || fail 'duplicate option: --now'
          now_override=$2
          seen_now=1
          ;;
      esac
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      fail "unknown or incomplete option: $1"
      ;;
  esac
done

[ -n "$vault" ] && [ -n "$topic" ] || { usage; exit 2; }
adopt_validate_topic "$topic"

if [ "$seen_restore_backup" -eq 1 ]; then
  [ -n "$restore_backup" ] || { usage; exit 2; }
  [ "$seen_workspace" -eq 0 ] || fail '--workspace is incompatible with --restore-backup'
  [ "$seen_now" -eq 0 ] || fail '--now is incompatible with --restore-backup'
fi

run_reconcile_locked() {
  RECONCILE_REPO_ROOT=$(adopt_repo_root) \
  RECONCILE_VAULT=$vault \
  RECONCILE_TOPIC=$topic \
  RECONCILE_WORKSPACE=$workspace \
  RECONCILE_RESTORE_BACKUP=$restore_backup \
  RECONCILE_NOW=$now_override \
  ruby <<'RUBY'
require "fileutils"
require "pathname"
require "stringio"
require "time"
require "yaml"
require "zlib"

repo_root = ENV.fetch("RECONCILE_REPO_ROOT")
require File.join(repo_root, "scripts", "lib-owner-confirmation")

module ReconcileCLI
  module_function

  BACKUPS_RELATIVE_DIR = "45_ai-systems/self-growth/backups".freeze
  PROPOSALS_RELATIVE_DIR = "45_ai-systems/self-growth/proposals".freeze
  CONFIRMATIONS_RELATIVE_DIR = "45_ai-systems/self-growth/confirmations".freeze
  EVENTS_HEADING = "## Events (append-only)\n".b.freeze
  ATTEMPT_BASIS = "legacy-no-correlation-observed".freeze
  FORBIDDEN_EVENT_SUBSTRINGS = %w[
    proposal_attempt owner_confirmation proposal-digest authorization-ref
  ].freeze
  LEGACY_T0_SENTENCE = "T0 fast path: this reversible, non-identity-critical proposal skips council review and remains subject to the Sho human gate.\n\n".freeze

  class UsageError < StandardError; end

  def fail_closed(code, detail = nil)
    raise OwnerConfirmation::Error.new(code, detail)
  end

  def usage_fail(message)
    raise UsageError, message
  end

  def inputs
    @inputs ||= {
      vault: ENV.fetch("RECONCILE_VAULT"),
      topic: ENV.fetch("RECONCILE_TOPIC"),
      workspace: ENV.fetch("RECONCILE_WORKSPACE", ""),
      restore_backup: ENV.fetch("RECONCILE_RESTORE_BACKUP", ""),
      now: ENV.fetch("RECONCILE_NOW", ""),
    }
  end

  def restore_mode?
    !inputs[:restore_backup].empty?
  end

  def vault_root
    @vault_root ||= OwnerConfirmation.canonicalize_root(inputs[:vault])
  end

  def topic_key
    @topic_key ||= OwnerConfirmation.validate_topic_key!(inputs[:topic])
  end

  def proposal_relative_path
    "#{PROPOSALS_RELATIVE_DIR}/#{topic_key}.md"
  end

  def proposal_path
    File.join(vault_root, proposal_relative_path)
  end

  def proposal_record
    @proposal_record ||= begin
      record = OwnerConfirmation.load_proposal_record(path: proposal_path)
      fail_closed("record-damaged", "topic mismatch") unless record["topic_key"] == topic_key
      record
    end
  end

  def sampled_now
    @sampled_now ||= begin
      raw = inputs[:now]
      if raw.nil? || raw.empty?
        Time.now.utc
      else
        parsed = OwnerConfirmation.parse_utc_timestamp(raw)
        Time.at(parsed.to_i).utc
      end
    end
  end

  def sampled_now_iso
    OwnerConfirmation.utc_timestamp(sampled_now)
  end

  def sampled_now_backup_stamp
    sampled_now.utc.strftime("%Y%m%dt%H%M%Sz")
  end

  def backup_basename(timestamp = sampled_now_backup_stamp)
    "reconcile-#{timestamp}-#{topic_key}.tar.gz"
  end

  def backup_relative_path(timestamp = sampled_now_backup_stamp)
    "#{BACKUPS_RELATIVE_DIR}/#{backup_basename(timestamp)}"
  end

  def backup_relative_path_re
    /\A45_ai-systems\/self-growth\/backups\/reconcile-[0-9]{8}t[0-9]{6}z-#{Regexp.escape(topic_key)}\.tar\.gz\z/
  end

  def backup_filename_re
    /\Areconcile-[0-9]{8}t[0-9]{6}z-#{Regexp.escape(topic_key)}\.tar\.gz\z/
  end

  def backup_temp_filename_re
    /\A\.reconcile-[0-9]{8}t[0-9]{6}z-#{Regexp.escape(topic_key)}\.tar\.gz\.tmp\.[1-9][0-9]*\.[0-9a-f]{16}\z/
  end

  def pending_confirmation
    OwnerConfirmation.pending_owner_confirmation
  end

  def ensure_workspace_unused!
    usage_fail("--workspace is only valid for legacy T0 PENDING_SHO reconciliation") unless inputs[:workspace].empty?
  end

  def workspace_root
    usage_fail("--workspace is required for legacy T0 PENDING_SHO reconciliation") if inputs[:workspace].empty?
    @workspace_root ||= OwnerConfirmation.canonicalize_root(inputs[:workspace])
  end

  def confirmations_topic_relative_path
    "#{CONFIRMATIONS_RELATIVE_DIR}/#{topic_key}"
  end

  def confirmations_topic_path
    File.join(vault_root, confirmations_topic_relative_path)
  end

  def topic_confirmation_directory_absent!
    return unless path_entry_exists?(confirmations_topic_path)
    fail_closed("attempt-namespace-occupied", confirmations_topic_relative_path)
  end

  def path_entry_exists?(path)
    File.lstat(path)
    true
  rescue Errno::ENOENT, Errno::ENOTDIR
    false
  end

  def lstat_regular_nonsymlink!(path, token)
    stat = File.lstat(path)
    fail_closed("#{token}-symlink") if stat.symlink?
    fail_closed("#{token}-not-regular") unless stat.file?
    stat
  rescue Errno::ENOENT, Errno::ENOTDIR
    fail_closed("#{token}-missing")
  end

  def fsync_directory(path)
    OwnerConfirmation.fsync_directory(path)
  end

  def ensure_directory_tree!(relative_path, mode: 0o700)
    current = vault_root
    relative_path.split("/").each do |component|
      fail_closed("backups-directory-invalid", "noncanonical path component") if component.empty? || component == "." || component == ".."
      current = File.join(current, component)
      if path_entry_exists?(current)
        stat = File.lstat(current)
        fail_closed("backups-directory-invalid", component) if stat.symlink? || !stat.directory?
        real = File.realpath(current)
        prefix = vault_root.end_with?(File::SEPARATOR) ? vault_root : "#{vault_root}#{File::SEPARATOR}"
        fail_closed("backups-directory-invalid", component) unless real == current && real.start_with?(prefix)
      else
        Dir.mkdir(current, mode)
        File.chmod(mode, current)
        fsync_directory(File.dirname(current))
      end
    end
    current
  end

  def backups_directory_path
    @backups_directory_path ||= ensure_directory_tree!(BACKUPS_RELATIVE_DIR, mode: 0o700)
  end

  def require_legacy_record!(record)
    fail_closed("record-damaged", "proposal is not a closed legacy record") unless record.respond_to?(:legacy) && record.legacy
    fail_closed("record-damaged", "proposal top-level keys/order do not match legacy schema") unless record.keys == OwnerConfirmation::LEGACY_PROPOSAL_KEYS
    validate_legacy_record_shape!(record)
    record
  end

  def validate_legacy_record_shape!(record)
    OwnerConfirmation.validate_topic_key!(record.fetch("topic_key"))
    OwnerConfirmation.actual_string!(record.fetch("title"), "title", min_bytes: 1, control_free: true)
    state = record.fetch("state")
    OwnerConfirmation.actual_string!(state, "state", ascii: true)
    fail_closed("record-damaged", "unsupported legacy state") unless %w[
      PROPOSED TRIALING COUNCIL PENDING_SHO ADOPTING ADOPTED EXPIRED REJECTED DLQ WATCH
    ].include?(state)
    canonical_timestamp_value!(record.fetch("state_entered_at"), "state_entered_at")
    risk_tier = record.fetch("risk_tier")
    OwnerConfirmation.actual_string!(risk_tier, "risk_tier", ascii: true)
    fail_closed("record-damaged", "risk_tier must be T0, T1, or T2") unless %w[T0 T1 T2].include?(risk_tier)
    fail_closed("record-damaged", "identity_critical must be boolean") unless record.fetch("identity_critical") == true || record.fetch("identity_critical") == false
    tiebreak = record.fetch("tiebreak")
    OwnerConfirmation.actual_string!(tiebreak, "tiebreak", ascii: true)
    fail_closed("record-damaged", "tiebreak must be T0, T1, or T2") unless %w[T0 T1 T2].include?(tiebreak)
    proposer = record.fetch("proposer")
    OwnerConfirmation.actual_string!(proposer, "proposer", min_bytes: 1, max_bytes: 64, ascii: true)
    fail_closed("record-damaged", "proposer invalid") unless /\A[a-z0-9_-]+\z/.match?(proposer)
    %w[executor_agent executor_model backup_ref effect_metric reversibility].each do |key|
      OwnerConfirmation.actual_string!(record.fetch(key), key, control_free: true)
    end
    %w[created updated].each { |key| canonical_date_value!(record.fetch(key), key) }
    cooldown = record.fetch("cooldown_until")
    cooldown_text = canonical_optional_timestamp_value!(cooldown, "cooldown_until")
    retry_count = record.fetch("retry_count")
    fail_closed("record-damaged", "retry_count must be a nonnegative integer") unless retry_count.is_a?(Integer) && retry_count >= 0
    source_items = record.fetch("source_items")
    fail_closed("record-damaged", "source_items must be a sequence") unless source_items.is_a?(Array)
    source_items.each do |item|
      fail_closed("record-damaged", "source_items entry must be a mapping") unless item.is_a?(Hash) && item.keys == %w[url seen report]
      OwnerConfirmation.actual_string!(item.fetch("url"), "source_items.url", min_bytes: 1, control_free: true)
      canonical_date_value!(item.fetch("seen"), "source_items.seen")
      OwnerConfirmation.actual_string!(item.fetch("report"), "source_items.report", min_bytes: 1, control_free: true)
    end
    links = record.fetch("links")
    fail_closed("record-damaged", "links must be a mapping") unless links.is_a?(Hash) && links.keys == %w[trial_bundle council_verdicts adoption_entry]
    links.each do |key, value|
      OwnerConfirmation.actual_string!(value, "links.#{key}", control_free: true)
    end
    report_due = record.fetch("report_due")
    canonical_optional_timestamp_value!(report_due, "report_due")
    record
  end

  def canonical_date_value!(value, label)
    string =
      case value
      when Date
        value.strftime("%Y-%m-%d")
      when String
        OwnerConfirmation.actual_string!(value, label, ascii: true)
        value
      else
        fail_closed("record-damaged", "#{label} invalid")
      end
    match = /\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/.match(string)
    fail_closed("record-damaged", "#{label} invalid") unless match
    year, month, day = match.captures.map(&:to_i)
    fail_closed("record-damaged", "#{label} invalid") unless Date.valid_date?(year, month, day)
    string
  end

  def canonical_timestamp_value!(value, label)
    string =
      case value
      when Time
        OwnerConfirmation.utc_timestamp(Time.at(value.to_i).utc)
      when String
        OwnerConfirmation.actual_string!(value, label, ascii: true)
        value
      else
        fail_closed("record-damaged", "#{label} invalid")
      end
    OwnerConfirmation.parse_utc_timestamp(string)
    string
  end

  def canonical_optional_timestamp_value!(value, label)
    case value
    when ""
      ""
    when String
      return "" if value.empty?
      canonical_timestamp_value!(value, label)
    when Time
      canonical_timestamp_value!(value, label)
    else
      fail_closed("record-damaged", "#{label} invalid")
    end
  end

  def classify_legacy_state!(record)
    state = record.fetch("state")
    case state
    when "PROPOSED", "TRIALING", "COUNCIL", "PENDING_SHO"
      state
    when "ADOPTING"
      fail_closed("legacy-adopting-reconcile-unsupported")
    when "ADOPTED", "EXPIRED", "REJECTED", "DLQ", "WATCH"
      fail_closed("legacy-terminal-reconcile-unsupported")
    else
      fail_closed("record-damaged", "unsupported legacy state")
    end
  end

  def extract_events_payload!(record)
    bytes = record.body_bytes
    first = bytes.index(EVENTS_HEADING)
    fail_closed("record-damaged", "events heading missing") unless first
    second = bytes.index(EVENTS_HEADING, first + EVENTS_HEADING.bytesize)
    fail_closed("record-damaged", "events heading duplicated") if second
    bytes.byteslice(first + EVENTS_HEADING.bytesize, bytes.bytesize - first - EVENTS_HEADING.bytesize) || "".b
  end

  def legacy_migration_guards!(record)
    topic_confirmation_directory_absent!
    fail_closed("record-damaged", "links.adoption_entry must be empty") unless record.dig("links", "adoption_entry") == ""
    payload = extract_events_payload!(record)
    FORBIDDEN_EVENT_SUBSTRINGS.each do |needle|
      fail_closed("legacy-correlation-observed", needle) if payload.include?(needle)
    end
    payload
  end

  def t0_legacy_artifact_bytes(state_entered_at)
    LEGACY_T0_SENTENCE + "- #{canonical_timestamp_value!(state_entered_at, 'state_entered_at')} alpha COUNCIL→PENDING_SHO — auto-adopt path (T0), council skipped\n"
  end

  def expected_t0_artifact_relative_path(record)
    trial_reference = OwnerConfirmation.validate_trial_reference!(record.dig("links", "trial_bundle"), record.fetch("topic_key"))
    task_id = OwnerConfirmation.task_id_from_trial_reference(trial_reference)
    "45_ai-systems/self-growth/council/#{record.fetch('topic_key')}/#{task_id}.t0-skip.md"
  end

  def build_reconciled_v2_record(legacy_record:, proposal_attempt:, backup_rel:, event_time_iso:)
    values = {}
    OwnerConfirmation::PROPOSAL_KEYS.each do |key|
      values[key] =
        case key
        when "schema"
          "sgl-proposal/v2"
        when "proposal_attempt"
          proposal_attempt
        when "owner_confirmation"
          pending_confirmation
        else
          OwnerConfirmation.deep_copy(legacy_record.fetch(key))
        end
    end
    event = "- #{event_time_iso} alpha EVENT — legacy proposal reconciled to sgl-proposal/v2; proposal_attempt=#{proposal_attempt}; attempt_basis=#{ATTEMPT_BASIS}; backup=#{backup_rel}\n"
    record = OwnerConfirmation::ProposalRecord.new(values)
    record.path = legacy_record.path
    record.legacy = false
    record.body_bytes = append_event(legacy_record.body_bytes, event)
    record
  end

  def append_event(body_bytes, event_line)
    bytes = body_bytes.dup
    bytes += "\n".b unless bytes.empty? || bytes.end_with?("\n".b)
    bytes + event_line.b
  end

  def build_reconciled_v2_bytes(legacy_record:, proposal_attempt:, backup_rel:, event_time_iso:)
    record = build_reconciled_v2_record(
      legacy_record: legacy_record,
      proposal_attempt: proposal_attempt,
      backup_rel: backup_rel,
      event_time_iso: event_time_iso,
    )
    OwnerConfirmation.validate_and_rewrite_proposal_v2!(record: record)
  end

  def backup_member_map_for_current_legacy(record:, t0_legacy_bytes: nil)
    members = { proposal_relative_path => record.source_bytes.b }
    if t0_legacy_bytes
      members[expected_t0_artifact_relative_path(record)] = t0_legacy_bytes.b
    end
    members
  end

  def t0_artifact_relative_path_for_record(record)
    evidence = OwnerConfirmation.derive_t0_evidence(
      vault_root: vault_root,
      workspace_root: workspace_root,
      record: record,
    )
    relative = evidence.fetch("artifact_relative_path")
    fail_closed("evidence-damaged", "unexpected T0 artifact path") unless relative == expected_t0_artifact_relative_path(record)
    relative
  end

  def build_tar_gz(member_map)
    payload = build_posix_ustar(member_map)
    out = StringIO.new("".b)
    Zlib::GzipWriter.wrap(out) do |gz|
      gz.mtime = 0
      gz.orig_name = ""
      gz.comment = ""
      gz.write(payload)
    end
    out.string.b
  end

  def build_posix_ustar(member_map)
    output = +"".b
    member_map.each do |name, bytes|
      output << tar_header(name, bytes.bytesize)
      output << bytes.b
      pad = (512 - (bytes.bytesize % 512)) % 512
      output << ("\0".b * pad)
    end
    output << ("\0".b * 1024)
    output
  end

  def tar_header(name, size)
    fail_closed("reconcile-backup-member-invalid", name) unless name.is_a?(String) && !name.empty? && name.ascii_only?
    prefix = ""
    short_name = name
    if name.bytesize > 100
      split = name.rindex("/", 155)
      fail_closed("reconcile-backup-member-invalid", name) unless split && split < name.bytesize - 1
      prefix = name.byteslice(0, split)
      short_name = name.byteslice(split + 1, name.bytesize - split - 1)
      fail_closed("reconcile-backup-member-invalid", name) unless short_name.bytesize <= 100 && prefix.bytesize <= 155
    end
    header = "\0".b * 512
    write_tar_field(header, 0, 100, short_name)
    write_tar_octal(header, 100, 8, 0o600)
    write_tar_octal(header, 108, 8, 0)
    write_tar_octal(header, 116, 8, 0)
    write_tar_octal(header, 124, 12, size)
    write_tar_octal(header, 136, 12, 0)
    header.setbyte(156, "0".ord)
    write_tar_field(header, 257, 6, "ustar\0")
    write_tar_field(header, 263, 2, "00")
    write_tar_field(header, 345, 155, prefix)
    148.upto(155) { |index| header.setbyte(index, 0x20) }
    checksum = header.bytes.sum
    checksum_text = format("%06o\0 ", checksum)
    write_tar_field(header, 148, 8, checksum_text)
    header
  end

  def write_tar_field(header, offset, length, value)
    bytes = value.b
    fail_closed("reconcile-backup-member-invalid") if bytes.bytesize > length
    bytes.each_byte.with_index { |byte, index| header.setbyte(offset + index, byte) }
  end

  def write_tar_octal(header, offset, length, value)
    text = format("%0#{length - 1}o", value)
    fail_closed("reconcile-backup-member-invalid") if text.bytesize > length - 1
    write_tar_field(header, offset, length, text + "\0")
  end

  def read_backup_archive(path)
    bytes = OwnerConfirmation.read_regular_file(path, max_bytes: OwnerConfirmation::MAX_PROPOSAL_BYTES * 4, label: "reconcile-backup")
    tar_bytes = gunzip_single_member(bytes)
    parse_ustar_entries(tar_bytes)
  end

  def gunzip_single_member(bytes)
    io = StringIO.new(bytes)
    gz = Zlib::GzipReader.new(io)
    payload = gz.read
    trailing = gz.unused
    gz.close
    fail_closed("reconcile-backup-invalid", "gzip trailing bytes present") unless trailing.nil? || trailing.empty?
    payload.b
  rescue Zlib::GzipFile::Error, Zlib::Error => e
    fail_closed("reconcile-backup-invalid", e.message)
  end

  def parse_ustar_entries(bytes)
    fail_closed("reconcile-backup-invalid", "tar payload misaligned") unless (bytes.bytesize % 512).zero?
    offset = 0
    members = {}
    saw_terminator = false
    while offset < bytes.bytesize
      block = bytes.byteslice(offset, 512)
      fail_closed("reconcile-backup-invalid", "short tar header") unless block && block.bytesize == 512
      if block == ("\0".b * 512)
        saw_terminator = true
        rest = bytes.byteslice(offset, bytes.bytesize - offset) || "".b
        fail_closed("reconcile-backup-invalid", "nonzero tar trailer") unless rest.bytes.all?(&:zero?)
        break
      end
      fail_closed("reconcile-backup-invalid", "tar entry after terminator") if saw_terminator
      name = tar_name(block)
      typeflag = block.getbyte(156)
      fail_closed("reconcile-backup-invalid", "unsupported tar entry type") unless typeflag == 0 || typeflag == "0".ord
      fail_closed("reconcile-backup-invalid", "ustar magic mismatch") unless block.byteslice(257, 6) == "ustar\0"
      fail_closed("reconcile-backup-invalid", "ustar version mismatch") unless block.byteslice(263, 2) == "00"
      size = parse_tar_octal(block.byteslice(124, 12), "size")
      data_start = offset + 512
      data_end = data_start + size
      fail_closed("reconcile-backup-invalid", "tar entry truncated") if data_end > bytes.bytesize
      data = bytes.byteslice(data_start, size) || "".b
      fail_closed("reconcile-backup-invalid", "duplicate tar member") if members.key?(name)
      members[name] = data.b
      offset = data_start + (((size + 511) / 512) * 512)
    end
    fail_closed("reconcile-backup-invalid", "tar terminator missing") unless saw_terminator
    members
  end

  def tar_name(block)
    name = trim_tar_string(block.byteslice(0, 100))
    prefix = trim_tar_string(block.byteslice(345, 155))
    full = prefix.empty? ? name : "#{prefix}/#{name}"
    fail_closed("reconcile-backup-invalid", "empty tar member name") if full.empty?
    fail_closed("reconcile-backup-invalid", "noncanonical tar member name") if full.start_with?("/") || full.split("/").any? { |part| part.empty? || part == "." || part == ".." }
    full
  end

  def trim_tar_string(bytes)
    value = bytes.to_s.sub(/\A\0+/, "")
    nul = value.index("\0")
    value = value.byteslice(0, nul) if nul
    value
  end

  def parse_tar_octal(bytes, label)
    text = bytes.to_s
    fail_closed("reconcile-backup-invalid", "invalid tar #{label}") if text.bytes.any? { |byte| byte >= 0x80 }
    stripped = text.delete(" \0")
    return 0 if stripped.empty?
    fail_closed("reconcile-backup-invalid", "invalid tar #{label}") unless /\A[0-7]+\z/.match?(stripped)
    stripped.to_i(8)
  end

  def exact_backup_member_map!(path, expected_members)
    actual = read_backup_archive(path)
    fail_closed("reconcile-backup-invalid", "member set mismatch") unless actual.keys.sort == expected_members.keys.sort
    expected_members.each do |name, expected_bytes|
      fail_closed("reconcile-backup-invalid", "member byte mismatch") unless actual[name] == expected_bytes.b
    end
    actual
  end

  def scan_existing_backups!
    ensure_directory_tree!(BACKUPS_RELATIVE_DIR, mode: 0o700)
    temp_matches = []
    final_matches = []
    Dir.each_child(backups_directory_path) do |entry|
      path = File.join(backups_directory_path, entry)
      stat = File.lstat(path)
      if backup_temp_filename_re.match?(entry)
        temp_matches << path if stat.file? && !stat.symlink?
        next
      end
      next unless backup_filename_re.match?(entry)
      fail_closed("reconcile-backup-conflict", entry) if stat.symlink? || !stat.file?
      final_matches << path
    end
    fail_closed("stale-reconcile-temp", temp_matches.first) unless temp_matches.empty?
    final_matches.sort
  end

  def choose_or_create_backup!(expected_members)
    existing = scan_existing_backups!
    if existing.empty?
      create_new_backup!(expected_members)
    elsif existing.length == 1
      exact_backup_member_map!(existing.first, expected_members)
      path_to_relative(existing.first)
    else
      fail_closed("reconcile-backup-conflict", "multiple matching backup candidates")
    end
  end

  def create_new_backup!(expected_members)
    archive_bytes = build_tar_gz(expected_members)
    final_rel = backup_relative_path
    final_path = File.join(vault_root, final_rel)
    temp_path = nil
    temp_path = File.join(
      backups_directory_path,
      ".#{backup_basename}.tmp.#{$$}.#{SecureRandom.hex(8)}",
    )
    fail_closed("stale-reconcile-temp", File.basename(temp_path)) if path_entry_exists?(temp_path)
    durable_publish_temp_file!(temp_path, archive_bytes)
    exact_backup_member_map!(temp_path, expected_members)
    begin
      File.link(temp_path, final_path)
    rescue Errno::EEXIST
      fail_closed("reconcile-backup-conflict", final_rel)
    end
    fsync_directory(backups_directory_path)
    exact_backup_member_map!(final_path, expected_members)
    File.delete(temp_path)
    fsync_directory(backups_directory_path)
    final_rel
  rescue
    if path_entry_exists?(temp_path)
      File.delete(temp_path) rescue nil
      fsync_directory(backups_directory_path) rescue nil
    end
    raise
  end

  def durable_publish_temp_file!(destination, bytes)
    directory = File.dirname(destination)
    stage = File.join(directory, ".#{File.basename(destination)}.stage.#{$$}.#{SecureRandom.hex(8)}")
    begin
      File.open(stage, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      fail_closed("reconcile-backup-invalid", "temporary byte mismatch") unless File.binread(stage) == bytes.b
      File.rename(stage, destination)
      fsync_directory(directory)
      fsync_directory(directory)
    ensure
      if path_entry_exists?(stage)
        File.delete(stage)
        fsync_directory(directory)
      end
    end
  end

  def path_to_relative(path)
    prefix = vault_root.end_with?(File::SEPARATOR) ? vault_root : "#{vault_root}#{File::SEPARATOR}"
    fail_closed("reconcile-backup-path-invalid") unless path.start_with?(prefix)
    path.byteslice(prefix.bytesize, path.bytesize - prefix.bytesize)
  end

  def restore_backup_relative
    value = inputs[:restore_backup]
    OwnerConfirmation.actual_string!(value, "restore backup", ascii: true, min_bytes: 1)
    fail_closed("restore-backup-invalid") unless backup_relative_path_re.match?(value)
    value
  end

  def restore_backup_path
    @restore_backup_path ||= canonical_backup_path(restore_backup_relative)
  end

  def canonical_backup_path(relative_path)
    OwnerConfirmation.canonical_contained_path(
      root: vault_root,
      relative_path: relative_path,
      max_bytes: OwnerConfirmation::MAX_PROPOSAL_BYTES * 4,
      label: "reconcile-backup",
    )
  end

  def parse_reconcile_event_from_v2!(record, expected_backup_rel: nil)
    fail_closed("reconcile-scope-unsupported", "proposal must be v2") unless record["schema"] == "sgl-proposal/v2"
    fail_closed("reconcile-scope-unsupported", "owner_confirmation must stay pending") unless record["owner_confirmation"] == pending_confirmation
    payload = OwnerConfirmation.valid_utf8_bytes!(extract_events_payload!(record), "reconcile-scope-unsupported", "events")
    lines = payload.lines
    marker = "alpha EVENT — legacy proposal reconciled to sgl-proposal/v2;"
    matches = lines.select { |line| line.include?(marker) }
    fail_closed("reconcile-scope-unsupported", "reconciliation event missing") unless matches.length == 1
    line = matches.first
    regex = /\A- ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z) alpha EVENT — legacy proposal reconciled to sgl-proposal\/v2; proposal_attempt=(0|1); attempt_basis=(legacy-no-correlation-observed); backup=(.+)\n\z/
    match = regex.match(line)
    fail_closed("reconcile-scope-unsupported", "reconciliation event malformed") unless match
    backup_rel = match[4]
    fail_closed("reconcile-scope-unsupported", "backup reference malformed") unless backup_relative_path_re.match?(backup_rel)
    if expected_backup_rel && backup_rel != expected_backup_rel
      fail_closed("restore-backup-mismatch")
    end
    {
      event_time: match[1],
      proposal_attempt: match[2].to_i,
      attempt_basis: match[3],
      backup_relative_path: backup_rel,
    }
  end

  def derive_attempt_from_legacy_state(state)
    case state
    when "PROPOSED", "TRIALING", "COUNCIL" then 0
    when "PENDING_SHO" then 1
    else fail_closed("reconcile-backup-invalid", "legacy state is not migratable")
    end
  end

  def validate_reconcile_archive_members!(member_map)
    allowed = [1, 2]
    fail_closed("reconcile-backup-invalid", "member count mismatch") unless allowed.include?(member_map.length)
    proposal_bytes = member_map[proposal_relative_path]
    fail_closed("reconcile-backup-invalid", "proposal member missing") unless proposal_bytes
    legacy_record = OwnerConfirmation.parse_proposal_bytes(proposal_bytes, path: proposal_path)
    require_legacy_record!(legacy_record)
    state = classify_legacy_state!(legacy_record)
    if member_map.length == 2
      fail_closed("reconcile-backup-invalid", "two-member backup only allowed for legacy T0 PENDING_SHO") unless state == "PENDING_SHO" && legacy_record["risk_tier"] == "T0"
      t0_rel = expected_t0_artifact_relative_path(legacy_record)
      legacy_t0 = member_map[t0_rel]
      fail_closed("reconcile-backup-invalid", "legacy T0 member missing") unless legacy_t0
      fail_closed("reconcile-backup-invalid", "unexpected extra member") unless member_map.keys.sort == [proposal_relative_path, t0_rel].sort
      expected_legacy_t0 = t0_legacy_artifact_bytes(legacy_record.fetch("state_entered_at"))
      fail_closed("reconcile-backup-invalid", "legacy T0 bytes mismatch") unless legacy_t0 == expected_legacy_t0.b
      {
        legacy_record: legacy_record,
        proposal_attempt: 1,
        t0_relative_path: t0_rel,
        legacy_t0_bytes: legacy_t0.b,
      }
    else
      fail_closed("reconcile-backup-invalid", "unexpected extra member") unless member_map.keys == [proposal_relative_path]
      {
        legacy_record: legacy_record,
        proposal_attempt: derive_attempt_from_legacy_state(state),
      }
    end
  end

  def validate_exact_reconciled_v2_bytes!(current_record, backup_rel, workspace_required:)
    event = parse_reconcile_event_from_v2!(current_record, expected_backup_rel: backup_rel)
    backup_path = canonical_backup_path(backup_rel)
    member_map = read_backup_archive(backup_path)
    archive = validate_reconcile_archive_members!(member_map)
    fail_closed("reconcile-scope-unsupported", "attempt mismatch") unless event[:proposal_attempt] == archive[:proposal_attempt]
    expected_bytes = build_reconciled_v2_bytes(
      legacy_record: archive[:legacy_record],
      proposal_attempt: archive[:proposal_attempt],
      backup_rel: backup_rel,
      event_time_iso: event[:event_time],
    )
    fail_closed("reconcile-scope-unsupported", "proposal bytes differ from exact reconciliation result") unless current_record.source_bytes == expected_bytes
    fail_closed("reconcile-scope-unsupported", "links.adoption_entry changed") unless current_record.dig("links", "adoption_entry") == ""
    topic_confirmation_directory_absent!
    if archive[:proposal_attempt] == 1 && archive[:legacy_record]["risk_tier"] == "T0"
      usage_fail("--workspace is required for legacy T0 PENDING_SHO reconciliation") if workspace_required && inputs[:workspace].empty?
      validate_current_t0_reconciled_state!(
        archive: archive,
        current_record: current_record,
        validate_workspace: workspace_required,
      )
    end
    { event: event, archive: archive }
  end

  def validate_current_t0_reconciled_state!(archive:, current_record:, validate_workspace:)
    fail_closed("legacy-t0-evidence-mismatch") unless expected_t0_artifact_relative_path(current_record) == archive.fetch(:t0_relative_path)
    evidence = OwnerConfirmation.derive_t0_evidence(
      vault_root: vault_root,
      workspace_root: nil,
      record: current_record,
    )
    if validate_workspace
      sealed = OwnerConfirmation.derive_t0_evidence(
        vault_root: vault_root,
        workspace_root: workspace_root,
        record: current_record,
      )
      fail_closed("legacy-t0-evidence-mismatch") unless sealed.fetch("artifact_bytes") == evidence.fetch("artifact_bytes")
    end
    true
  end

  def durable_restore_regular_file!(path, bytes)
    stat = lstat_regular_nonsymlink!(path, "restore-target")
    mode = stat.mode & 0o777
    directory = File.dirname(path)
    temporary = File.join(directory, ".#{File.basename(path)}.restore.#{$$}.#{SecureRandom.hex(8)}")
    begin
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      fail_closed("restore-write-failed", "temporary byte mismatch") unless File.binread(temporary) == bytes.b
      File.rename(temporary, path)
      fsync_directory(directory)
      File.delete(temporary) if path_entry_exists?(temporary)
      fsync_directory(directory)
    ensure
      if path_entry_exists?(temporary)
        File.delete(temporary) rescue nil
        fsync_directory(directory) rescue nil
      end
    end
  end

  def current_t0_artifact_bytes(relative_path)
    path = OwnerConfirmation.canonical_contained_path(
      root: vault_root,
      relative_path: relative_path,
      max_bytes: OwnerConfirmation::MAX_EVIDENCE_BYTES,
      label: "t0-evidence",
    )
    OwnerConfirmation.read_regular_file(path, max_bytes: OwnerConfirmation::MAX_EVIDENCE_BYTES, label: "t0-evidence", utf8: true)
  end

  def migrate_or_reconcile!
    record = proposal_record
    if record.legacy
      migrate_legacy_record!(record)
    elsif record["schema"] == "sgl-proposal/v2"
      validate_exact_reconciled_v2_bytes!(record, parse_reconcile_event_from_v2!(record)[:backup_relative_path], workspace_required: true)
      puts "NO-OP #{topic_key}: exact reconciliation result"
    else
      fail_closed("reconcile-scope-unsupported")
    end
  end

  def migrate_legacy_record!(record)
    require_legacy_record!(record)
    state = classify_legacy_state!(record)
    legacy_migration_guards!(record)

    if state == "PENDING_SHO" && record["risk_tier"] == "T0"
      migrate_legacy_t0_pending_sho!(record)
      return
    end

    ensure_workspace_unused!
    attempt = (state == "PENDING_SHO" ? 1 : 0)
    expected_members = backup_member_map_for_current_legacy(record: record)
    backup_rel = choose_or_create_backup!(expected_members)
    bytes = build_reconciled_v2_bytes(
      legacy_record: record,
      proposal_attempt: attempt,
      backup_rel: backup_rel,
      event_time_iso: sampled_now_iso,
    )
    OwnerConfirmation.atomic_replace_regular_file(record.path, bytes, label: "proposal")
    puts "RECONCILED #{topic_key}: legacy #{state} -> v2"
  end

  def migrate_legacy_t0_pending_sho!(record)
    workspace_root
    expected_legacy_t0 = t0_legacy_artifact_bytes(record.fetch("state_entered_at"))
    sealed = OwnerConfirmation.derive_t0_evidence(
      vault_root: vault_root,
      workspace_root: workspace_root,
      record: record,
    )
    t0_rel = sealed.fetch("artifact_relative_path")
    t0_path = File.join(vault_root, t0_rel)
    current_t0 = current_t0_artifact_bytes(t0_rel)
    if current_t0 == sealed.fetch("artifact_bytes")
      backup_rel = find_crash_recovery_backup!(
        proposal_bytes: record.source_bytes,
        t0_rel: t0_rel,
        expected_legacy_t0: expected_legacy_t0,
      )
      bytes = build_reconciled_v2_bytes(
        legacy_record: record,
        proposal_attempt: 1,
        backup_rel: backup_rel,
        event_time_iso: sampled_now_iso,
      )
      OwnerConfirmation.atomic_replace_regular_file(record.path, bytes, label: "proposal")
      puts "REPAIRED #{topic_key}: completed proposal publish after T0 seal"
      return
    end
    fail_closed("t0-evidence-conflict") unless current_t0 == expected_legacy_t0.b

    expected_members = backup_member_map_for_current_legacy(record: record, t0_legacy_bytes: expected_legacy_t0)
    backup_rel = choose_or_create_backup!(expected_members)
    durable_restore_regular_file!(t0_path, sealed.fetch("artifact_bytes"))
    bytes = build_reconciled_v2_bytes(
      legacy_record: record,
      proposal_attempt: 1,
      backup_rel: backup_rel,
      event_time_iso: sampled_now_iso,
    )
    OwnerConfirmation.atomic_replace_regular_file(record.path, bytes, label: "proposal")
    puts "RECONCILED #{topic_key}: legacy PENDING_SHO T0 -> v2"
  end

  def find_crash_recovery_backup!(proposal_bytes:, t0_rel:, expected_legacy_t0:)
    candidates = scan_existing_backups!
    matches = candidates.select do |path|
      begin
        exact_backup_member_map!(
          path,
          {
            proposal_relative_path => proposal_bytes.b,
            t0_rel => expected_legacy_t0.b,
          },
        )
        true
      rescue OwnerConfirmation::Error
        false
      end
    end
    fail_closed("reconcile-backup-conflict", "expected exactly one crash-recovery backup") unless matches.length == 1
    path_to_relative(matches.first)
  end

  def restore_reconciled_backup!
    archive = validate_reconcile_archive_members!(read_backup_archive(restore_backup_path))
    current = proposal_record
    if archive[:proposal_attempt] == 1 &&
       archive[:legacy_record]["risk_tier"] == "T0" &&
       t0_restore_already_complete?(archive, current)
      puts "RESTORED #{topic_key}: #{restore_backup_relative}"
      return
    end

    if archive[:proposal_attempt] == 1 && archive[:legacy_record]["risk_tier"] == "T0"
      validate_t0_restore_state!(archive, current)
      restore_t0_backup!(archive, current)
    else
      validate_exact_reconciled_v2_bytes!(current, restore_backup_relative, workspace_required: false)
      fail_closed("restore-state-changed") unless current.dig("links", "adoption_entry") == ""
      topic_confirmation_directory_absent!
      durable_restore_regular_file!(current.path, archive[:legacy_record].source_bytes)
    end
    puts "RESTORED #{topic_key}: #{restore_backup_relative}"
  end

  def validate_t0_restore_state!(archive, current_record)
    event = parse_reconcile_event_from_v2!(current_record, expected_backup_rel: restore_backup_relative)
    fail_closed("reconcile-scope-unsupported", "attempt mismatch") unless event[:proposal_attempt] == archive[:proposal_attempt]
    expected_bytes = build_reconciled_v2_bytes(
      legacy_record: archive[:legacy_record],
      proposal_attempt: archive[:proposal_attempt],
      backup_rel: restore_backup_relative,
      event_time_iso: event[:event_time],
    )
    fail_closed("reconcile-scope-unsupported", "proposal bytes differ from exact reconciliation result") unless current_record.source_bytes == expected_bytes
    fail_closed("reconcile-scope-unsupported", "links.adoption_entry changed") unless current_record.dig("links", "adoption_entry") == ""
    topic_confirmation_directory_absent!
  end

  def t0_restore_already_complete?(archive, current_record)
    return false unless current_record.legacy
    return false unless current_record.source_bytes == archive[:legacy_record].source_bytes

    current_t0_artifact_bytes(archive.fetch(:t0_relative_path)) == archive.fetch(:legacy_t0_bytes)
  end

  def restore_t0_backup!(archive, current_record)
    current_t0 = current_t0_artifact_bytes(archive.fetch(:t0_relative_path))
    legacy_t0 = archive.fetch(:legacy_t0_bytes)
    if current_t0 == legacy_t0
      durable_restore_regular_file!(current_record.path, archive[:legacy_record].source_bytes)
      return
    end
    sealed = OwnerConfirmation.derive_t0_evidence(
      vault_root: vault_root,
      workspace_root: nil,
      record: current_record,
    )
    fail_closed("restore-t0-mismatch") unless expected_t0_artifact_relative_path(current_record) == archive.fetch(:t0_relative_path)
    fail_closed("restore-t0-mismatch") unless sealed.fetch("artifact_bytes") == current_t0
    durable_restore_regular_file!(File.join(vault_root, archive.fetch(:t0_relative_path)), legacy_t0)
    durable_restore_regular_file!(current_record.path, archive[:legacy_record].source_bytes)
  end

  def run!
    if restore_mode?
      restore_reconciled_backup!
    else
      migrate_or_reconcile!
    end
  end
end

begin
  ReconcileCLI.run!
rescue ReconcileCLI::UsageError => e
  warn "adopt-reconcile.sh: #{e.message}"
  exit 2
rescue OwnerConfirmation::Error => e
  warn "adopt-reconcile.sh: #{e.message}"
  exit 3
end
RUBY
}

adopt_with_lock "$vault" run_reconcile_locked
