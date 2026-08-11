# Trial Packet: {{TITLE}}

- Topic: `{{TOPIC_KEY}}`
- Engine task: `{{TASK_ID}}`
- Created: `{{CREATED_AT}}`

## Rubric

Read and evaluate these success criteria before taking any action:

{{RUBRIC}}

Do not begin the trial until every criterion is measurable or explicitly marked
`QUALITATIVE-ONLY` because quantification is impossible.

## Risk tier and reversibility

- Risk tier: `{{RISK_TIER}}`
- Reversibility: {{REVERSIBILITY}}

T0 means rollback takes at most 10 minutes, requires one mechanical action, loses
no data, and affects one runtime. T1 means rollback is still possible but requires
coordination or affects more than one runtime. T2 means the change is practically
irreversible or touches identity or memory. Prefer a quantitative statement such
as `rollback = git revert 1 commit, <10 min, no data loss`. If quantification is
impossible, flag the criterion `QUALITATIVE-ONLY` and explain why.

## Identity-critical check

- Identity critical: `{{IDENTITY_CRITICAL}}`
- Sho pre-approved: `{{SHO_APPROVED}}`

Any change to an agent memory store or persona configuration requires council
review and Sho approval regardless of its mechanical risk tier.

## Isolation level

- Required isolation: `{{ISOLATION_LEVEL}}`
- Contract: `docs/trial-isolation.md`

Apply the runtime-specific isolation controls before executing the trial.

## Budget

- Time: `{{TIME_BUDGET_MIN}} minutes`
- Steps: `{{STEP_BUDGET}}`
- Cost: `{{COST_BUDGET}}`

Stop and escalate before exceeding any budget.

## Executor

- Agent: `{{EXECUTOR_AGENT}}`
- Model: `{{EXECUTOR_MODEL}}`

The council evaluator must not be the same identity as this executor.

## Concurrent-session conflict check

Before workspace-level changes, verify that no other agent or session is using the
same checkout. Record the command or observation used and its result in the trial
bundle. Do not proceed while a conflicting session is active.

## Artifact bundle contract

Write the complete bundle under `$ARTIFACT_DIR/out/bundle/`:

- [ ] `run.log` — raw execution logs
- [ ] `env-manifest.txt` — environment and dependency/version manifest
- [ ] `config-diff.txt` — configuration diff, or an explicit no-change statement
- [ ] `permissions.md` — permissions requested, or an explicit none statement
- [ ] `cost.txt` — actual cost
- [ ] `attempts.md` — failed attempts, or an explicit none statement
- [ ] `repro.md` — reproduction steps
- [ ] `rollback-test.md` — rollback test result

Every file must be non-empty. Do not include credentials, secrets, private keys,
or credential-bearing environment values in the packet or bundle.
