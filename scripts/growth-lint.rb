#!/usr/bin/env ruby
# Frozen implementation for growth-lint.sh; kept in Ruby for strict YAML/time handling.
require 'yaml'
require 'time'
require 'fileutils'
require 'shellwords'
require File.expand_path('lib-owner-confirmation', __dir__)

vault, ledger, report, template = ENV.values_at('VAULT', 'LEDGER', 'REPORT', 'TEMPLATE')
dry = ENV['DRY_RUN'] == '1'
def ts(value)
  s = value.is_a?(Time) ? value.iso8601 : value.to_s
  return nil unless s.match?(/(?:Z|[+-]\d\d:\d\d)\z/)
  Time.iso8601(s).utc
rescue ArgumentError
  nil
end
now = ENV['NOW_OVERRIDE'].to_s.empty? ? Time.now.utc : ts(ENV['NOW_OVERRIDE'])
abort 'growth-lint.sh: --now must be ISO8601 with an explicit timezone' unless now
now_s = now.strftime('%Y-%m-%dT%H:%M:%SZ')
MAX_CORRELATED_RECORD_BYTES = 1_048_576

def record(path)
  raw = File.binread(path); raise 'invalid UTF-8' unless raw.force_encoding('UTF-8').valid_encoding?
  lines = raw.lines; raise 'frontmatter missing' unless lines.first == "---\n"
  finish = lines[1, 200].to_a.index("---\n"); raise 'frontmatter unbounded or missing terminator' unless finish
  finish += 1; raise 'frontmatter too large' if lines[0..finish].join.bytesize > 32 * 1024
  data = YAML.load(lines[0..finish].join); raise 'frontmatter is not a mapping' unless data.is_a?(Hash)
  OwnerConfirmation.normalize_state_on_read!(data)
  %w[state state_entered_at updated].each { |k| raise "non-literal or missing #{k} key" unless lines[1...finish].any? { |l| l.start_with?("#{k}:") } }
  [lines, finish, data]
end
def trial_task(data)
  id = File.basename(data.dig('links', 'trial_bundle').to_s); id.empty? || id == '.' ? 'unknown' : id
end
def prepare(path, lines, stop, target, entered, cooldown, updated, event)
  out=[]; seen={}
  lines.each_with_index do |line, i|
    if i < stop
      case line
      when /^state:/ then seen['state']=true; out << "state: #{target}\n"
      when /^state_entered_at:/ then seen['state_entered_at']=true; out << "state_entered_at: #{entered}\n"
      when /^updated:/ then seen['updated']=true; out << "updated: #{updated}\n"
      when /^cooldown_until:/ then seen['cooldown_until']=true; out << "cooldown_until: #{cooldown.empty? ? '""' : cooldown}\n"
      else out << line
      end
    elsif i == stop
      out << "cooldown_until: #{cooldown.empty? ? '""' : cooldown}\n" unless seen['cooldown_until']; out << line
    else out << line end
  end
  raise 'non-literal key spelling cannot be rewritten' unless %w[state state_entered_at updated].all? { |k| seen[k] }
  temp = "#{path}.growth-lint.#{$$}.#{rand(1_000_000)}"; mode = File.stat(path).mode & 0o7777
  File.open(temp, 'w', mode) { |f| f.write(out.join); f.write("#{event}\n"); f.flush; f.fsync }; File.chmod(mode, temp)
  parsed = YAML.load_file(temp)
  {'state'=>target, 'state_entered_at'=>entered, 'cooldown_until'=>cooldown, 'updated'=>updated}.each do |k,v|
    equal = if %w[state_entered_at cooldown_until].include?(k) && ts(parsed[k]) && ts(v)
      ts(parsed[k]) == ts(v)
    else
      parsed[k].to_s == v.to_s
    end
    raise "semantic postcondition failed for #{k}" unless equal
  end
  temp
rescue StandardError
  File.delete(temp) if defined?(temp) && temp && File.exist?(temp); raise
end

def owner_confirmation_map(data)
  value = data['owner_confirmation']
  value.is_a?(Hash) ? value : {}
end

def validate_v2_record_for_lint!(data, frontmatter)
  return unless data.key?('schema')
  raise 'proposal schema mismatch' unless data['schema'] == 'sgl-proposal/v2'
  raise 'proposal top-level keys/order do not match a closed schema' unless data.keys == OwnerConfirmation::PROPOSAL_KEYS
  OwnerConfirmation.validate_v2_record!(data, frontmatter)
end

def owner_config_token(vault)
  OwnerConfirmation.load_owner_config(vault_root: vault)
  nil
rescue OwnerConfirmation::Error => e
  e.code
end

def current_authorization_artifact(vault:, topic:, attempt:)
  relative = OwnerConfirmation.owner_confirmation_relative_path(topic_key: topic, proposal_attempt: attempt)
  path = OwnerConfirmation.canonical_contained_path(
    root: vault,
    relative_path: relative,
    max_bytes: OwnerConfirmation::MAX_CONFIRMATION_BYTES,
    label: 'authorization-artifact',
  )
  bytes = OwnerConfirmation.read_regular_file(
    path,
    max_bytes: OwnerConfirmation::MAX_CONFIRMATION_BYTES,
    label: 'authorization-artifact',
    utf8: true,
  )
  parsed = OwnerConfirmation.parse_owner_confirmation_artifact(bytes, topic_key: topic, proposal_attempt: attempt)
  {
    reference: OwnerConfirmation.build_owner_confirmation_reference(topic_key: topic, proposal_attempt: attempt, bytes: bytes),
    expires_at: parsed.fetch('header').fetch('expires-at'),
  }
rescue OwnerConfirmation::Error => e
  return nil if e.code == 'authorization-artifact-missing'
  raise
end

def adopt_confirm_templates(vault, topic)
  escaped_vault = Shellwords.escape(vault)
  escaped_topic = Shellwords.escape(topic)
  [
    '**Owner disposition templates**:',
    "`GO (NON-EXECUTABLE TEMPLATE): scripts/adopt-confirm.sh --vault #{escaped_vault} --topic #{escaped_topic} --decision GO --backup-ref <value> --effect-metric <value> --report-due <YYYY-MM-DDTHH:MM:SSZ>`",
    "`REJECT (NON-EXECUTABLE TEMPLATE): scripts/adopt-confirm.sh --vault #{escaped_vault} --topic #{escaped_topic} --decision REJECT --reason <value>`",
    "`WATCH (NON-EXECUTABLE TEMPLATE): scripts/adopt-confirm.sh --vault #{escaped_vault} --topic #{escaped_topic} --decision WATCH --reason <value>`",
  ].join("\n")
end

def authorization_queue_text(topic, data, vault, audits)
  attempt = data['proposal_attempt']
  return '**Owner disposition**: damaged — proposal_attempt must be a positive integer before issuance' unless attempt.is_a?(Integer) && attempt.positive?

  confirmation = owner_confirmation_map(data)
  config_status = owner_config_token(vault)
  artifact = current_authorization_artifact(vault: vault, topic: topic, attempt: attempt)
  lines = []
  if config_status
    audits << "#{topic}: #{config_status}"
    lines << "**Owner disposition**: blocked — `#{config_status}`"
  end
  if artifact
    lines << "CURRENT — supersedes any previously printed reference for this attempt: `#{artifact.fetch(:reference)}`"
    lines << "Consume-by: #{artifact.fetch(:expires_at)}"
    lines << 'Raw disposition values are intentionally not stored; retain the exact consume command from issuance or regenerate it by rerunning `adopt-confirm.sh` with the identical raw values.'
  elsif confirmation['status'].to_s == 'verified' && !confirmation['reference'].to_s.empty?
    audits << "#{topic}: damaged owner confirmation mapping without current canonical artifact"
    lines << '**Owner disposition**: damaged — verified owner confirmation has no current canonical artifact'
  else
    lines << adopt_confirm_templates(vault, topic)
  end
  lines.join("\n\n")
rescue OwnerConfirmation::Error => e
  audits << "#{topic}: damaged owner disposition evidence (#{e.code})"
  '**Owner disposition**: damaged — owner disposition evidence is invalid'
end

def adoption_owner_confirmation_fields(bytes)
  text = bytes.dup.force_encoding('UTF-8')
  raise 'adoption record is not valid UTF-8' unless text.valid_encoding?
  binary_text = text.b
  decision_count = text.scan(/^## Decision basis\n/).length
  observation_count = text.scan(/^## Observation contract\n/).length
  raise 'adoption record heading count mismatch' unless decision_count == 1 && observation_count == 1
  decision_offset = binary_text.index("## Decision basis\n".b)
  observation_offset = binary_text.index("## Observation contract\n".b)
  raise 'adoption record heading order mismatch' unless decision_offset && observation_offset && decision_offset < observation_offset
  count = text.scan(/^## Owner confirmation\n/).length
  return nil if count.zero?
  raise 'owner confirmation heading count mismatch' unless count == 1
  start = binary_text.index("## Owner confirmation\n".b)
  raise 'owner confirmation heading order mismatch' unless start && start > decision_offset && start < observation_offset
  section = text.byteslice(start, observation_offset - start)
  match = /\A## Owner confirmation\n\n- Status: ([^\n]+)\n- Assurance: ([^\n]+)\n- Reference: ([^\n]+)\n- Proposal digest: ([^\n]+)\n- Decision: ([^\n]+)\n- Principal: ([^\n]+)\n- Verified at: ([^\n]+)\n\n\z/.match(section)
  raise 'owner confirmation block format mismatch' unless match
  {
    'status' => match[1],
    'assurance' => match[2],
    'reference' => match[3],
    'proposal_digest' => match[4],
    'decision' => match[5],
    'principal' => match[6],
    'verified_at' => match[7],
  }
end

def legacy_closed_proposal?(data)
  data.is_a?(Hash) && data.keys == OwnerConfirmation::LEGACY_PROPOSAL_KEYS
end

def adoption_lint_status(topic, data, vault)
  links = data['links'].is_a?(Hash) ? data['links'] : {}
  relative = links['adoption_entry'].to_s
  raise 'adoption_entry missing' if relative.empty?
  path = OwnerConfirmation.canonical_contained_path(
    root: vault,
    relative_path: relative,
    max_bytes: MAX_CORRELATED_RECORD_BYTES,
    label: 'adoption-record',
  )
  bytes = OwnerConfirmation.read_regular_file(
    path,
    max_bytes: MAX_CORRELATED_RECORD_BYTES,
    label: 'adoption-record',
    utf8: true,
  )
  fields = adoption_owner_confirmation_fields(bytes)
  if fields.nil?
    return 'authorization-reference-unknown' if legacy_closed_proposal?(data) && data['state'].to_s == 'ADOPTED'
    raise 'owner confirmation block missing'
  end
  raise 'legacy adoption record unexpectedly carries owner confirmation block' if legacy_closed_proposal?(data)
  expected = owner_confirmation_map(data)
  raise 'owner confirmation mapping missing' unless expected.is_a?(Hash) && !expected.empty?
  %w[status assurance reference proposal_digest decision principal verified_at].each do |key|
    raise "owner confirmation #{key} mismatch" unless fields[key] == expected[key].to_s
  end
  raise 'owner confirmation decision must be GO' unless fields['decision'] == 'GO'
  attempt = data['proposal_attempt']
  raise 'proposal_attempt missing for adoption correlation' unless attempt.is_a?(Integer) && attempt.positive?
  OwnerConfirmation.parse_owner_confirmation_reference(fields['reference'], topic_key: topic, proposal_attempt: attempt)
  artifact = current_authorization_artifact(vault: vault, topic: topic, attempt: attempt)
  return 'authorization-artifact-missing' if artifact.nil?
  raise 'owner confirmation reference is not current' unless artifact.fetch(:reference) == fields['reference']
  nil
rescue OwnerConfirmation::Error => e
  return 'authorization-artifact-missing' if e.code == 'authorization-artifact-missing'
  raise e
end

def decision_card(topic, data, entered, body, now, vault, audits)
  data = {} unless data.is_a?(Hash)
  links = data['links'].is_a?(Hash) ? data['links'] : {}
  waiting = entered ? format('%.1f', (now-entered)/86400.0) : 'overdue'
  expiry = entered ? (entered + 30*86_400).utc.strftime('%Y-%m-%d') : 'unknown'
  raw_judgement = body[/^## Judgement\s*\n(.*?)(?=^## |\z)/m, 1].to_s
  judgement = raw_judgement.lines.map(&:strip).reject(&:empty?)
  judgement = judgement.first(5); judgement << '… [truncated]' if raw_judgement.lines.reject { |x| x.strip.empty? }.length > 5
  sources = Array(data['source_items']).map { |x| x.is_a?(Hash) ? x['url'].to_s : x.to_s }.reject(&:empty?)
  council = if data['risk_tier'].to_s == 'T0' && data['identity_critical'] != true && body.include?('auto-adopt path (T0), council skipped')
    'council skipped — T0 fast path (CANDIDATE marker only; this gate is still required)'
  else
    begin
      dir = links['council_verdicts'].to_s
      raise 'unsafe council verdict path' unless dir.empty? || (dir !~ /[[:cntrl:]]/ && !dir.start_with?('/') && !dir.split('/').include?('..'))
      candidates = dir.empty? ? [] : Dir.glob(File.join(vault, '45_ai-systems/self-growth', dir, '*.quorum.md'))
      candidates += Dir.glob(File.join(vault, '45_ai-systems/self-growth/council', topic, '*.quorum.md')) if candidates.empty?
      path = candidates.sort.last
      raise 'missing quorum' unless path && File.file?(path) && File.size(path) <= 256 * 1024
      quorum = File.binread(path).force_encoding('UTF-8'); raise 'invalid quorum encoding' unless quorum.valid_encoding?
      raise 'unsealed quorum' unless quorum.include?('sealed: true')
      votes = quorum[/^## Vote table\s*\n(.*?)(?=^## |\z)/m, 1].to_s.lines.grep(/^\|/).reject { |line| line.match?(/---|seat/i) }.first(3)
      raise 'malformed quorum vote table' if votes.length < 3
      dissent = quorum[/^## Dissents \/ reservations\s*\n(.*?)(?=^## |\z)/m, 1].to_s.strip
      "sealed quorum: #{File.basename(path)}\nVotes:\n#{votes.map(&:strip).join("\n")}#{dissent.empty? ? '' : "\nDissents:\n> #{dissent.gsub("\n", "\n> ")}"}"
    rescue StandardError => e
      "council record unavailable/damaged — #{e.message}; review before deciding"
    end
  end
  rollback = data['reversibility'].to_s.strip
  rollback = 'MISSING — protocol audit: declare reversibility before rollout' if rollback.empty?
  authorization = authorization_queue_text(topic, data, vault, audits)
  ["### #{topic} — #{data['title']}",
   "Waiting: #{waiting}d · expires: #{expiry} (30d SLA) · risk: #{data['risk_tier']} · identity_critical: #{data['identity_critical'] == true}",
   "**What**: #{data['title']}\n#{judgement.empty? ? '_No Judgement body recorded._' : judgement.map { |x| "- #{x}" }.join("\n")}",
   "**Why now**: proposer #{data['proposer']}#{sources.empty? ? '; source items missing' : '; '+sources.join(', ')}",
   "**Council**: #{council}",
   "**Trial evidence**: #{links['trial_bundle'].to_s.empty? ? 'missing' : links['trial_bundle']}",
   "**Rollback plan**: #{rollback}",
   authorization].join("\n\n")
end
states=Hash.new(0); actions=[]; pending=[]; effect_pending=[]; reminders=[]; overdue=[]; near=[]; audits=[]; proposed=[]; watch=[]; records=[]; plans=[]; errors=0; merged=0; recent=0
paths=Dir.exist?(ledger) ? Dir.glob(File.join(ledger, '*.md')).sort : []
paths.each do |path|
  begin
    raw=File.binread(path); raise 'invalid UTF-8' unless raw.force_encoding('UTF-8').valid_encoding?
    if raw.match?(/\AMERGED_INTO:\s*([^\s]+)\s*\z/)
      target=File.join(ledger, Regexp.last_match(1)+'.md'); content=File.file?(target) && File.binread(target)
      raise 'MERGED_INTO target missing or chained' unless content && !content.match?(/\AMERGED_INTO:/); merged+=1; next
    end
    raise 'malformed MERGED_INTO stub' if raw.start_with?('MERGED_INTO:')
    lines, stop, data=record(path); topic=data['topic_key'].to_s.empty? ? File.basename(path,'.md') : data['topic_key'].to_s
    validate_v2_record_for_lint!(data, lines[0..stop].join)
    entered=ts(data['state_entered_at']); raise 'future timestamp: state_entered_at' if entered && entered > now+300
    original=data['state'].to_s; raise 'missing state' if original.empty?; age=entered ? (now-entered)/86400.0 : Float::INFINITY; body=lines[(stop+1)..].to_a.join
    body.scan(/^-\s+(\S+).*?\b(?:SIGHTING|PROPOSED)\b/i).flatten.each { |stamp| t=ts(stamp); raise 'future timestamp: event' if t && t>now+300; recent+=1 if t && now-t<=172800 }
    audits << "#{topic}: identity_critical true requires risk_tier T2" if data['identity_critical']==true && data['risk_tier'].to_s!='T2'
    audits << "#{topic}: TRIALING missing executor_agent" if original=='TRIALING' && data['executor_agent'].to_s.empty?
    if original=='ADOPTING'; miss=%w[backup_ref effect_metric report_due].select { |k| data[k].to_s.empty? }; audits << "#{topic}: ADOPTING missing #{miss.join(', ')}" unless miss.empty? end
    audits << "#{topic}: PENDING_OWNER missing reversibility" if original=='PENDING_OWNER' && data['reversibility'].to_s.empty?
    body.each_line.grep(/TRIALING→(?:WATCH|DLQ)/).each { |l| audits << "#{topic}: trial transition missing task token" unless l.match?(/\btask\s+\S+/) }
    # YAML parses unquoted timestamps into Time; Time#to_s is NOT ISO8601Z, so
    # preserved fields must be re-normalized or appends corrupt the record.
    iso = ->(v) { (t=ts(v)) ? t.utc.strftime('%Y-%m-%dT%H:%M:%SZ') : v.to_s }
    state=original; entered_out=iso.call(data['state_entered_at']); cooldown=data['cooldown_until'].to_s.empty? ? '' : iso.call(data['cooldown_until']); event=nil
    rules={'PROPOSED'=>[14,'EXPIRED',(now+2592000).strftime('%Y-%m-%dT%H:%M:%SZ')], 'TRIALING'=>[7,'DLQ',cooldown], 'COUNCIL'=>[3,'DLQ',cooldown], 'PENDING_OWNER'=>[30,'EXPIRED',''], 'ADOPTING'=>[7,'DLQ',cooldown]}
    if rules[state] && age>=rules[state][0]
      limit,target,cooldown=rules[state]; note="SLA #{limit}d exceeded (#{entered ? format('state age %.1fd',age) : 'damaged state_entered_at; treated overdue now'})"
      audits << "#{topic}: transitioned with damaged state_entered_at — verify #{original}→#{target} was warranted" unless entered
      if state=='TRIALING'; id=trial_task(data); note += "; task #{id} abandoned to engine DLQ"; audits << "#{topic}: growth-lint used task unknown" if id=='unknown' end
      note += "; rollback_required: #{data['reversibility'].to_s.empty? ? 'declared reversibility missing' : data['reversibility']}" if state=='ADOPTING'
      event="- #{now_s} growth-lint #{state}→#{target} — #{note}"; entered_out=now_s; state=target
    elsif !entered
      raise 'state_entered_at missing/malformed'
    end
    if state == 'ADOPTED'
      begin
        adoption_status = adoption_lint_status(topic, data, vault)
        audits << "#{topic}: #{adoption_status}" if adoption_status
      rescue OwnerConfirmation::Error => e
        audits << "#{topic}: damaged adoption correlation (#{e.code})"
      rescue StandardError => e
        audits << "#{topic}: damaged adoption correlation (#{e.message})"
      end
    end
    if original=='ADOPTED' && !data['report_due'].to_s.empty?
      due=ts(data['report_due']); raise 'future timestamp: report_due' if due && due>now+300
      resolved=body.each_line.any? { |l| l.match?(/\b(?:EFFECT_REPORT|SHO_WAIVER)\b/) && !l.match?(/\bEFFECT_REPORT_OVERDUE\b/) }
      if due && due<now && !resolved
        days=(now-due)/86400.0; overdue << "#{topic} — effect report overdue #{format('%.1f',days)}d (due #{data['report_due']})"
        if days>=14
          # Append the escalation event once, but keep the PENDING_OWNER pin sticky
          # every run until EFFECT_REPORT/SHO_WAIVER resolves it (spec §3).
          event="- #{now_s} growth-lint EFFECT_REPORT_OVERDUE — effect report overdue — escalated to Sho" unless body.match?(/\bEFFECT_REPORT_OVERDUE\b/)
          effect_pending << [topic, data['report_due'].to_s, 'effect report overdue — escalated to Sho']
        end
      end
    end
    if event
      if dry then actions << "PLAN #{topic}: #{original}→#{state}"
      else plans << [path, prepare(path,lines,stop,state,entered_out,cooldown,now.strftime('%Y-%m-%d'),event),topic,original,state,data] end
    end
    states[state]+=1; pending << [topic,data,entered,nil,body] if state=='PENDING_OWNER'; reminders << "REMINDER #{topic} — waiting #{format('%.1f',age)}d; Sho reminder" if state=='PENDING_OWNER' && !event && age>=16 && age<30
    near << "#{topic} — #{format('%.1f',age)}d in TRIALING" if state=='TRIALING' && age>=5 && age<7
    if state=='PROPOSED'; tag=body[/Judgement\s*[:—-]?\s*\[(ADOPT-NOW|TRIAL|WATCH)\]/i,1] || '-'; (tag=='WATCH' ? watch : proposed) << [topic,tag,age,data['proposer'].to_s] end
    records << [state,data]
  rescue StandardError => e
    errors+=1; states['DAMAGED']+=1; actions << "DAMAGED #{File.basename(path)} — #{e.message}"
  end
end
pending.uniq! { |x| x[0] }; pending.sort_by!(&:first)
rows=pending.map { |k,d,t,e,b| decision_card(k,d,t,b || '',now,vault,audits) }
rows += effect_pending.sort_by(&:first).map { |topic, due, message| "### #{topic} — EFFECT_REPORT\n\n**Escalation**: #{message}; due #{due}. Run `EFFECT_REPORT` or `SHO_WAIVER` on the proposal record." }
plans.each do |path,temp,topic,source,target,data|
  begin File.rename(temp,path); actions << "TRANSITION #{topic}: #{source}→#{target}"
  rescue StandardError => e
    errors+=1; states[target]-=1; states[source]+=1
    records.each { |entry| entry[0]=source if entry[1].equal?(data) }
    actions << "DAMAGED #{topic} — commit failed: #{e.message}"
  ensure File.delete(temp) if File.exist?(temp) end
end
quotas=Hash.new(0); records.each { |state,data| quotas[data['executor_agent'].to_s.empty? ? '(missing executor_agent)' : data['executor_agent'].to_s]+=1 if state=='TRIALING' }

sense=[]; broken=false; sp=ENV['SENSE_STATUS'].to_s; sp=File.join(vault,'45_ai-systems/self-growth/sense-status.log') if sp.empty?; latest={}
if !File.file?(sp); broken=true; sense << "missing status file: #{sp}"
else
  File.foreach(sp).with_index { |line,i| f=line.strip.split(/\s+/,4); latest[f[1] || "line-#{i+1}"]=f }; ENV['SENSORS'].to_s.split(',').map(&:strip).reject(&:empty?).each { |s| latest[s]=nil unless latest.key?(s) }
  latest.keys.sort.each do |sensor|
    f=latest[sensor]
    if !f; broken=true; sense << "#{sensor}: BROKEN missing from status log (expected by roster)"
    elsif f.length<3 || !%w[OK FAIL].include?(f[2]) || !(t=ts(f[0])); broken=true; sense << "#{sensor}: BROKEN malformed latest status"
    elsif t>now+300; broken=true; sense << "#{sensor}: BROKEN future timestamp"
    elsif f[2]!='OK' || now-t>129600; broken=true; sense << "#{sensor}: #{f[2]} #{f[3]}".strip
    else sense << "#{sensor}: OK #{f[3]}".strip end
  end
end
totals=(["- Total records: #{paths.length}","- DAMAGED: #{states['DAMAGED']}","- merged: #{merged}"]+states.keys.sort.reject { |k| k=='DAMAGED' }.map { |k| "- #{k}: #{states[k]}" }).join("\n")
inventory=proposed.sort_by(&:first).map { |k,t,a,p| "- #{k} | #{t} | #{format('%.1f',a)} | #{p}" }; inventory << "- WATCH: #{watch.length} — #{watch.sort_by(&:first).map(&:first).join(', ')}" unless watch.empty?
values={'GENERATED_AT'=>now_s,'LEDGER_DIR'=>ledger,'RUN_BANNER'=>(errors>0 ? "> **RUN ERRORS: #{errors} — damaged inputs/actions are listed below.**" : ''),'EMPTY_BANNER'=>(paths.empty? ? '> **LEDGER EMPTY — verify vault root.**' : ''),'PENDING_OWNER_ROWS'=>(rows.empty? ? '- None' : rows.join("\n")),'TOTALS_BY_STATE'=>totals,'PROPOSAL_INVENTORY'=>(inventory.empty? ? '- None' : "- topic_key | recommendation | age days | proposer\n"+inventory.join("\n")),'PROTOCOL_AUDIT'=>(audits.empty? ? '- None' : audits.sort.map { |x| "- #{x}" }.join("\n")),'SENSE_BANNER'=>(broken ? '> **SENSE BROKEN — verify sensors and status logging immediately.**' : ''),'SENSE_DETAIL'=>(sense.empty? ? '- No sensor status' : sense.map { |x| "- #{x}" }.join("\n")),'PIPELINE_WARNING'=>(recent.zero? ? '> **PIPELINE QUIET — verify sensors:** zero new sightings/proposals in the last 48h.' : ''),'OVERDUE_AND_ACTIONS'=>((actions+reminders+overdue+near).empty? ? '- None' : (actions+reminders+overdue+near).map { |x| "- #{x}" }.join("\n")),'TRIALING_QUOTAS'=>(quotas.empty? ? '- None' : quotas.keys.sort.map { |k| "- #{k}: #{quotas[k]}/1#{quotas[k]>1 ? ' — VIOLATION' : ''}" }.join("\n"))}
out=File.read(template); values.each { |k,v| out.gsub!("{{#{k}}}",v) }
if dry then puts out
else
  FileUtils.mkdir_p(File.dirname(report)); temp="#{report}.growth-lint.#{$$}"
  begin
    File.open(temp,'w') { |f| f.write(out); f.flush; f.fsync }
    File.rename(temp,report)
    # dir fsync is best-effort; write+rename failures above must stay fatal
    begin File.open(File.dirname(report),File::RDONLY) { |d| d.fsync } rescue SystemCallError; end
    puts "WROTE #{report}"
  rescue => e
    abort "growth-lint: report publication FAILED (#{e.class}: #{e.message}) — previous report at #{report} may be stale"
  ensure File.delete(temp) if File.exist?(temp) end
end
