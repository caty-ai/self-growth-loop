#!/usr/bin/env bash
set -u

# shellcheck disable=SC2034 # consumed by sourced helper
ADOPT_TOOL=adopt-confirm.sh
# shellcheck disable=SC1091
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/lib-adopt.sh"

usage() {
  cat >&2 <<'EOF'
Usage: adopt-confirm.sh --vault <root> --topic <key> --decision <GO|REJECT|WATCH> [--backup-ref <value> --effect-metric <value> --report-due <UTC timestamp>] [--reason <text>] [--now <ISO8601Z>]
EOF
}

single_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

print_result() {
  reference=$1
  consume_command=$2
  printf 'Authorization reference: %s\n' "$reference"
  printf 'Consume command: %s\n' "$consume_command"
}

require_tty() {
  ruby -e 'File.open("/dev/tty", "r+") {}' >/dev/null 2>&1 || adopt_fail 'tty-required: controlling terminal is required for interactive confirmation'
}

parse_phase_output() {
  output=$1
  PHASE_STATUS=''
  PHASE_ATTEMPT=''
  PHASE_PROPOSAL_DIGEST=''
  PHASE_SNAPSHOT_B64=''
  PHASE_REFERENCE=''
  while IFS= read -r line; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      status) PHASE_STATUS=$value ;;
      attempt) PHASE_ATTEMPT=$value ;;
      proposal_digest) PHASE_PROPOSAL_DIGEST=$value ;;
      snapshot_b64) PHASE_SNAPSHOT_B64=$value ;;
      reference) PHASE_REFERENCE=$value ;;
    esac
  done <<EOF
$output
EOF
}

build_consume_command() {
  authorization_ref=$1
  case "$decision" in
    GO)
      tool="$repo_root/scripts/adopt-approve.sh"
      printf "%s %s %s %s %s %s %s %s %s %s %s %s %s\n" \
        "$(single_quote "$tool")" \
        "$(single_quote '--vault')" "$(single_quote "$vault")" \
        "$(single_quote '--topic')" "$(single_quote "$topic")" \
        "$(single_quote '--authorization-ref')" "$(single_quote "$authorization_ref")" \
        "$(single_quote '--backup-ref')" "$(single_quote "$backup_ref")" \
        "$(single_quote '--effect-metric')" "$(single_quote "$effect_metric")" \
        "$(single_quote '--report-due')" "$(single_quote "$report_due")"
      ;;
    REJECT)
      tool="$repo_root/scripts/adopt-reject.sh"
      printf "%s %s %s %s %s %s %s %s %s\n" \
        "$(single_quote "$tool")" \
        "$(single_quote '--vault')" "$(single_quote "$vault")" \
        "$(single_quote '--topic')" "$(single_quote "$topic")" \
        "$(single_quote '--authorization-ref')" "$(single_quote "$authorization_ref")" \
        "$(single_quote '--reason')" "$(single_quote "$reason")"
      ;;
    WATCH)
      tool="$repo_root/scripts/adopt-watch.sh"
      printf "%s %s %s %s %s %s %s %s %s\n" \
        "$(single_quote "$tool")" \
        "$(single_quote '--vault')" "$(single_quote "$vault")" \
        "$(single_quote '--topic')" "$(single_quote "$topic")" \
        "$(single_quote '--authorization-ref')" "$(single_quote "$authorization_ref")" \
        "$(single_quote '--reason')" "$(single_quote "$reason")"
      ;;
  esac
}

read_tty_confirmation() {
  snapshot_b64=$1
  prompt_line=$2
  ruby - "$snapshot_b64" "$prompt_line" <<'RUBY'
require "io/wait"

snapshot = ARGV.fetch(0).unpack1("m0")
prompt_line = ARGV.fetch(1)
tty = File.open("/dev/tty", File::RDWR)
saved = `stty -g < /dev/tty`.strip
raise "tty-state-unavailable" if saved.empty?

drain = lambda do
  loop do
    ready = IO.select([tty], nil, nil, 0.01)
    break unless ready
    chunk = tty.read_nonblock(4096, exception: false)
    break if chunk == :wait_readable || chunk.nil?
  end
end

restore = lambda do
  system("stty", saved, in: tty, out: File::NULL, err: File::NULL)
end

Signal.trap("INT") { drain.call; restore.call; exit 130 }
Signal.trap("TERM") { drain.call; restore.call; exit 143 }
Signal.trap("HUP") { drain.call; restore.call; exit 129 }

begin
  tty.write(snapshot)
  tty.write(prompt_line)
  tty.write("\n")
  tty.flush
  system("stty", "-echo", "-icanon", "icrnl", "-igncr", "-inlcr", "min", "1", "time", "0", in: tty, out: File::NULL, err: File::NULL) or raise "tty-mode-failed"
  buffer = +""
  loop do
    byte = tty.read(1)
    if byte.nil?
      drain.call
      restore.call
      warn "confirmation-response-invalid"
      exit 2
    end
    buffer << byte
    break if byte == "\n"
  end
  if IO.select([tty], nil, nil, 0.1)
    extra = tty.read_nonblock(1, exception: false)
    if extra != :wait_readable && !extra.nil?
      drain.call
      restore.call
      warn "confirmation-response-invalid"
      exit 2
    end
  end
  restore.call
  expected = "#{prompt_line}\n"
  unless buffer == expected
    drain.call
    warn "confirmation-response-invalid"
    exit 2
  end
  STDOUT.write(buffer)
ensure
  restore.call rescue nil
end
RUBY
}

run_phase() {
  phase=$1
  expected_snapshot_b64=${2-}
  PHASE_EXPECTED_SNAPSHOT_B64=$expected_snapshot_b64 \
  PHASE_ACTION=$phase \
  PHASE_REPO_ROOT=$repo_root \
  PHASE_VAULT=$vault \
  PHASE_TOPIC=$topic \
  PHASE_DECISION=$decision \
  PHASE_BACKUP_REF=$backup_ref \
  PHASE_EFFECT_METRIC=$effect_metric \
  PHASE_REPORT_DUE=$report_due \
  PHASE_REASON=$reason \
  ruby <<'RUBY'
require "base64"
require "fileutils"
require "securerandom"

repo_root = ENV.fetch("PHASE_REPO_ROOT")
require File.join(repo_root, "scripts/lib-owner-confirmation")

module ConfirmCLI
  module_function

  def inputs
    @inputs ||= {
      vault: ENV.fetch("PHASE_VAULT"),
      topic: ENV.fetch("PHASE_TOPIC"),
      decision: ENV.fetch("PHASE_DECISION"),
      backup_ref: ENV.fetch("PHASE_BACKUP_REF"),
      effect_metric: ENV.fetch("PHASE_EFFECT_METRIC"),
      report_due: ENV.fetch("PHASE_REPORT_DUE"),
      reason: ENV.fetch("PHASE_REASON"),
      expected_snapshot_b64: ENV.fetch("PHASE_EXPECTED_SNAPSHOT_B64", ""),
    }
  end

  def fail_token(code)
    raise OwnerConfirmation::Error, code
  rescue ArgumentError
    raise OwnerConfirmation::Error.new(code)
  end

  def root
    @root ||= OwnerConfirmation.canonicalize_root(inputs[:vault])
  end

  def owner_config
    @owner_config ||= OwnerConfirmation.load_owner_config(vault_root: root)
  end

  def record_path
    File.join(root, "45_ai-systems/self-growth/proposals", "#{inputs[:topic]}.md")
  end

  def record
    @record ||= begin
      loaded = OwnerConfirmation.load_proposal_record(path: record_path)
      OwnerConfirmation.fail_closed("record-damaged", "proposal must be v2") unless loaded["schema"] == "sgl-proposal/v2"
      OwnerConfirmation.fail_closed("record-damaged", "proposal state must be PENDING_SHO") unless loaded["state"] == "PENDING_SHO"
      attempt = loaded["proposal_attempt"]
      OwnerConfirmation.fail_closed("record-damaged", "proposal attempt must be positive") unless attempt.is_a?(Integer) && attempt.positive?
      OwnerConfirmation.fail_closed("record-damaged", "owner_confirmation must be pending") unless loaded["owner_confirmation"] == OwnerConfirmation.pending_owner_confirmation
      loaded
    end
  end

  def attempt
    record.fetch("proposal_attempt")
  end

  def issued_inputs
    values = {
      "backup_ref" => inputs[:backup_ref],
      "effect_metric" => inputs[:effect_metric],
      "report_due" => inputs[:report_due],
      "reason" => inputs[:reason],
    }
    values.delete_if { |_key, value| value.nil? || value.empty? }
    values
  end

  def evidence
    @evidence ||= begin
      if record["risk_tier"] == "T0"
        OwnerConfirmation.derive_t0_evidence(vault_root: root, workspace_root: nil, record: record)
      else
        OwnerConfirmation.derive_council_evidence(vault_root: root, record: record)
      end
    end
  end

  def snapshot
    @snapshot ||= OwnerConfirmation.build_decision_snapshot(
      record: record,
      owner_config: owner_config,
      decision: inputs[:decision],
      issued_inputs: issued_inputs,
      evidence: evidence,
    )
  end

  def proposal_digest
    @proposal_digest ||= "sha256:#{OwnerConfirmation.sha256_hex(snapshot)}"
  end

  def confirmation_rel
    OwnerConfirmation.owner_confirmation_relative_path(topic_key: record["topic_key"], proposal_attempt: attempt)
  end

  def confirmation_abs
    File.join(root, confirmation_rel)
  end

  def confirmation_parent_abs
    File.dirname(confirmation_abs)
  end

  def confirmations_root_abs
    File.join(root, "45_ai-systems/self-growth/confirmations")
  end

  def topic_dir_abs
    File.dirname(confirmation_parent_abs)
  end

  def verify_existing_component!(path)
    stat = File.lstat(path)
    OwnerConfirmation.fail_closed("confirmation-path-invalid", "symlink component") if stat.symlink?
    OwnerConfirmation.fail_closed("confirmation-path-invalid", "directory component required") unless stat.directory?
    real = File.realpath(path)
    prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
    OwnerConfirmation.fail_closed("confirmation-path-invalid", "path escapes root") unless real.start_with?(prefix)
    OwnerConfirmation.fail_closed("confirmation-path-invalid", "noncanonical directory") unless real == path
  rescue Errno::ENOENT, Errno::ENOTDIR
    nil
  end

  def validate_confirmation_namespace!
    [confirmations_root_abs, topic_dir_abs].each do |path|
      next unless File.exist?(path) || File.symlink?(path)
      verify_existing_component!(path)
    end

    if File.exist?(confirmation_parent_abs) || File.symlink?(confirmation_parent_abs)
      stat = File.lstat(confirmation_parent_abs)
      OwnerConfirmation.fail_closed("attempt-namespace-occupied") if stat.symlink? || !stat.directory?
      verify_existing_component!(confirmation_parent_abs)
      entries = Dir.children(confirmation_parent_abs)
      allowed = ["owner-confirmation.txt"]
      unexpected = entries.reject { |entry| allowed.include?(entry) }
      OwnerConfirmation.fail_closed("stale-confirmation-temp") unless unexpected.empty?
      if entries.include?("owner-confirmation.txt")
        artifact_stat = File.lstat(confirmation_abs)
        OwnerConfirmation.fail_closed("authorization-artifact-damaged", "artifact symlink") if artifact_stat.symlink?
        OwnerConfirmation.fail_closed("authorization-artifact-damaged", "artifact must be regular") unless artifact_stat.file?
      end
    end
  end

  def classify_existing_artifact(sample_time:)
    validate_confirmation_namespace!
    begin
      path = OwnerConfirmation.canonical_contained_path(
        root: root,
        relative_path: confirmation_rel,
        max_bytes: OwnerConfirmation::MAX_CONFIRMATION_BYTES,
        label: "authorization-artifact",
      )
    rescue OwnerConfirmation::Error => e
      raise unless e.code == "authorization-artifact-missing"
      return { status: "absent" }
    end

    bytes = OwnerConfirmation.read_regular_file(
      path,
      max_bytes: OwnerConfirmation::MAX_CONFIRMATION_BYTES,
      label: "authorization-artifact",
      utf8: true,
    )
    artifact = OwnerConfirmation.parse_owner_confirmation_artifact(
      bytes,
      topic_key: record["topic_key"],
      proposal_attempt: attempt,
    )
    reference = OwnerConfirmation.build_owner_confirmation_reference(
      topic_key: record["topic_key"],
      proposal_attempt: attempt,
      bytes: bytes,
    )

    same = artifact.fetch("header").fetch("decision") == inputs[:decision] &&
           artifact.fetch("snapshot_bytes") == snapshot
    unless same
      OwnerConfirmation.fail_closed("authorization-artifact-conflict")
    end

    if artifact.fetch("issued_time").to_i <= sample_time.to_i && sample_time.to_i < artifact.fetch("expires_time").to_i
      { status: "unexpired-identical", reference: reference, artifact: artifact }
    else
      { status: "expired-identical", reference: reference, artifact: artifact }
    end
  end

  def build_artifact(issued_at:)
    OwnerConfirmation.build_owner_confirmation_artifact(
      record: record,
      owner_config: owner_config,
      decision: inputs[:decision],
      issued_at: issued_at,
      issued_inputs: issued_inputs,
      evidence: evidence,
    )
  end

  def fsync_directory(path)
    File.open(path, File::RDONLY) { |file| file.fsync }
  rescue SystemCallError => e
    OwnerConfirmation.fail_closed("durability-failed", e.message)
  end

  def ensure_dir!(path, parent:)
    return verify_existing_component!(path) if File.exist?(path) || File.symlink?(path)
    Dir.mkdir(path, 0o700)
    fsync_directory(parent)
    verify_existing_component!(path)
  rescue Errno::EEXIST
    verify_existing_component!(path)
  end

  def prepare_confirmation_directories!
    ensure_dir!(confirmations_root_abs, parent: File.dirname(confirmations_root_abs))
    ensure_dir!(topic_dir_abs, parent: confirmations_root_abs)
    if File.exist?(confirmation_parent_abs) || File.symlink?(confirmation_parent_abs)
      stat = File.lstat(confirmation_parent_abs)
      OwnerConfirmation.fail_closed("attempt-namespace-occupied") if stat.symlink? || !stat.directory?
      verify_existing_component!(confirmation_parent_abs)
    else
      Dir.mkdir(confirmation_parent_abs, 0o700)
      fsync_directory(topic_dir_abs)
      verify_existing_component!(confirmation_parent_abs)
    end
    entries = Dir.children(confirmation_parent_abs)
    unexpected = entries.reject { |entry| entry == "owner-confirmation.txt" }
    OwnerConfirmation.fail_closed("stale-confirmation-temp") unless unexpected.empty?
  rescue Errno::EEXIST
    retry
  end

  def publish_artifact!(bytes, replace:)
    prepare_confirmation_directories!
    nonce = SecureRandom.hex(8)
    temp = File.join(confirmation_parent_abs, ".owner-confirmation.txt.tmp.#{$$}.#{nonce}")
    flags = File::WRONLY | File::CREAT | File::EXCL
    File.open(temp, flags, 0o600) do |file|
      file.write(bytes)
      file.flush
      file.fsync
    end
    temp_bytes = OwnerConfirmation.read_regular_file(temp, max_bytes: bytes.bytesize, label: "authorization-artifact-temp")
    OwnerConfirmation.fail_closed("authorization-artifact-damaged", "temporary byte mismatch") unless temp_bytes == bytes.b
    OwnerConfirmation.parse_owner_confirmation_artifact(bytes, topic_key: record["topic_key"], proposal_attempt: attempt)
    if replace
      File.rename(temp, confirmation_abs)
    else
      File.link(temp, confirmation_abs)
    end
    fsync_directory(confirmation_parent_abs)
  ensure
    if defined?(temp) && temp && (File.exist?(temp) || File.symlink?(temp))
      File.delete(temp) rescue nil
      fsync_directory(confirmation_parent_abs) rescue nil
    end
  end

  def phase_a
    _owner = owner_config
    _record = record
    _evidence = evidence
    classification =
      if File.exist?(confirmation_abs) || File.symlink?(confirmation_abs)
        classify_existing_artifact(sample_time: Time.now.utc)
      else
        validate_confirmation_namespace!
        { status: "absent" }
      end

    result = {
      status: classification[:status],
      attempt: attempt.to_s,
      proposal_digest: proposal_digest,
      snapshot_b64: Base64.strict_encode64(snapshot),
    }
    result[:reference] = classification[:reference] if classification[:reference]
    result
  end

  def phase_b
    expected_snapshot = Base64.strict_decode64(inputs[:expected_snapshot_b64])
    OwnerConfirmation.fail_closed("confirmation-snapshot-drift") unless snapshot == expected_snapshot
    sampled = Time.now.utc
    classification = classify_existing_artifact(sample_time: sampled)
    case classification[:status]
    when "absent"
      replace = false
    when "expired-identical"
      replace = true
    else
      OwnerConfirmation.fail_closed("authorization-artifact-conflict")
    end
    bytes = build_artifact(issued_at: sampled)
    publish_artifact!(bytes, replace: replace)
    {
      status: replace ? "replaced" : "created",
      attempt: attempt.to_s,
      proposal_digest: proposal_digest,
      snapshot_b64: Base64.strict_encode64(snapshot),
      reference: OwnerConfirmation.build_owner_confirmation_reference(
        topic_key: record["topic_key"],
        proposal_attempt: attempt,
        bytes: bytes,
      ),
    }
  end

  def emit(result)
    order = %i[status attempt proposal_digest snapshot_b64 reference]
    order.each do |key|
      next unless result.key?(key)
      puts "#{key}=#{result[key]}"
    end
  end
end

begin
  action = ENV.fetch("PHASE_ACTION")
  result =
    case action
    when "phase-a" then ConfirmCLI.phase_a
    when "phase-b" then ConfirmCLI.phase_b
    else OwnerConfirmation.fail_closed("record-damaged", "unknown phase")
    end
  ConfirmCLI.emit(result)
rescue OwnerConfirmation::Error => e
  warn e.code
  exit 3
end
RUBY
}

repo_root=$(adopt_repo_root) || exit 2
vault=''
topic=''
decision=''
backup_ref=''
effect_metric=''
report_due=''
reason=''

seen_vault=0
seen_topic=0
seen_decision=0
seen_backup_ref=0
seen_effect_metric=0
seen_report_due=0
seen_reason=0
seen_now=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --vault)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_vault" -eq 0 ] || adopt_fail 'duplicate option: --vault'
      seen_vault=1
      vault=$2
      shift 2
      ;;
    --topic)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_topic" -eq 0 ] || adopt_fail 'duplicate option: --topic'
      seen_topic=1
      topic=$2
      shift 2
      ;;
    --decision)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_decision" -eq 0 ] || adopt_fail 'duplicate option: --decision'
      seen_decision=1
      decision=$2
      shift 2
      ;;
    --backup-ref)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_backup_ref" -eq 0 ] || adopt_fail 'duplicate option: --backup-ref'
      seen_backup_ref=1
      backup_ref=$2
      shift 2
      ;;
    --effect-metric)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_effect_metric" -eq 0 ] || adopt_fail 'duplicate option: --effect-metric'
      seen_effect_metric=1
      effect_metric=$2
      shift 2
      ;;
    --report-due)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_report_due" -eq 0 ] || adopt_fail 'duplicate option: --report-due'
      seen_report_due=1
      report_due=$2
      shift 2
      ;;
    --reason)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_reason" -eq 0 ] || adopt_fail 'duplicate option: --reason'
      seen_reason=1
      reason=$2
      shift 2
      ;;
    --now)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      [ "$seen_now" -eq 0 ] || adopt_fail 'duplicate option: --now'
      seen_now=1
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      adopt_fail "unknown option: $1"
      ;;
  esac
done

[ -n "$vault" ] && [ -n "$topic" ] && [ -n "$decision" ] || { usage; exit 2; }
adopt_validate_topic "$topic"

case "$decision" in
  GO)
    [ -n "$backup_ref" ] && [ -n "$effect_metric" ] && [ -n "$report_due" ] || { usage; exit 2; }
    [ "$seen_reason" -eq 0 ] || adopt_fail '--reason is irrelevant to GO'
    ;;
  REJECT|WATCH)
    [ -n "$reason" ] || { usage; exit 2; }
    [ "$seen_backup_ref" -eq 0 ] || adopt_fail '--backup-ref is irrelevant to non-GO decisions'
    [ "$seen_effect_metric" -eq 0 ] || adopt_fail '--effect-metric is irrelevant to non-GO decisions'
    [ "$seen_report_due" -eq 0 ] || adopt_fail '--report-due is irrelevant to non-GO decisions'
    ;;
  *)
    adopt_fail "invalid decision: $decision"
    ;;
esac

phase_a_worker() { run_phase phase-a; }
phase_a_output=$(adopt_with_lock "$vault" phase_a_worker) || exit $?
parse_phase_output "$phase_a_output"
[ -n "$PHASE_STATUS" ] || adopt_policy_fail 'record-damaged'

consume_command=''
if [ -n "$PHASE_REFERENCE" ]; then
  consume_command=$(build_consume_command "$PHASE_REFERENCE")
fi

case "$PHASE_STATUS" in
  unexpired-identical)
    print_result "$PHASE_REFERENCE" "$consume_command"
    exit 0
    ;;
  absent|expired-identical)
    require_tty
    :
    ;;
  *)
    adopt_policy_fail "$PHASE_STATUS"
    ;;
esac

digest_short=$(printf '%s' "$PHASE_PROPOSAL_DIGEST" | sed -E 's/^sha256:([0-9a-f]{12}).*/\1/')
confirm_line="CONFIRM $decision $topic $PHASE_ATTEMPT $digest_short"
read_tty_confirmation "$PHASE_SNAPSHOT_B64" "$confirm_line" >/dev/null || {
  status=$?
  [ "$status" -eq 2 ] && adopt_fail 'confirmation-response-invalid'
  exit "$status"
}

phase_b_worker() { run_phase phase-b "$PHASE_SNAPSHOT_B64"; }
phase_b_output=$(adopt_with_lock "$vault" phase_b_worker) || exit $?
parse_phase_output "$phase_b_output"
[ -n "$PHASE_REFERENCE" ] || adopt_policy_fail 'authorization-artifact-missing'
consume_command=$(build_consume_command "$PHASE_REFERENCE")
print_result "$PHASE_REFERENCE" "$consume_command"
