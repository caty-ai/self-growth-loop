require "digest"
require "date"
require "fileutils"
require "pathname"
require "securerandom"
require "socket"
require "time"
require "yaml"

module OwnerConfirmation
  OWNER_CONFIG_RELATIVE_PATH = "45_ai-systems/self-growth/config/owner.yaml".freeze
  PROPOSAL_KEYS = %w[
    schema topic_key title state state_entered_at risk_tier
    identity_critical tiebreak proposer executor_agent executor_model
    created updated cooldown_until retry_count proposal_attempt
    owner_confirmation source_items links backup_ref effect_metric
    report_due reversibility
  ].freeze
  LEGACY_PROPOSAL_KEYS = (PROPOSAL_KEYS - %w[schema proposal_attempt owner_confirmation]).freeze
  CONFIRMATION_KEYS = %w[
    status assurance reference proposal_digest decision principal verified_at
  ].freeze
  BUNDLE_FILES = %w[
    attempts.md config-diff.txt cost.txt env-manifest.txt permissions.md
    repro.md rollback-test.md run.log
  ].freeze
  SNAPSHOT_KEYS = %w[
    repository-id principal assurance topic-key proposal-attempt title-sha256
    judgement-sha256 risk-tier identity-critical reversibility-sha256
    trial-reference trial-evidence-sha256 manifest-reference
    manifest-evidence-sha256 council-reference council-evidence-sha256
    decision backup-reference-sha256 effect-metric-sha256 report-due
    reason-sha256
  ].freeze
  TOPIC_RE = /\A[a-z0-9]+(?:-[a-z0-9]+)*__[a-z0-9]+(?:-[a-z0-9]+)*(?:__v[0-9]+)?\z/.freeze
  SHA256_RE = /\A[0-9a-f]{64}\z/.freeze
  DIGEST_RE = /\Asha256:[0-9a-f]{64}\z/.freeze
  POSITIVE_INTEGER_RE = /\A[1-9][0-9]*\z/.freeze
  TIMESTAMP_RE = /\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-5][0-9])Z\z/.freeze
  CONFIRMATION_SENTENCE = "I explicitly approve this exact disposition".freeze
  T0_MARKER = "auto-adopt path (T0), council skipped".freeze
  MAX_PROPOSAL_BYTES = 1_048_576
  MAX_EVIDENCE_BYTES = 1_048_576
  MAX_CONFIRMATION_BYTES = 65_536
  MAX_OWNER_CONFIG_BYTES = 32_768

  STATE_CONFIRMATION_FORMS = {
    "PROPOSED" => %w[pending verified],
    "TRIALING" => %w[pending verified],
    "COUNCIL" => %w[pending verified],
    "PENDING_OWNER" => %w[pending],
    "ADOPTING" => %w[verified],
    "ADOPTED" => %w[verified],
    "WATCH" => %w[verified],
    "EXPIRED" => %w[pending],
    "DLQ" => %w[pending verified],
    "REJECTED" => %w[pending verified],
  }.freeze

  class Error < StandardError
    attr_reader :code

    def initialize(code, detail = nil)
      @code = code.to_s
      super(detail.nil? || detail.empty? ? @code : "#{@code}: #{detail}")
    end
  end

  class ProposalRecord < Hash
    attr_accessor :source_bytes, :frontmatter_bytes, :body_bytes,
                  :judgement_bytes, :path, :legacy

    def initialize(values = {})
      super()
      update(values)
    end
  end

  module_function

  def fail_closed(code, detail = nil)
    raise Error.new(code, detail)
  end

  def actual_string!(value, label, min_bytes: nil, max_bytes: nil, ascii: false, control_free: false)
    fail_closed("record-damaged", "#{label} must be a string") unless value.is_a?(String)
    bytes = value.b
    utf8 = value.dup.force_encoding(Encoding::UTF_8)
    fail_closed("record-damaged", "#{label} is not valid UTF-8") unless utf8.valid_encoding?
    fail_closed("record-damaged", "#{label} must be ASCII") if ascii && !value.ascii_only?
    fail_closed("record-damaged", "#{label} contains an ASCII control byte") if control_free && bytes.match?(/[\x00-\x1f\x7f]/n)
    fail_closed("record-damaged", "#{label} is too short") if min_bytes && bytes.bytesize < min_bytes
    fail_closed("record-damaged", "#{label} is too long") if max_bytes && bytes.bytesize > max_bytes
    value
  end

  def validate_topic_key!(topic)
    actual_string!(topic, "topic_key", min_bytes: 1, max_bytes: 62, ascii: true)
    fail_closed("record-damaged", "invalid topic_key") unless TOPIC_RE.match?(topic)
    topic
  end

  def load_owner_config(vault_root:)
    root = canonicalize_root(vault_root)
    path = canonical_contained_path(
      root: root,
      relative_path: OWNER_CONFIG_RELATIVE_PATH,
      max_bytes: MAX_OWNER_CONFIG_BYTES,
      label: "owner-config",
    )
    bytes = read_regular_file(path, max_bytes: MAX_OWNER_CONFIG_BYTES, label: "owner-config", utf8: true)
    lines = bytes.lines
    expected_keys = %w[schema principal repository_id default_assurance]
    unless lines.length == 4 && lines.all? { |line| line.end_with?("\n") } && lines.join == bytes
      fail_closed("owner-config-format-invalid", "expected exactly four LF-terminated lines")
    end
    fail_closed("owner-config-format-invalid", "CRLF/control byte rejected") if bytes.match?(/[\x00-\x09\x0b-\x1f\x7f]/n)
    values = {}
    lines.each_with_index do |line, index|
      prefix = "#{expected_keys[index]}: "
      fail_closed("owner-config-format-invalid", "line #{index + 1}") unless line.start_with?(prefix)
      value = line.byteslice(prefix.bytesize, line.bytesize - prefix.bytesize - 1)
      fail_closed("owner-config-format-invalid", "line #{index + 1}") if value.nil? || value.empty?
      values[expected_keys[index]] = value.force_encoding(Encoding::UTF_8)
    end
    fail_closed("owner-config-schema-unsupported") unless values["schema"] == "sgl-owner-config/v1"
    principal = values["principal"]
    repository_id = values["repository_id"]
    assurance = values["default_assurance"]
    unless principal.ascii_only? && principal.bytesize.between?(1, 64) && /\A[a-z0-9_-]+\z/.match?(principal)
      fail_closed("owner-config-principal-invalid")
    end
    unless repository_id.ascii_only? && repository_id.bytesize.between?(3, 255) &&
           /\A[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\z/.match?(repository_id)
      fail_closed("owner-config-repository-id-invalid")
    end
    unless assurance.ascii_only? && assurance.bytesize.between?(1, 16) && /\A[a-z]+\z/.match?(assurance)
      fail_closed("owner-config-assurance-invalid")
    end
    fail_closed("unimplemented-assurance") unless assurance == "standard"
    values.freeze
  end

  def load_proposal_record(path:)
    absolute = File.expand_path(path)
    parent = canonicalize_root(File.dirname(absolute))
    basename = File.basename(absolute)
    fail_closed("record-damaged", "proposal basename is invalid") if basename == "." || basename == ".."
    canonical = canonical_contained_path(
      root: parent,
      relative_path: basename,
      max_bytes: MAX_PROPOSAL_BYTES,
      label: "proposal",
    )
    bytes = read_regular_file(canonical, max_bytes: MAX_PROPOSAL_BYTES, label: "proposal", utf8: true)
    parse_proposal_bytes(bytes, path: canonical)
  end

  def normalize_state_on_read!(values)
    # legacy-read: PENDING_SHO accepted until v1.0 (issue #10)
    values["state"] = "PENDING_OWNER" if values["state"] == "PENDING_SHO"
    values
  end

  def parse_proposal_bytes(bytes, path: nil)
    text = valid_utf8_bytes!(bytes, "record-damaged", "proposal")
    fail_closed("record-damaged", "frontmatter must begin at byte zero") unless text.start_with?("---\n")
    closing_start = exact_line_offset(text, "---\n", start_offset: 4)
    fail_closed("record-damaged", "frontmatter terminator missing") unless closing_start
    closing_end = closing_start + 4
    frontmatter = text.byteslice(0, closing_end)
    body = text.byteslice(closing_end, text.bytesize - closing_end) || "".b
    yaml_frontmatter = markdown_frontmatter_as_yaml(frontmatter)
    reject_yaml_duplicates!(yaml_frontmatter, "proposal")
    values = safe_yaml_load(yaml_frontmatter, "proposal")
    fail_closed("record-damaged", "proposal frontmatter is not a mapping") unless values.is_a?(Hash)
    normalize_state_on_read!(values)

    legacy = values.keys == LEGACY_PROPOSAL_KEYS
    unless legacy || values.keys == PROPOSAL_KEYS
      fail_closed("record-damaged", "proposal top-level keys/order do not match a closed schema")
    end
    if legacy
      fail_closed("record-damaged", "legacy proposal unexpectedly carries schema") if values.key?("schema")
    else
      fail_closed("record-damaged", "proposal schema mismatch") unless values["schema"] == "sgl-proposal/v2"
      validate_v2_record!(values, frontmatter)
    end
    validate_topic_key!(values["topic_key"])
    actual_string!(values["title"], "title", min_bytes: 1, control_free: true)
    actual_string!(values["risk_tier"], "risk_tier", ascii: true)
    fail_closed("record-damaged", "risk_tier must be T0, T1, or T2") unless %w[T0 T1 T2].include?(values["risk_tier"])
    fail_closed("record-damaged", "identity_critical must be boolean") unless values["identity_critical"] == true || values["identity_critical"] == false
    actual_string!(values["reversibility"], "reversibility", min_bytes: 1, control_free: true)
    fail_closed("record-damaged", "links must be a mapping") unless values["links"].is_a?(Hash)
    actual_string!(values["links"]["trial_bundle"], "links.trial_bundle", ascii: true)

    judgement = extract_judgement_span(body)
    record = ProposalRecord.new(values)
    record.source_bytes = text.b
    record.frontmatter_bytes = frontmatter.b
    record.body_bytes = body.b
    record.judgement_bytes = judgement.b
    record.path = path
    record.legacy = legacy
    record
  end

  def validate_v2_record!(values, frontmatter = nil)
    attempt = values["proposal_attempt"]
    fail_closed("record-damaged", "proposal_attempt must be an integer") unless attempt.is_a?(Integer) && attempt >= 0
    if frontmatter
      top_lines = frontmatter.lines.select do |line|
        PROPOSAL_KEYS.any? { |key| line.start_with?("#{key}:") }
      end
      fail_closed("record-damaged", "top-level physical key order mismatch") unless top_lines.length == PROPOSAL_KEYS.length
      found_names = top_lines.map { |line| line.byteslice(0, line.b.index(":".b)) }
      fail_closed("record-damaged", "top-level physical key order mismatch") unless found_names == PROPOSAL_KEYS
      identity_line = top_lines[6]
      fail_closed("record-damaged", "identity_critical token is not canonical") unless /\Aidentity_critical: (?:true|false)\n\z/.match?(identity_line)
      loaded_identity = identity_line == "identity_critical: true\n"
      fail_closed("record-damaged", "identity_critical token disagrees with YAML value") unless loaded_identity == values["identity_critical"]
      attempt_line = top_lines[15]
      fail_closed("record-damaged", "proposal_attempt token is not canonical") unless /\Aproposal_attempt: (?:0|[1-9][0-9]*)\n\z/.match?(attempt_line)
      fail_closed("record-damaged", "proposal_attempt token disagrees with YAML value") unless attempt_line == "proposal_attempt: #{attempt}\n"
    end
    confirmation = validate_owner_confirmation!(values["owner_confirmation"], topic_key: values["topic_key"], proposal_attempt: attempt)
    if frontmatter
      expected_block = owner_confirmation_yaml_block(confirmation)
      marker = "owner_confirmation:\n"
      start = frontmatter.b.index(marker.b)
      fail_closed("record-damaged", "owner_confirmation physical block missing") unless start
      actual = frontmatter.byteslice(start, expected_block.bytesize)
      fail_closed("record-damaged", "owner_confirmation physical block is noncanonical") unless actual == expected_block
      next_byte = frontmatter.getbyte(start + expected_block.bytesize)
      fail_closed("record-damaged", "owner_confirmation has extra physical content") if next_byte == 0x20
    end
    state = values["state"]
    actual_string!(state, "state", ascii: true)
    allowed = STATE_CONFIRMATION_FORMS[state]
    fail_closed("record-damaged", "unknown v2 state") unless allowed
    fail_closed("record-damaged", "state/owner_confirmation form mismatch") unless allowed.include?(confirmation["status"])
    values
  end

  def validate_owner_confirmation!(confirmation, topic_key:, proposal_attempt:)
    fail_closed("record-damaged", "owner_confirmation must be a mapping") unless confirmation.is_a?(Hash)
    fail_closed("record-damaged", "owner_confirmation keys/order mismatch") unless confirmation.keys == CONFIRMATION_KEYS
    confirmation.each { |key, value| actual_string!(value, "owner_confirmation.#{key}") }
    fail_closed("record-damaged", "owner_confirmation assurance mismatch") unless confirmation["assurance"] == "standard"
    case confirmation["status"]
    when "pending"
      fail_closed("record-damaged", "pending owner_confirmation is mixed") unless confirmation == pending_owner_confirmation
    when "verified"
      fail_closed("record-damaged", "verified proposal attempt must be positive") unless proposal_attempt.is_a?(Integer) && proposal_attempt.positive?
      parse_owner_confirmation_reference(
        confirmation["reference"],
        topic_key: topic_key,
        proposal_attempt: proposal_attempt,
      )
      fail_closed("record-damaged", "invalid proposal_digest") unless DIGEST_RE.match?(confirmation["proposal_digest"])
      fail_closed("record-damaged", "invalid decision") unless %w[GO REJECT WATCH].include?(confirmation["decision"])
      fail_closed("record-damaged", "invalid principal") unless /\A[a-z0-9_-]{1,64}\z/.match?(confirmation["principal"])
      parse_utc_timestamp(confirmation["verified_at"])
    else
      fail_closed("record-damaged", "invalid owner_confirmation status")
    end
    confirmation
  end

  def pending_owner_confirmation
    {
      "status" => "pending",
      "assurance" => "standard",
      "reference" => "",
      "proposal_digest" => "",
      "decision" => "",
      "principal" => "",
      "verified_at" => "",
    }
  end

  def verified_owner_confirmation(reference:, proposal_digest:, decision:, principal:, verified_at:)
    confirmation = {
      "status" => "verified",
      "assurance" => "standard",
      "reference" => reference,
      "proposal_digest" => proposal_digest,
      "decision" => decision,
      "principal" => principal,
      "verified_at" => verified_at,
    }
    parsed_reference = parse_owner_confirmation_reference(reference)
    validate_owner_confirmation!(
      confirmation,
      topic_key: parsed_reference["topic_key"],
      proposal_attempt: parsed_reference["proposal_attempt"],
    )
    confirmation
  end

  def build_next_proposal_v2(record:, expected_state: nil)
    fail_closed("record-damaged", "record must be a mapping") unless record.is_a?(Hash)
    fail_closed("record-damaged", "expected_state is required for a fresh attempt") if expected_state.nil?
    fail_closed("record-damaged", "PENDING_OWNER repair must preserve its attempt") if expected_state == "PENDING_OWNER"
    fail_closed("record-damaged", "fresh confirmation attempt expected #{expected_state}") unless record["state"] == expected_state
    previous_attempt =
      if record["schema"] == "sgl-proposal/v2"
        value = record["proposal_attempt"]
        fail_closed("record-damaged", "proposal_attempt must be a nonnegative integer") unless value.is_a?(Integer) && value >= 0
        value
      elsif record.keys == LEGACY_PROPOSAL_KEYS || (record.respond_to?(:legacy) && record.legacy)
        0
      else
        fail_closed("record-damaged", "record is neither closed legacy nor proposal v2")
      end
    next_attempt = previous_attempt + 1
    values = {}
    PROPOSAL_KEYS.each do |key|
      values[key] =
        case key
        when "schema" then "sgl-proposal/v2"
        when "state" then "PENDING_OWNER"
        when "proposal_attempt" then next_attempt
        when "owner_confirmation" then pending_owner_confirmation
        else deep_copy(record.fetch(key))
        end
    end
    result = ProposalRecord.new(values)
    if record.is_a?(ProposalRecord)
      result.source_bytes = record.source_bytes
      result.frontmatter_bytes = record.frontmatter_bytes
      result.body_bytes = record.body_bytes
      result.judgement_bytes = record.judgement_bytes
      result.path = record.path
    end
    result.legacy = false
    result
  end

  def validate_and_rewrite_proposal_v2!(record:, path: nil)
    fail_closed("record-damaged", "record must be a mapping") unless record.is_a?(Hash)
    fail_closed("record-damaged", "proposal top-level keys/order mismatch") unless record.keys == PROPOSAL_KEYS
    validate_v2_record!(record)
    body =
      if record.respond_to?(:body_bytes) && !record.body_bytes.nil?
        record.body_bytes
      elsif record.respond_to?(:source_bytes) && record.source_bytes
        parsed = parse_proposal_bytes(record.source_bytes)
        parsed.body_bytes
      else
        ""
      end
    ordered = {}
    PROPOSAL_KEYS.each { |key| ordered[key] = deep_copy(record.fetch(key)) }
    dumped = YAML.dump(ordered)
    dumped = valid_utf8_bytes!(dumped, "record-damaged", "serialized proposal")
    owner_start = dumped.b.index("owner_confirmation:\n".b)
    source_start = exact_line_offset(dumped, "source_items:", start_offset: owner_start || 0)
    fail_closed("record-damaged", "cannot serialize owner_confirmation") unless owner_start && source_start && source_start > owner_start
    frontmatter = dumped.byteslice(0, owner_start) +
                  owner_confirmation_yaml_block(record["owner_confirmation"]) +
                  dumped.byteslice(source_start, dumped.bytesize - source_start)
    bytes = frontmatter.b + "---\n".b + body.b
    parsed = parse_proposal_bytes(bytes)
    fail_closed("record-damaged", "proposal rewrite postcondition mismatch") unless proposal_semantically_equal?(parsed, record)

    destination = path || (record.path if record.respond_to?(:path))
    atomic_replace_regular_file(destination, bytes, label: "proposal") if destination
    bytes
  end

  def owner_confirmation_yaml_block(confirmation)
    validate_owner_confirmation_shape_for_emission!(confirmation)
    if confirmation["status"] == "pending"
      <<~YAML
        owner_confirmation:
          status: pending
          assurance: standard
          reference: ""
          proposal_digest: ""
          decision: ""
          principal: ""
          verified_at: ""
      YAML
    else
      <<~YAML
        owner_confirmation:
          status: verified
          assurance: standard
          reference: #{confirmation.fetch("reference")}
          proposal_digest: #{confirmation.fetch("proposal_digest")}
          decision: #{confirmation.fetch("decision")}
          principal: #{confirmation.fetch("principal")}
          verified_at: "#{confirmation.fetch("verified_at")}"
      YAML
    end
  end

  def validate_owner_confirmation_shape_for_emission!(confirmation)
    fail_closed("record-damaged", "owner_confirmation must be a mapping") unless confirmation.is_a?(Hash)
    fail_closed("record-damaged", "owner_confirmation keys/order mismatch") unless confirmation.keys == CONFIRMATION_KEYS
    confirmation.each do |key, value|
      actual_string!(value, "owner_confirmation.#{key}", control_free: true)
    end
    if confirmation["status"] == "pending"
      fail_closed("record-damaged", "pending owner_confirmation is mixed") unless confirmation == pending_owner_confirmation
    else
      fail_closed("record-damaged", "invalid owner_confirmation status") unless confirmation["status"] == "verified"
      fail_closed("record-damaged", "invalid owner confirmation reference") unless /\A45_ai-systems\/self-growth\/confirmations\/[a-z0-9_-]+(?:__[a-z0-9_-]+)*\/[1-9][0-9]*\/owner-confirmation\.txt#sha256:[0-9a-f]{64}\z/.match?(confirmation["reference"])
      fail_closed("record-damaged", "invalid proposal digest") unless DIGEST_RE.match?(confirmation["proposal_digest"])
      fail_closed("record-damaged", "invalid decision") unless %w[GO REJECT WATCH].include?(confirmation["decision"])
      fail_closed("record-damaged", "invalid principal") unless /\A[a-z0-9_-]{1,64}\z/.match?(confirmation["principal"])
      parse_utc_timestamp(confirmation["verified_at"])
    end
    confirmation
  end

  def build_decision_snapshot(record:, owner_config:, decision:, issued_inputs:, evidence:)
    validate_owner_config_mapping!(owner_config)
    fail_closed("record-damaged", "proposal must be v2") unless record.is_a?(Hash) && record["schema"] == "sgl-proposal/v2"
    topic = validate_topic_key!(record["topic_key"])
    attempt = record["proposal_attempt"]
    fail_closed("record-damaged", "proposal attempt must be positive") unless attempt.is_a?(Integer) && attempt.positive?
    fail_closed("record-damaged", "decision must be GO, REJECT, or WATCH") unless %w[GO REJECT WATCH].include?(decision)
    title = actual_string!(record["title"], "title", min_bytes: 1, control_free: true)
    reversibility = actual_string!(record["reversibility"], "reversibility", min_bytes: 1, control_free: true)
    risk_tier = record["risk_tier"]
    fail_closed("record-damaged", "invalid risk_tier") unless %w[T0 T1 T2].include?(risk_tier)
    identity = record["identity_critical"]
    fail_closed("record-damaged", "identity_critical must be boolean") unless identity == true || identity == false
    validate_t0_eligibility!(record) if risk_tier == "T0"
    judgement =
      if record.respond_to?(:judgement_bytes) && record.judgement_bytes
        record.judgement_bytes
      elsif record.key?("__judgement_bytes")
        record["__judgement_bytes"]
      end
    fail_closed("record-damaged", "Judgement bytes unavailable; load the proposal through load_proposal_record") unless judgement.is_a?(String)
    fail_closed("record-damaged", "Judgement is empty") unless judgement.b.match?(/[^\x09\x0a\x0c\x0d\x20]/n)
    proposal_trial_reference = validate_trial_reference!(record.dig("links", "trial_bundle"), topic)
    trial_reference = validate_trial_reference!(evidence_value(evidence, "trial_reference"), topic)
    fail_closed("evidence-damaged", "trial reference differs from proposal") unless trial_reference == proposal_trial_reference

    rollout = decision_snapshot_rollout_fields(decision, issued_inputs)
    fields = {
      "repository-id" => owner_config.fetch("repository_id"),
      "principal" => owner_config.fetch("principal"),
      "assurance" => owner_config.fetch("default_assurance"),
      "topic-key" => topic,
      "proposal-attempt" => attempt.to_s,
      "title-sha256" => sha256_hex(title.b),
      "judgement-sha256" => sha256_hex(judgement.b),
      "risk-tier" => risk_tier,
      "identity-critical" => identity ? "true" : "false",
      "reversibility-sha256" => sha256_hex(reversibility.b),
      "trial-reference" => trial_reference,
      "trial-evidence-sha256" => evidence_digest!(evidence, "trial_evidence_sha256"),
      "manifest-reference" => evidence_reference!(evidence, "manifest_reference"),
      "manifest-evidence-sha256" => evidence_digest_or_none!(evidence, "manifest_evidence_sha256"),
      "council-reference" => evidence_reference!(evidence, "council_reference"),
      "council-evidence-sha256" => evidence_digest_or_none!(evidence, "council_evidence_sha256"),
      "decision" => decision,
      "backup-reference-sha256" => rollout.fetch("backup-reference-sha256"),
      "effect-metric-sha256" => rollout.fetch("effect-metric-sha256"),
      "report-due" => rollout.fetch("report-due"),
      "reason-sha256" => rollout.fetch("reason-sha256"),
    }
    validate_snapshot_evidence_pairing!(fields, task_id_from_trial_reference(trial_reference), risk_tier)
    serialize_labeled_block("sgl-decision-snapshot/v1", fields)
  end

  def build_owner_confirmation_artifact(record:, owner_config:, decision:, issued_at:, issued_inputs:, evidence:)
    snapshot = build_decision_snapshot(
      record: record,
      owner_config: owner_config,
      decision: decision,
      issued_inputs: issued_inputs,
      evidence: evidence,
    )
    issued_time =
      if issued_at.is_a?(Time)
        Time.at(issued_at.to_i).utc
      else
        parse_utc_timestamp(issued_at)
      end
    issued = utc_timestamp(issued_time)
    begin
      expires_time = Time.at(issued_time.to_i + 86_400).utc
      fail_closed("confirmation-window-overflow") unless expires_time.year.between?(1, 9999)
    rescue RangeError, ArgumentError
      fail_closed("confirmation-window-overflow")
    end
    expires = utc_timestamp(expires_time)
    snapshot_fields = parse_decision_snapshot(snapshot)
    if decision == "GO"
      due = parse_utc_timestamp(snapshot_fields.fetch("report-due"))
      fail_closed("report-due-not-after-confirmation-window") unless due.to_i > expires_time.to_i
    end
    digest = "sha256:#{sha256_hex(snapshot)}"
    fields = {
      "assurance" => owner_config.fetch("default_assurance"),
      "principal" => owner_config.fetch("principal"),
      "repository-id" => owner_config.fetch("repository_id"),
      "decision" => decision,
      "topic-key" => record.fetch("topic_key"),
      "proposal-attempt" => record.fetch("proposal_attempt").to_s,
      "proposal-digest" => digest,
      "issued-at" => issued,
      "expires-at" => expires,
      "confirmation" => CONFIRMATION_SENTENCE,
    }
    header = serialize_labeled_block("sgl-owner-confirmation/v1", fields)
    header + "\n" + snapshot
  end

  def parse_owner_confirmation_artifact(bytes, topic_key:, proposal_attempt:)
    text = valid_utf8_bytes!(bytes, "authorization-artifact-damaged", "owner confirmation")
    fail_closed("authorization-artifact-damaged", "artifact exceeds 64 KiB") if text.bytesize > MAX_CONFIRMATION_BYTES
    separator = "\nsgl-decision-snapshot/v1\n"
    binary_text = text.b
    binary_separator = separator.b
    first = binary_text.index(binary_separator)
    fail_closed("authorization-artifact-damaged", "snapshot separator missing") unless first
    fail_closed("authorization-artifact-damaged", "snapshot separator duplicated") if binary_text.index(binary_separator, first + 1)
    header_bytes = text.byteslice(0, first)
    snapshot_bytes = text.byteslice(first + 1, text.bytesize - first - 1)
    header = parse_labeled_block(
      header_bytes,
      "sgl-owner-confirmation/v1",
      %w[
        assurance principal repository-id decision topic-key proposal-attempt
        proposal-digest issued-at expires-at confirmation
      ],
      "authorization-artifact-damaged",
    )
    snapshot = parse_decision_snapshot(snapshot_bytes)
    topic = validate_topic_key!(topic_key)
    attempt_string = proposal_attempt.to_s
    fail_closed("authorization-artifact-damaged", "proposal attempt is not positive") unless POSITIVE_INTEGER_RE.match?(attempt_string)
    fail_closed("authorization-artifact-damaged", "topic mismatch") unless header["topic-key"] == topic && snapshot["topic-key"] == topic
    unless header["proposal-attempt"] == attempt_string && snapshot["proposal-attempt"] == attempt_string
      fail_closed("authorization-artifact-damaged", "attempt mismatch")
    end
    %w[decision principal repository-id assurance].each do |key|
      fail_closed("authorization-artifact-damaged", "#{key} header/snapshot mismatch") unless header[key] == snapshot[key]
    end
    fail_closed("authorization-artifact-damaged", "confirmation sentence mismatch") unless header["confirmation"] == CONFIRMATION_SENTENCE
    fail_closed("authorization-artifact-damaged", "invalid decision") unless %w[GO REJECT WATCH].include?(header["decision"])
    expected_digest = "sha256:#{sha256_hex(snapshot_bytes)}"
    fail_closed("authorization-artifact-damaged", "snapshot digest mismatch") unless header["proposal-digest"] == expected_digest
    issued = parse_utc_timestamp(header["issued-at"])
    expires = parse_utc_timestamp(header["expires-at"])
    begin
      expected_expires = Time.at(issued.to_i + 86_400).utc
    rescue RangeError, ArgumentError
      fail_closed("authorization-artifact-damaged", "confirmation window overflow")
    end
    fail_closed("authorization-artifact-damaged", "confirmation window mismatch") unless expires.to_i == expected_expires.to_i
    if header["decision"] == "GO"
      due = parse_utc_timestamp(snapshot["report-due"])
      fail_closed("authorization-artifact-damaged", "report due is not after expiry") unless due.to_i > expires.to_i
    end
    {
      "header" => header,
      "snapshot" => snapshot,
      "snapshot_bytes" => snapshot_bytes.b,
      "artifact_bytes" => text.b,
      "artifact_sha256" => sha256_hex(text.b),
      "issued_time" => issued,
      "expires_time" => expires,
    }
  end

  def verify_owner_confirmation_reference(reference, vault_root:, topic_key:, proposal_attempt:, now: Time.now)
    parsed_reference = parse_owner_confirmation_reference(
      reference,
      topic_key: topic_key,
      proposal_attempt: proposal_attempt,
    )
    root = canonicalize_root(vault_root)
    path = canonical_contained_path(
      root: root,
      relative_path: parsed_reference.fetch("path"),
      max_bytes: MAX_CONFIRMATION_BYTES,
      label: "authorization-artifact",
    )
    bytes = read_regular_file(path, max_bytes: MAX_CONFIRMATION_BYTES, label: "authorization-artifact", utf8: true)
    fail_closed("authorization-reference-stale") unless sha256_hex(bytes) == parsed_reference.fetch("sha256")
    artifact = parse_owner_confirmation_artifact(
      bytes,
      topic_key: topic_key,
      proposal_attempt: proposal_attempt,
    )
    owner = load_owner_config(vault_root: root)
    header = artifact.fetch("header")
    unless header["principal"] == owner["principal"] &&
           header["repository-id"] == owner["repository_id"] &&
           header["assurance"] == owner["default_assurance"]
      fail_closed("authorization-artifact-damaged", "owner config correlation mismatch")
    end
    sample = now.is_a?(Time) ? Time.at(now.to_i).utc : parse_utc_timestamp(now)
    unless artifact["issued_time"].to_i <= sample.to_i && sample.to_i < artifact["expires_time"].to_i
      fail_closed("authorization-artifact-expired")
    end
    artifact.merge(
      "reference" => reference,
      "path" => path,
      "owner_config" => owner,
    )
  end

  def owner_confirmation_relative_path(topic_key:, proposal_attempt:)
    topic = validate_topic_key!(topic_key)
    attempt = proposal_attempt.to_s
    fail_closed("record-damaged", "proposal attempt must be positive") unless POSITIVE_INTEGER_RE.match?(attempt)
    "45_ai-systems/self-growth/confirmations/#{topic}/#{attempt}/owner-confirmation.txt"
  end

  def build_owner_confirmation_reference(topic_key:, proposal_attempt:, bytes:)
    path = owner_confirmation_relative_path(topic_key: topic_key, proposal_attempt: proposal_attempt)
    "#{path}#sha256:#{sha256_hex(bytes.b)}"
  end

  def parse_owner_confirmation_reference(reference, topic_key: nil, proposal_attempt: nil)
    actual_string!(reference, "authorization reference", ascii: true)
    match = /\A(45_ai-systems\/self-growth\/confirmations\/([^\/]+)\/([1-9][0-9]*)\/owner-confirmation\.txt)#sha256:([0-9a-f]{64})\z/.match(reference)
    fail_closed("authorization-reference-invalid") unless match
    parsed_topic = validate_topic_key!(match[2])
    if topic_key && parsed_topic != topic_key
      fail_closed("authorization-reference-invalid", "topic mismatch")
    end
    if proposal_attempt && match[3] != proposal_attempt.to_s
      fail_closed("authorization-reference-invalid", "attempt mismatch")
    end
    canonical = owner_confirmation_relative_path(topic_key: parsed_topic, proposal_attempt: match[3])
    fail_closed("authorization-reference-invalid", "path is not canonical") unless match[1] == canonical
    {
      "path" => match[1],
      "topic_key" => parsed_topic,
      "proposal_attempt" => match[3].to_i,
      "sha256" => match[4],
    }
  end

  def decision_snapshot_rollout_fields(decision, issued_inputs)
    if decision == "GO"
      backup = required_raw_input!(issued_inputs, "backup_ref")
      metric = required_raw_input!(issued_inputs, "effect_metric")
      due = required_raw_input!(issued_inputs, "report_due")
      parse_utc_timestamp(due)
      reject_present_input!(issued_inputs, "reason")
      {
        "backup-reference-sha256" => sha256_hex(backup.b),
        "effect-metric-sha256" => sha256_hex(metric.b),
        "report-due" => due,
        "reason-sha256" => "none",
      }
    else
      reason = required_raw_input!(issued_inputs, "reason")
      %w[backup_ref effect_metric report_due].each { |key| reject_present_input!(issued_inputs, key) }
      {
        "backup-reference-sha256" => "none",
        "effect-metric-sha256" => "none",
        "report-due" => "none",
        "reason-sha256" => sha256_hex(reason.b),
      }
    end
  end

  def required_raw_input!(inputs, key)
    value = flexible_fetch(inputs, key)
    actual_string!(value, key, min_bytes: 1, max_bytes: 8192, control_free: true)
  rescue KeyError
    fail_closed("record-damaged", "missing #{key}")
  end

  def reject_present_input!(inputs, key)
    return unless flexible_key?(inputs, key)
    fail_closed("record-damaged", "#{key} is irrelevant to this decision")
  end

  def evidence_value(evidence, key)
    flexible_fetch(evidence, key)
  rescue KeyError
    fail_closed("evidence-damaged", "missing #{key}")
  end

  def evidence_digest!(evidence, key)
    value = evidence_value(evidence, key)
    fail_closed("evidence-damaged", "invalid #{key}") unless value.is_a?(String) && SHA256_RE.match?(value)
    value
  end

  def evidence_digest_or_none!(evidence, key)
    value = evidence_value(evidence, key)
    fail_closed("evidence-damaged", "invalid #{key}") unless value == "none" || (value.is_a?(String) && SHA256_RE.match?(value))
    value
  end

  def evidence_reference!(evidence, key)
    value = evidence_value(evidence, key)
    actual_string!(value, key, min_bytes: 1, max_bytes: 1024, ascii: true, control_free: true)
  end

  def validate_snapshot_evidence_pairing!(fields, task_id, risk_tier)
    topic = fields.fetch("topic-key")
    if risk_tier == "T0"
      %w[manifest-reference manifest-evidence-sha256 council-reference council-evidence-sha256].each do |key|
        fail_closed("evidence-damaged", "#{key} must be none for T0") unless fields[key] == "none"
      end
    else
      manifest = "45_ai-systems/self-growth/council/#{topic}/#{task_id}.convene.yaml"
      council = "45_ai-systems/self-growth/council/#{topic}/#{task_id}.quorum.md"
      fail_closed("evidence-damaged", "manifest reference mismatch") unless fields["manifest-reference"] == manifest
      fail_closed("evidence-damaged", "council reference mismatch") unless fields["council-reference"] == council
      fail_closed("evidence-damaged", "manifest digest missing") unless SHA256_RE.match?(fields["manifest-evidence-sha256"])
      fail_closed("evidence-damaged", "council digest missing") unless SHA256_RE.match?(fields["council-evidence-sha256"])
    end
  end

  def parse_decision_snapshot(bytes)
    fields = parse_labeled_block(
      bytes,
      "sgl-decision-snapshot/v1",
      SNAPSHOT_KEYS,
      "authorization-artifact-damaged",
    )
    fail_closed("authorization-artifact-damaged", "invalid assurance") unless fields["assurance"] == "standard"
    fail_closed("authorization-artifact-damaged", "invalid principal") unless /\A[a-z0-9_-]{1,64}\z/.match?(fields["principal"])
    unless fields["repository-id"].bytesize.between?(3, 255) &&
           /\A[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\z/.match?(fields["repository-id"])
      fail_closed("authorization-artifact-damaged", "invalid repository-id")
    end
    validate_topic_key!(fields["topic-key"])
    fail_closed("authorization-artifact-damaged", "invalid proposal attempt") unless POSITIVE_INTEGER_RE.match?(fields["proposal-attempt"])
    %w[title-sha256 judgement-sha256 reversibility-sha256 trial-evidence-sha256].each do |key|
      fail_closed("authorization-artifact-damaged", "invalid #{key}") unless SHA256_RE.match?(fields[key])
    end
    fail_closed("authorization-artifact-damaged", "invalid risk tier") unless %w[T0 T1 T2].include?(fields["risk-tier"])
    fail_closed("authorization-artifact-damaged", "invalid identity-critical") unless %w[true false].include?(fields["identity-critical"])
    validate_trial_reference!(fields["trial-reference"], fields["topic-key"])
    %w[manifest-evidence-sha256 council-evidence-sha256 backup-reference-sha256 effect-metric-sha256 reason-sha256].each do |key|
      fail_closed("authorization-artifact-damaged", "invalid #{key}") unless fields[key] == "none" || SHA256_RE.match?(fields[key])
    end
    fail_closed("authorization-artifact-damaged", "invalid decision") unless %w[GO REJECT WATCH].include?(fields["decision"])
    if fields["decision"] == "GO"
      unless SHA256_RE.match?(fields["backup-reference-sha256"]) &&
             SHA256_RE.match?(fields["effect-metric-sha256"]) &&
             fields["reason-sha256"] == "none"
        fail_closed("authorization-artifact-damaged", "GO rollout fields mismatch")
      end
      parse_utc_timestamp(fields["report-due"])
    else
      unless fields["backup-reference-sha256"] == "none" &&
             fields["effect-metric-sha256"] == "none" &&
             fields["report-due"] == "none" &&
             SHA256_RE.match?(fields["reason-sha256"])
        fail_closed("authorization-artifact-damaged", "reason disposition fields mismatch")
      end
    end
    validate_snapshot_evidence_pairing!(
      fields,
      task_id_from_trial_reference(fields["trial-reference"]),
      fields["risk-tier"],
    )
    fields
  end

  def serialize_labeled_block(schema, fields)
    fields.each do |key, value|
      actual_string!(key, "field name", ascii: true)
      actual_string!(value, key, min_bytes: 1, control_free: true)
    end
    ([schema] + fields.map { |key, value| "#{key}: #{value}" }).join("\n") + "\n"
  end

  def parse_labeled_block(bytes, schema, keys, token)
    text = valid_utf8_bytes!(bytes, token, schema)
    fail_closed(token, "#{schema} lacks one terminal LF") unless text.end_with?("\n")
    lines = text.split("\n", -1)
    fail_closed(token, "#{schema} contains an extra blank line") unless lines.pop == ""
    fail_closed(token, "#{schema} line count mismatch") unless lines.length == keys.length + 1
    fail_closed(token, "#{schema} mismatch") unless lines.shift == schema
    result = {}
    keys.each_with_index do |key, index|
      prefix = "#{key}: "
      line = lines[index]
      fail_closed(token, "#{key} line mismatch") unless line.start_with?(prefix)
      value = line.byteslice(prefix.bytesize, line.bytesize - prefix.bytesize)
      fail_closed(token, "#{key} is empty") if value.nil? || value.empty?
      fail_closed(token, "#{key} contains an ASCII control byte") if value.b.match?(/[\x00-\x1f\x7f]/n)
      result[key] = value
    end
    fail_closed(token, "#{schema} is noncanonical") unless serialize_labeled_block(schema, result) == text
    result
  end

  def derive_t0_evidence(vault_root:, workspace_root:, record:)
    validate_t0_eligibility!(record)
    root = canonicalize_root(vault_root)
    topic = validate_topic_key!(record["topic_key"])
    trial_reference = validate_trial_reference!(record.dig("links", "trial_bundle"), topic)
    task_id = task_id_from_trial_reference(trial_reference)
    relative = "45_ai-systems/self-growth/council/#{topic}/#{task_id}.t0-skip.md"

    if workspace_root.nil?
      path = canonical_contained_path(
        root: root,
        relative_path: relative,
        max_bytes: MAX_EVIDENCE_BYTES,
        label: "t0-evidence",
      )
      bytes = read_regular_file(path, max_bytes: MAX_EVIDENCE_BYTES, label: "t0-evidence", utf8: true)
      parse_t0_artifact(bytes, topic_key: topic, task_id: task_id, trial_reference: trial_reference)
    else
      workspace = canonicalize_root(workspace_root)
      packet_relative = "45_ai-systems/self-growth/trial-packets/#{task_id}.md"
      packet_path = canonical_contained_path(
        root: root,
        relative_path: packet_relative,
        max_bytes: MAX_EVIDENCE_BYTES,
        label: "trial-packet",
      )
      packet = read_regular_file(packet_path, max_bytes: MAX_EVIDENCE_BYTES, label: "trial-packet")
      digests = {}
      BUNDLE_FILES.each do |filename|
        relative_bundle = "loop/artifacts/#{task_id}/out/bundle/#{filename}"
        bundle_path = canonical_contained_path(
          root: workspace,
          relative_path: relative_bundle,
          max_bytes: MAX_EVIDENCE_BYTES,
          label: "trial-bundle",
        )
        digests[filename] = sha256_hex(
          read_regular_file(bundle_path, max_bytes: MAX_EVIDENCE_BYTES, label: "trial-bundle"),
        )
      end
      packet_digest = sha256_hex(packet)
      bundle_map_digest = sha256_hex(serialize_bundle_digest_map(digests))
      fields = {
        "sealed" => "true",
        "topic-key" => topic,
        "task-id" => task_id,
        "trial-reference" => trial_reference,
        "packet-sha256" => packet_digest,
        "bundle-map-sha256" => bundle_map_digest,
        "marker" => T0_MARKER,
      }
      bytes = serialize_labeled_block("sgl-t0-skip/v1", fields)
      parse_t0_artifact(bytes, topic_key: topic, task_id: task_id, trial_reference: trial_reference).merge(
        "artifact_relative_path" => relative,
        "packet_sha256" => packet_digest,
        "bundle_digests" => digests.freeze,
      )
    end
  end

  def derive_council_evidence(vault_root:, record:)
    root = canonicalize_root(vault_root)
    topic = validate_topic_key!(record["topic_key"])
    trial_reference = validate_trial_reference!(record.dig("links", "trial_bundle"), topic)
    task_id = task_id_from_trial_reference(trial_reference)
    manifest_relative = "45_ai-systems/self-growth/council/#{topic}/#{task_id}.convene.yaml"
    quorum_relative = "45_ai-systems/self-growth/council/#{topic}/#{task_id}.quorum.md"
    manifest_path = canonical_contained_path(
      root: root,
      relative_path: manifest_relative,
      max_bytes: MAX_EVIDENCE_BYTES,
      label: "council-manifest",
    )
    quorum_path = canonical_contained_path(
      root: root,
      relative_path: quorum_relative,
      max_bytes: MAX_EVIDENCE_BYTES,
      label: "council-quorum",
    )
    manifest_bytes = read_regular_file(manifest_path, max_bytes: MAX_EVIDENCE_BYTES, label: "council-manifest", utf8: true)
    quorum_bytes = read_regular_file(quorum_path, max_bytes: MAX_EVIDENCE_BYTES, label: "council-quorum", utf8: true)
    reject_yaml_duplicates!(manifest_bytes, "council manifest")
    manifest = safe_yaml_load(manifest_bytes, "council manifest")
    validate_council_manifest!(
      manifest,
      raw: manifest_bytes,
      topic_key: topic,
      task_id: task_id,
      trial_reference: trial_reference,
    )
    quorum, quorum_body, quorum_frontmatter = parse_yaml_frontmatter_document(quorum_bytes, "council quorum")
    validate_council_quorum!(
      quorum,
      body: quorum_body,
      raw: quorum_frontmatter,
      manifest: manifest,
      task_id: task_id,
    )
    packet_digest = manifest.dig("digests", "packet")
    bundle_digests = manifest.dig("digests", "bundle")
    trial_digest = sha256_hex(
      "packet=#{packet_digest}\n" + serialize_bundle_digest_map(bundle_digests),
    )
    {
      "trial_reference" => trial_reference,
      "trial_evidence_sha256" => trial_digest,
      "manifest_reference" => manifest_relative,
      "manifest_evidence_sha256" => sha256_hex(manifest_bytes),
      "council_reference" => quorum_relative,
      "council_evidence_sha256" => sha256_hex(quorum_bytes),
      "task_id" => task_id,
      "manifest" => manifest,
      "quorum" => quorum,
    }
  end

  def parse_t0_artifact(bytes, topic_key:, task_id:, trial_reference:)
    fields = parse_labeled_block(
      bytes,
      "sgl-t0-skip/v1",
      %w[sealed topic-key task-id trial-reference packet-sha256 bundle-map-sha256 marker],
      "t0-evidence-damaged",
    )
    fail_closed("t0-evidence-damaged", "sealed mismatch") unless fields["sealed"] == "true"
    fail_closed("t0-evidence-damaged", "topic mismatch") unless fields["topic-key"] == topic_key
    fail_closed("t0-evidence-damaged", "task mismatch") unless fields["task-id"] == task_id
    fail_closed("t0-evidence-damaged", "trial reference mismatch") unless fields["trial-reference"] == trial_reference
    fail_closed("t0-evidence-damaged", "packet digest invalid") unless SHA256_RE.match?(fields["packet-sha256"])
    fail_closed("t0-evidence-damaged", "bundle map digest invalid") unless SHA256_RE.match?(fields["bundle-map-sha256"])
    fail_closed("t0-evidence-damaged", "marker mismatch") unless fields["marker"] == T0_MARKER
    {
      "trial_reference" => trial_reference,
      "trial_evidence_sha256" => sha256_hex(bytes.b),
      "manifest_reference" => "none",
      "manifest_evidence_sha256" => "none",
      "council_reference" => "none",
      "council_evidence_sha256" => "none",
      "task_id" => task_id,
      "artifact_bytes" => bytes.b,
      "t0_fields" => fields,
    }
  end

  def validate_t0_eligibility!(record)
    unless record.is_a?(Hash) &&
           record["risk_tier"] == "T0" &&
           record["identity_critical"] == false &&
           record["reversibility"].is_a?(String) &&
           !record["reversibility"].empty?
      fail_closed("t0-eligibility-mismatch")
    end
    actual_string!(record["reversibility"], "reversibility", min_bytes: 1, control_free: true)
    true
  end

  def validate_council_manifest!(manifest, raw:, topic_key:, task_id:, trial_reference:)
    fail_closed("council-evidence-damaged", "manifest is not a mapping") unless manifest.is_a?(Hash)
    expected_keys = %w[
      schema topic_key task_id bundle executor_model executor_family convened_at
      correlated_panel correlated_reason writer_correlated digests seats sealed
      decision decision_at
    ]
    fail_closed("council-evidence-damaged", "manifest keys/order mismatch") unless manifest.keys == expected_keys
    fail_closed("council-evidence-damaged", "manifest schema mismatch") unless manifest["schema"] == "sgl-council-convene/v1"
    fail_closed("council-evidence-damaged", "manifest topic mismatch") unless manifest["topic_key"] == topic_key
    fail_closed("council-evidence-damaged", "manifest task mismatch") unless manifest["task_id"] == task_id
    fail_closed("council-evidence-damaged", "manifest bundle mismatch") unless manifest["bundle"] == trial_reference
    %w[executor_model executor_family].each do |key|
      actual_string!(manifest[key], "manifest #{key}", min_bytes: 1, control_free: true)
    end
    actual_string!(manifest["correlated_reason"], "manifest correlated_reason", control_free: true)
    parse_utc_timestamp(timestamp_scalar(manifest["convened_at"], "manifest convened_at"))
    %w[correlated_panel writer_correlated].each do |key|
      fail_closed("council-evidence-damaged", "#{key} must be boolean") unless manifest[key] == true || manifest[key] == false
    end
    fail_closed("council-evidence-damaged", "manifest must be sealed") unless manifest["sealed"] == true
    fail_closed("council-evidence-damaged", "manifest decision invalid") unless ["GO", "GO (Sho override of security veto)"].include?(manifest["decision"])
    parse_utc_timestamp(timestamp_scalar(manifest["decision_at"], "manifest decision_at"))

    digests = manifest["digests"]
    fail_closed("council-evidence-damaged", "manifest digests keys/order mismatch") unless digests.is_a?(Hash) && digests.keys == %w[packet bundle]
    fail_closed("council-evidence-damaged", "packet digest invalid") unless digests["packet"].is_a?(String) && SHA256_RE.match?(digests["packet"])
    bundle = digests["bundle"]
    unless bundle.is_a?(Hash) && bundle.keys.sort_by(&:b) == BUNDLE_FILES
      fail_closed("council-evidence-damaged", "bundle digest map mismatch")
    end
    bundle.each do |name, digest|
      fail_closed("council-evidence-damaged", "invalid bundle digest #{name}") unless digest.is_a?(String) && SHA256_RE.match?(digest)
    end

    seats = manifest["seats"]
    fail_closed("council-evidence-damaged", "seats must be a sequence") unless seats.is_a?(Array)
    attempt_tokens = raw.lines.grep(/\A +attempt: /)
    fail_closed("council-evidence-damaged", "seat attempt token count mismatch") unless attempt_tokens.length == seats.length
    identities = {}
    seat_keys = %w[seat lens attempt evaluator_model evaluator_family evaluator_vendor deadline status brief brief_digest]
    seats.each_with_index do |seat, index|
      fail_closed("council-evidence-damaged", "seat is not a mapping") unless seat.is_a?(Hash) && seat.keys == seat_keys
      lens = seat["lens"]
      fail_closed("council-evidence-damaged", "seat lens invalid") unless %w[utility cost security].include?(lens)
      attempt = seat["attempt"]
      attempt_line = attempt_tokens[index]
      unless attempt.is_a?(Integer) && attempt.positive? &&
             /\A +attempt: #{attempt}\n\z/.match?(attempt_line)
        fail_closed("council-evidence-damaged", "seat attempt token invalid")
      end
      identity = "#{lens}-a#{attempt}"
      fail_closed("council-evidence-damaged", "seat identity mismatch") unless seat["seat"] == identity
      fail_closed("council-evidence-damaged", "duplicate seat identity") if identities.key?([lens, attempt])
      identities[[lens, attempt]] = true
      %w[evaluator_model evaluator_family evaluator_vendor brief].each do |key|
        actual_string!(seat[key], "seat #{key}", min_bytes: 1, control_free: true)
      end
      parse_utc_timestamp(timestamp_scalar(seat["deadline"], "seat deadline"))
      fail_closed("council-evidence-damaged", "seat status invalid") unless %w[seated timed_out].include?(seat["status"])
      fail_closed("council-evidence-damaged", "brief digest invalid") unless seat["brief_digest"].is_a?(String) && SHA256_RE.match?(seat["brief_digest"])
    end
    manifest
  end

  def validate_council_quorum!(quorum, body:, raw:, manifest:, task_id:)
    expected_keys = %w[schema task_id decision decision_at sealed counted_attempt_ids]
    fail_closed("council-evidence-damaged", "quorum keys/order mismatch") unless quorum.is_a?(Hash) && quorum.keys == expected_keys
    fail_closed("council-evidence-damaged", "quorum schema mismatch") unless quorum["schema"] == "sgl-council-quorum/v1"
    fail_closed("council-evidence-damaged", "quorum task mismatch") unless quorum["task_id"] == task_id
    fail_closed("council-evidence-damaged", "quorum decision mismatch") unless quorum["decision"] == manifest["decision"]
    fail_closed("council-evidence-damaged", "quorum decision_at mismatch") unless timestamp_scalar(quorum["decision_at"], "quorum decision_at") == timestamp_scalar(manifest["decision_at"], "manifest decision_at")
    decision_at = timestamp_scalar(quorum["decision_at"], "quorum decision_at")
    unless raw.lines.any? { |line| line == "decision_at: #{decision_at}\n" }
      fail_closed("council-evidence-damaged", "quorum decision_at token is noncanonical")
    end
    fail_closed("council-evidence-damaged", "quorum must be sealed") unless quorum["sealed"] == true

    active = {}
    %w[utility cost security].each do |lens|
      candidates = manifest["seats"].select { |seat| seat["lens"] == lens && seat["status"] != "timed_out" }
      fail_closed("council-evidence-damaged", "no active #{lens} seat") if candidates.empty?
      maximum = candidates.map { |seat| seat["attempt"] }.max
      greatest = candidates.select { |seat| seat["attempt"] == maximum }
      fail_closed("council-evidence-damaged", "ambiguous active #{lens} seat") unless greatest.length == 1
      active[lens] = greatest.first
    end
    expected_ids = %w[utility cost security].map { |lens| active[lens]["seat"] }
    counted = quorum["counted_attempt_ids"]
    unless counted.is_a?(Array) && counted.length == 3 &&
           counted.all? { |value| value.is_a?(String) } && counted == expected_ids
      fail_closed("council-evidence-damaged", "counted attempt identities mismatch")
    end
    validate_vote_table!(body, active)
    quorum
  end

  def validate_vote_table!(body, active)
    heading = "## Vote table\n"
    offsets = []
    cursor = 0
    while (found = exact_line_offset(body, heading, start_offset: cursor))
      offsets << found
      cursor = found + heading.bytesize
    end
    fail_closed("council-evidence-damaged", "Vote table heading count mismatch") unless offsets.length == 1
    start = offsets.first + heading.bytesize
    following = body.byteslice(start, body.bytesize - start)
    terminator = next_markdown_heading_offset(following)
    section = terminator ? following.byteslice(0, terminator) : following
    lines = section.lines
    expected_header = [
      "\n",
      "| Lens | Attempt | Model | State | Verdict |\n",
      "|---|---:|---|---|---|\n",
    ]
    fail_closed("council-evidence-damaged", "Vote table grammar mismatch") unless lines.shift(3) == expected_header
    rows = lines.take_while { |line| line.start_with?("|") }
    fail_closed("council-evidence-damaged", "Vote table row count mismatch") unless rows.length == 3
    %w[utility cost security].each_with_index do |lens, index|
      match = /\A\| (utility|cost|security) \| a([1-9][0-9]*) \| ([^|\n]+) \| ([^|\n]+) \| ([^|\n]*) \|\n\z/.match(rows[index])
      fail_closed("council-evidence-damaged", "Vote table row grammar mismatch") unless match
      seat = active[lens]
      unless match[1] == lens && match[2].to_i == seat["attempt"] && match[3] == seat["evaluator_model"]
        fail_closed("council-evidence-damaged", "Vote table active seat mismatch")
      end
    end
  end

  def canonicalize_root(path)
    actual_string!(path.to_s, "root path", min_bytes: 1)
    expanded = File.expand_path(path.to_s)
    begin
      canonical = File.realpath(expanded)
      stat = File.stat(canonical)
    rescue SystemCallError => e
      fail_closed("root-invalid", e.message)
    end
    fail_closed("root-invalid", "root is not a directory") unless stat.directory?
    canonical.freeze
  end

  def canonical_contained_path(root:, relative_path:, max_bytes:, label:)
    canonical_root = canonicalize_root(root)
    relative = relative_path.to_s
    fail_closed("#{label}-path-invalid", "path is not valid UTF-8") unless relative.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    fail_closed("#{label}-path-invalid", "absolute path rejected") if Pathname.new(relative).absolute?
    components = relative.split("/", -1)
    if components.empty? || components.any? { |part| part.empty? || part == "." || part == ".." }
      fail_closed("#{label}-path-invalid", "noncanonical path component")
    end
    current = canonical_root
    components.each_with_index do |component, index|
      current = File.join(current, component)
      begin
        stat = File.lstat(current)
      rescue Errno::ENOENT, Errno::ENOTDIR
        fail_closed("#{label}-missing", relative)
      rescue SystemCallError => e
        fail_closed("#{label}-path-invalid", e.message)
      end
      fail_closed("#{label}-symlink", component) if stat.symlink?
      if index < components.length - 1
        fail_closed("#{label}-path-invalid", "#{component} is not a directory") unless stat.directory?
      else
        fail_closed("#{label}-not-regular") unless stat.file?
        fail_closed("#{label}-too-large") if stat.size > max_bytes
      end
    end
    begin
      real = File.realpath(current)
    rescue SystemCallError => e
      fail_closed("#{label}-path-invalid", e.message)
    end
    expected = File.join(canonical_root, *components)
    fail_closed("#{label}-path-invalid", "realpath mismatch") unless real == expected
    prefix = canonical_root.end_with?(File::SEPARATOR) ? canonical_root : "#{canonical_root}#{File::SEPARATOR}"
    fail_closed("#{label}-path-invalid", "path escapes root") unless real.start_with?(prefix)
    real
  end

  def sha256_hex(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def utc_timestamp(time)
    utc = time.utc
    fail_closed("timestamp-out-of-range") unless utc.year.between?(1, 9999)
    format(
      "%04d-%02d-%02dT%02d:%02d:%02dZ",
      utc.year, utc.month, utc.day, utc.hour, utc.min, utc.sec,
    )
  end

  def parse_utc_timestamp(value)
    fail_closed("timestamp-invalid", "timestamp must be a string") unless value.is_a?(String)
    match = TIMESTAMP_RE.match(value)
    fail_closed("timestamp-invalid", value) unless match
    year, month, day, hour, minute, second = match.captures.map(&:to_i)
    unless year.between?(1, 9999) && Date.valid_date?(year, month, day) &&
           hour.between?(0, 23) && minute.between?(0, 59)
      fail_closed("timestamp-invalid", value)
    end
    begin
      Time.utc(year, month, day, hour, minute, second)
    rescue ArgumentError, RangeError
      fail_closed("timestamp-invalid", value)
    end
  end

  def hostname
    Socket.gethostname
  end

  def valid_utf8_bytes!(bytes, token, label)
    fail_closed(token, "#{label} must be bytes") unless bytes.is_a?(String)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    fail_closed(token, "#{label} is not valid UTF-8") unless text.valid_encoding?
    text
  end

  def read_regular_file(path, max_bytes:, label:, utf8: false)
    before = File.lstat(path)
    fail_closed("#{label}-symlink") if before.symlink?
    fail_closed("#{label}-not-regular") unless before.file?
    fail_closed("#{label}-too-large") if before.size > max_bytes
    flags = File::RDONLY
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    bytes = nil
    File.open(path, flags) do |file|
      held = file.stat
      unless held.file? && held.dev == before.dev && held.ino == before.ino
        fail_closed("#{label}-path-invalid", "file identity changed")
      end
      bytes = file.read(max_bytes + 1)
      fail_closed("#{label}-too-large") if bytes.bytesize > max_bytes
      after = File.lstat(path)
      unless !after.symlink? && after.file? && after.dev == held.dev && after.ino == held.ino
        fail_closed("#{label}-path-invalid", "file identity changed")
      end
    end
    valid_utf8_bytes!(bytes, "#{label}-invalid-utf8", label) if utf8
    bytes.b
  rescue Errno::ELOOP
    fail_closed("#{label}-symlink")
  rescue Errno::ENOENT, Errno::ENOTDIR
    fail_closed("#{label}-missing")
  end

  def exact_line_offset(bytes, exact_line, start_offset: 0)
    binary_bytes = bytes.b
    binary_line = exact_line.b
    cursor = start_offset
    while (index = binary_bytes.index(binary_line, cursor))
      return index if index.zero? || binary_bytes.getbyte(index - 1) == 0x0a
      cursor = index + 1
    end
    nil
  end

  def next_markdown_heading_offset(bytes)
    binary_bytes = bytes.b
    return 0 if binary_bytes.start_with?("## ".b)
    index = binary_bytes.index("\n## ".b)
    index && index + 1
  end

  def extract_judgement_span(body)
    heading = "## Judgement\n"
    offsets = []
    cursor = 0
    while (found = exact_line_offset(body, heading, start_offset: cursor))
      offsets << found
      cursor = found + heading.bytesize
    end
    fail_closed("record-damaged", "Judgement heading count mismatch") unless offsets.length == 1
    start = offsets.first + heading.bytesize
    remainder = body.byteslice(start, body.bytesize - start) || ""
    finish = next_markdown_heading_offset(remainder)
    span = finish ? remainder.byteslice(0, finish) : remainder
    fail_closed("record-damaged", "Judgement is blank") unless span.b.match?(/[^\x09\x0a\x0c\x0d\x20]/n)
    span
  end

  def markdown_frontmatter_as_yaml(frontmatter)
    unless frontmatter.start_with?("---\n") && frontmatter.end_with?("---\n")
      fail_closed("record-damaged", "frontmatter delimiters invalid")
    end
    frontmatter.byteslice(0, frontmatter.bytesize - 4) + "...\n"
  end

  def parse_yaml_frontmatter_document(bytes, label)
    text = valid_utf8_bytes!(bytes, "council-evidence-damaged", label)
    fail_closed("council-evidence-damaged", "#{label} frontmatter missing") unless text.start_with?("---\n")
    closing = exact_line_offset(text, "---\n", start_offset: 4)
    fail_closed("council-evidence-damaged", "#{label} frontmatter terminator missing") unless closing
    finish = closing + 4
    frontmatter = text.byteslice(0, finish)
    yaml = markdown_frontmatter_as_yaml(frontmatter)
    reject_yaml_duplicates!(yaml, label)
    data = safe_yaml_load(yaml, label)
    fail_closed("council-evidence-damaged", "#{label} frontmatter is not a mapping") unless data.is_a?(Hash)
    [data, text.byteslice(finish, text.bytesize - finish) || "", frontmatter]
  end

  def reject_yaml_duplicates!(yaml, label)
    stream = Psych.parse_stream(yaml)
    fail_closed("record-damaged", "#{label} must contain exactly one YAML document") unless stream.children.length == 1
    document = stream.children.first
    walk_yaml_node_for_duplicates!(document.root, label) if document.root
  rescue Psych::SyntaxError => e
    fail_closed("record-damaged", "#{label} YAML syntax: #{e.message}")
  end

  def walk_yaml_node_for_duplicates!(node, label)
    case node
    when Psych::Nodes::Mapping
      seen = {}
      node.children.each_slice(2) do |key_node, value_node|
        unless key_node.is_a?(Psych::Nodes::Scalar)
          fail_closed("record-damaged", "#{label} contains a non-scalar mapping key")
        end
        key = key_node.value
        fail_closed("record-damaged", "#{label} contains duplicate key #{key}") if seen.key?(key)
        seen[key] = true
        walk_yaml_node_for_duplicates!(value_node, label)
      end
    when Psych::Nodes::Sequence
      node.children.each { |child| walk_yaml_node_for_duplicates!(child, label) }
    when Psych::Nodes::Alias
      fail_closed("record-damaged", "#{label} contains a YAML alias")
    end
  end

  def safe_yaml_load(yaml, label)
    YAML.safe_load(yaml, permitted_classes: [Date, Time], aliases: false)
  rescue Psych::Exception => e
    fail_closed("record-damaged", "#{label} YAML is unsafe: #{e.message}")
  end

  def deep_copy(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, child), copy| copy[deep_copy(key)] = deep_copy(child) }
    when Array
      value.map { |child| deep_copy(child) }
    when String
      value.dup
    when Time
      value.dup
    when Date
      value.dup
    else
      value
    end
  end

  def proposal_semantically_equal?(parsed, expected)
    PROPOSAL_KEYS.all? { |key| parsed[key] == expected[key] }
  end

  def atomic_replace_regular_file(path, bytes, label:)
    destination = File.expand_path(path)
    directory = canonicalize_root(File.dirname(destination))
    fail_closed("#{label}-path-invalid") unless File.dirname(destination) == directory
    if path_entry_exists?(destination)
      stat = File.lstat(destination)
      fail_closed("#{label}-symlink") if stat.symlink?
      fail_closed("#{label}-not-regular") unless stat.file?
      mode = stat.mode & 0o777
    else
      mode = 0o600
    end
    temporary = File.join(directory, ".#{File.basename(destination)}.tmp.#{$$}.#{SecureRandom.hex(8)}")
    begin
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      fail_closed("#{label}-write-failed", "temporary byte mismatch") unless read_regular_file(temporary, max_bytes: bytes.bytesize, label: "#{label}-temporary") == bytes.b
      File.rename(temporary, destination)
      fsync_directory(directory)
    ensure
      if path_entry_exists?(temporary)
        File.delete(temporary)
        fsync_directory(directory)
      end
    end
    destination
  end

  def fsync_directory(directory)
    File.open(directory, File::RDONLY) { |file| file.fsync }
  rescue SystemCallError => e
    fail_closed("durability-failed", e.message)
  end

  def path_entry_exists?(path)
    File.lstat(path)
    true
  rescue Errno::ENOENT, Errno::ENOTDIR
    false
  end

  def flexible_key?(mapping, key)
    mapping.respond_to?(:key?) &&
      (mapping.key?(key) || mapping.key?(key.to_sym) || mapping.key?(key.tr("_", "-")))
  end

  def flexible_fetch(mapping, key)
    fail_closed("record-damaged", "expected mapping") unless mapping.respond_to?(:key?)
    return mapping[key] if mapping.key?(key)
    symbol = key.to_sym
    return mapping[symbol] if mapping.key?(symbol)
    hyphenated = key.tr("_", "-")
    return mapping[hyphenated] if mapping.key?(hyphenated)
    raise KeyError, key
  end

  def validate_owner_config_mapping!(owner)
    expected = %w[schema principal repository_id default_assurance]
    fail_closed("owner-config-format-invalid") unless owner.is_a?(Hash) && owner.keys == expected
    fail_closed("owner-config-schema-unsupported") unless owner["schema"] == "sgl-owner-config/v1"
    fail_closed("unimplemented-assurance") unless owner["default_assurance"] == "standard"
    unless owner["principal"].is_a?(String) && /\A[a-z0-9_-]{1,64}\z/.match?(owner["principal"])
      fail_closed("owner-config-principal-invalid")
    end
    unless owner["repository_id"].is_a?(String) && owner["repository_id"].bytesize.between?(3, 255) &&
           /\A[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\z/.match?(owner["repository_id"])
      fail_closed("owner-config-repository-id-invalid")
    end
    owner
  end

  def validate_trial_reference!(value, topic_key)
    actual_string!(value, "links.trial_bundle", min_bytes: 1, ascii: true, control_free: true)
    pattern = /\Aloop\/artifacts\/(sgl-trial-#{Regexp.escape(topic_key)}-[0-9]{8}t[0-9]{6})\/\z/
    fail_closed("evidence-damaged", "invalid trial reference") unless pattern.match?(value)
    value
  end

  def task_id_from_trial_reference(reference)
    reference.byteslice("loop/artifacts/".bytesize, reference.bytesize - "loop/artifacts/".bytesize - 1)
  end

  def serialize_bundle_digest_map(digests)
    unless digests.is_a?(Hash) && digests.keys.sort_by(&:b) == BUNDLE_FILES
      fail_closed("evidence-damaged", "bundle digest map mismatch")
    end
    BUNDLE_FILES.map do |filename|
      digest = digests[filename]
      fail_closed("evidence-damaged", "invalid digest for #{filename}") unless digest.is_a?(String) && SHA256_RE.match?(digest)
      "#{filename}=#{digest}\n"
    end.join
  end

  def timestamp_scalar(value, label)
    string =
      case value
      when String
        value
      when Time
        utc_timestamp(value)
      else
        fail_closed("council-evidence-damaged", "#{label} is not a timestamp")
      end
    parse_utc_timestamp(string)
    string
  end
end
