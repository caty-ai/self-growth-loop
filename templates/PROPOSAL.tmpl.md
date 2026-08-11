---
schema: sgl-proposal/v2
topic_key: {{TOPIC_KEY}}
title: {{TITLE}}
state: {{STATE}}
state_entered_at: {{TIMESTAMP}}
risk_tier: {{RISK_TIER}}
identity_critical: {{IDENTITY_CRITICAL}}
tiebreak: T0
proposer: {{PROPOSER}}
executor_agent: ""
executor_model: ""
created: {{DATE}}
updated: {{DATE}}
cooldown_until: ""
retry_count: 0
proposal_attempt: 0
owner_confirmation:
  status: pending
  assurance: standard
  reference: ""
  proposal_digest: ""
  decision: ""
  principal: ""
  verified_at: ""
source_items:
  - url: {{SOURCE_URL}}
    seen: {{DATE}}
    report: {{SOURCE_REPORT}}
links:
  trial_bundle: ""
  council_verdicts: ""
  adoption_entry: ""
backup_ref: ""
effect_metric: ""
report_due: ""
reversibility: {{REVERSIBILITY}}
---

## Judgement

{{JUDGEMENT}}

## Events (append-only)

- {{TIMESTAMP}} {{ACTOR}} {{STATE}} — {{RATIONALE}}
