# Adoption Wiring

This document covers the owner bootstrap, issuance boundary, queue wording, consume verbs, lint tokens, reconcile/restore flow, and the shared proposal lock. It does not describe provider adapters or any bypass path.

## Gate Mechanics

`PENDING_OWNER` records appear as decision cards in the self-growth queue. Sho
approves, rejects, or parks them through the morning reply or a vault append;
there is no new approval channel. The human gate always applies, including the
T0 council-skip path. After 30 days the record becomes `EXPIRED` without
cooldown; a human bump re-enters it.

The owning runtime applies its own rollout, records the applied diff, and
re-runs the trial smoke rubric. `ADOPTED` is governance-only here: it means the
owner disposition was consumed and the rollout obligation was accepted. It does
not by itself prove target-owned `APPLIED`, a later `reverted` fact, or
metric-backed `EFFECTIVE`. Those are subsequent external facts recorded
separately; when that evidence is absent, they remain unknown.

## Normative Tier Table

This is the single normative tier summary. Operational details remain in
[trial-isolation.md](trial-isolation.md) and
[council-wiring.md](council-wiring.md).

| Tier | Isolation | Council quorum | Human gate |
|---|---|---|---|
| T0 | Dedicated worktree or disposable scratch directory | Panel skipped; sealed `sgl-t0-skip/v1` artifact + `auto-adopt path (T0), council skipped` transition | Sho always |
| T1 | Worktree/scratch; tool/SDK/MCP trials add secrets-clean environment | Closed 3-seat ballot; GO >= 2 | Sho always |
| T2 | Production data/paid work blocked until the collection-controls prerequisite is closed and Sho trial-plan approval | Closed 3-seat ballot; GO >= 2 and security GO; security NO-GO veto | Sho always |

T0 council skipping never bypasses Sho. `identity_critical: true` records are
never T0 here: tooling clamps them to T2, so a T0+identity-critical record is
damaged.

## Owner Bootstrap

The owner config is operator-created at `45_ai-systems/self-growth/config/owner.yaml`.

It is read by `scripts/lib-owner-confirmation.rb` and never created or modified by the adoption commands. The file is a strict four-line UTF-8 YAML subset with exactly these keys in this order: `schema`, `principal`, `repository_id`, `default_assurance`.

The implementation fails closed on:

- `owner-config-format-invalid`
- `owner-config-schema-unsupported`
- `owner-config-principal-invalid`
- `owner-config-repository-id-invalid`
- `owner-config-assurance-invalid`
- `unimplemented-assurance`

## Issuance Boundary

`scripts/adopt-confirm.sh` is the issuance surface. Phase A classifies the current artifact first. If the artifact is present and unexpired with an identical snapshot, the script returns the same authorization reference and consume command without opening `/dev/tty`.

Only the missing-artifact or expired-replacement branch prompts for operator confirmation. The TTY check is an operational intent checkpoint, not human-presence proof, and it does not add resistance against a caller with the same authority.

The output labels are exact:

- `Authorization reference: ...`
- `Consume command: ...`

Do not reconstruct the consume command from stale fields. Use the printed command as-is.

## Queue Surface

`growth-lint` renders exactly three non-executable owner-disposition templates:

- `GO`
- `REJECT`
- `WATCH`

When a current authorization artifact exists, the queue replaces those templates with:

- `CURRENT — supersedes any previously printed reference for this attempt`
- `Consume-by: ...`

The queue does not carry raw disposition values or the exact consume command. It shows only the current reference and consume-by timestamp. Retain the command from issuance, or regenerate it by rerunning `adopt-confirm.sh` with the identical raw values; do not source it from the queue.

The consume verbs map one-to-one to the scripts:

- `GO` -> `scripts/adopt-approve.sh`
- `REJECT` -> `scripts/adopt-reject.sh`
- `WATCH` -> `scripts/adopt-watch.sh`

The `GO` consume path requires `--backup-ref`, `--effect-metric`, and `--report-due`.
The `REJECT` and `WATCH` consume paths require `--reason`.
All three require `--authorization-ref`.

The same consume command is retry-safe only when the current artifact and target state still match. Otherwise the worker fails closed with:

- `authorization-reference-stale`
- `authorization-artifact-missing`
- `authorization-artifact-expired`
- `authorization-target-state-changed`

## Lint Tokens

Owner-config failures block issuance. Consume-only staleness is separate and never means the bootstrap file is wrong.

The lint/status path emits only:

- `authorization-reference-unknown`
- `authorization-artifact-missing`

The consume path alone uses the stale/expired/target-changed tokens:

- `authorization-reference-stale`
- `authorization-artifact-expired`
- `authorization-target-state-changed`

## Reconcile And Restore

`scripts/adopt-reconcile.sh` supports two modes:

- reconcile / migrate: `--vault <root> --topic <key> [--workspace <root>] [--now <ISO8601Z>]`
- restore: `--vault <root> --topic <key> --restore-backup <vault-relative path>`

`--workspace` is only valid for legacy T0 `PENDING_OWNER` reconciliation. It is rejected everywhere else, and it is incompatible with `--restore-backup`.

The legacy T0 path reads the exact workspace root and the exact sealed T0 artifact. The live workspace is only consulted during that legacy T0 migration/recovery path.
Legacy T0 repair is exact-form only: restore the sealed `sgl-t0-skip/v1` block
or rerun that one-time reconcile path against the exact workspace root. Do not
reconstruct the skip artifact from the live workspace or paraphrase the legacy
prose note.

Reconcile backups are written under `45_ai-systems/self-growth/backups/` as `reconcile-<stamp>-<topic>.tar.gz`.
Partial temp backups fail visibly with `stale-reconcile-temp`.
Legacy terminal states refuse reconciliation with `legacy-terminal-reconcile-unsupported`.

## Intentional False Positives

The reconcile path intentionally treats these substrings as forbidden in legacy event payloads:

- `proposal_attempt`
- `owner_confirmation`
- `proposal-digest`
- `authorization-ref`

That check is conservative by design. If a legacy event text triggers it, stop and inspect the exact historical event path with operator-owned remediation evidence. Do not advise casual event editing, and do not relax, bypass, or auto-migrate around the scan.

## Shared Lock

All adoption verbs share `45_ai-systems/self-growth/proposals/.lock`.

The lock helper validates the process identity before acquisition. If the pid, host, or tool token is malformed, the command fails with `lock-identity-invalid` before it tries `mkdir`.

The acquire path retries once immediately and then nine more times at 0.5-second intervals. If it still cannot hold the lock, it fails with `proposal-lock-busy`.
For the frozen `growth-lint` heartbeat compatibility path, shared-lock busy
remains exit 1 with the exact skipped-without-writes message
`run-growth-lint.sh: lock busy: skipped (heartbeat ok)`. By contrast,
`lock-quarantine-conflict` remains a fail-closed exit 3. Unequal legacy/shared
hostname tokens fail safe by leaving the lock busy rather than treating the
owner as breakable.

Stale owner directories may be quarantined. A changed-owner quarantine is renamed to the exact preserved path `.quarantine-changed.<pid>.<attempt>` and left visible to the operator. Inspect that exact path and the successor `.lock` path directly; prove the recorded PID is not live on the recorded host before removing anything. Never glob or bulk-delete quarantine artifacts. The helper only removes the directory it still owns; otherwise it fails closed with `lock-quarantine-conflict`.

Do not describe the lock as a generic mutex. The token names matter:

- `lock-identity-invalid`
- `proposal-lock-busy`
- `lock-quarantine-conflict`
