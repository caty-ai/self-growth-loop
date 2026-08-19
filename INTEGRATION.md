# INTEGRATION.md — engine seam declaration

Per [plugin-convention.md](https://github.com/caty-ai/caty-agent-harness/blob/main/docs/plugin-convention.md) rule 4 (dual bookkeeping). The matching registry entry lives in the engine repo's `docs/plugins.md`.

## Engine pin

```
HARNESS_VERSION=v0.6.0
```

Tag lineage: `v1.2.0` was the numbering of the engine's private pre-release predecessor; caty-agent-harness is a fresh public history whose tags restarted at `v0.x`.

Re-verify (run the integration test below) before deploying against any newer engine tag.

## Seams used

| Seam | Usage |
|---|---|
| 1. Enqueue (`scripts/tr-enqueue`) | Active: `scripts/trial-enqueue.sh` emits one task bundle per approved TRIAL with an embedded donecheck. Task ids use `sgl-trial-<validated-topic-key>-<YYYYMMDD>t<HHMMSS>`. |
| 2. Results (read-only) | `scripts/trial-poll.sh` verifies `loop/artifacts/<task-id>/state.json` against `loop/tasks/{delivered,dlq}/` before advancing TRIALING → COUNCIL/DLQ. `growth-lint` detects trial zombies. |
| 3. Templates | Task files rendered against `templates/TASK.tmpl.md` of the pinned tag. |
| 4. Data plane | Proposal ledger + council verdicts + queue report live in family-vault (`25_review-pending/`, ledger dir per the ledger spec). The engine never reads this. |

## Target runtimes

- Writer of record: the operator's designated writer host — `trial-enqueue.sh` and `trial-poll.sh` execute their ledger transitions there, and only there (single-writer protocol, see the ledger spec).
- Second authorized transition executor: `growth-lint` (timeout transitions only).
- Proposers: reporting agents via Task Packet round-trip — no direct ledger writes.

## Cron entries

| launchd label | Schedule | Entrypoint | Dead-man coverage |
|---|---|---|---|
| `com.alpha.self-growth.growth-lint` | Daily at 07:00 host-local (system TZ). The invariant is "after the morning feed pull", not a fixed wall-clock hour — adjust to your deployment's rhythm. | `scripts/run-growth-lint.sh` | Dead-man jobs framework (private infrastructure): heartbeat `self-growth-lint.json` via `job-heartbeat`, watched by an external watchdog. Optional — the loop degrades to manual log checks without it. |
| `com.alpha.self-growth.trial-poll` | Hourly (`StartInterval` 3600) | `scripts/run-trial-poll.sh` | Heartbeat `self-growth-trial-poll` via `job-heartbeat`. Watchdog manifest registration follows the first live enqueue. |

The plists under `ops/` are templates: replace the `{{HOME}}` placeholder with your absolute home directory before installing (launchd does not expand `$HOME` or `~`), e.g. `sed "s|{{HOME}}|$HOME|g" ops/com.alpha.self-growth.growth-lint.plist > ~/Library/LaunchAgents/com.alpha.self-growth.growth-lint.plist`.

Before `launchctl bootstrap`, run `mkdir -p ~/.claude/logs/self-growth`. launchd opens `StandardOutPath` and `StandardErrorPath` before starting the job and does not create their parent directories.

The timestamped `growth-lint-<ts>.log` and `trial-poll-<ts>.log` files are the authoritative job-output logs. The launchd `.out/.err` captures contain wrapper warnings only. Each wrapper prunes its own timestamped logs older than 30 days.

The pinned heartbeat interface is `job-heartbeat <job> ok|fail [--reason R] [--duration-ms N]` (provided by the operator's private monitoring infrastructure; path supplied via `SGL_HEARTBEAT_TOOL`, unset by default — e.g. an `EnvironmentVariables` entry in the installed plist. When the tool is absent the wrappers log a warning and continue — see the `[ -x "$heartbeat_tool" ]` guards in `scripts/run-*.sh`). A skipped run caused by lint exit 1 (lock busy) reports `ok`, because the dead-man contract records that cron ran, while the wrapper still returns exit 1.

`RunAtLoad` is false. If the machine is powered off at fire time, launchd does not run this job later as a catch-up; the watchdog staleness alert is the designed catch.

`SGL_ENGINE_WORKSPACE` selects the workspace that `trial-poll.sh` reconciles trial evidence from (default: `$HOME/claude-workspace/sgl-engine-workspace` — a dedicated workspace initialized with the engine's `loop-init`, separate from any engine checkout). It is read-side only: the enqueue workspace is a mandatory `--workspace` flag on `trial-enqueue.sh` / `council-*.sh` with no environment fallback, and the tick workspace is set in the engine's cron driver (operator-owned deployment config). The three must be kept identical by the operator — they are not linked automatically. The workspace must satisfy the pause contract below. Override the variable explicitly for any isolated deployment.

### Workspace switchover invariant

Moving the workspace means flipping three independently-deployed paths (poll env default, cron driver, operator enqueue convention). Execute in one maintenance window with zero `TRIALING` records in the ledger, in this order: (1) merge and pull the poll checkout, (2) deploy the cron driver pointing at the new workspace with `install -m 755` (the launchd job execs the file directly — the exec bit is load-bearing), (3) pause the retired workspace by creating `<old-workspace>/.caty-agent-harness/DISABLED` so stray enqueues fail closed (`tr-enqueue` exit 3), (4) verify all three paths agree and `loop/.deadman/tick.marker` in the new workspace freshens. Do not deploy the cron driver before the poll checkout is pulled: the reverse order delivers evidence into a workspace the poll does not read, and after 7 days growth-lint force-DLQs the record. The deadman probe watches only the workspace the tick is wired to; it cannot detect an enqueue/tick divergence.

## Integration test

Required by convention rule 2: `tests/test-trial-integration.sh` runs the real `tr-enqueue` and `task-runner.sh` from the pinned `v0.6.0` tag against a temporary workspace. **Status: shipped.** The test clones the local engine repository and never writes to its working tree.

### Workspace pause contract

Initialize every engine workspace before enqueueing with `"$engine/scripts/loop-init" --workspace "$workspace"`. Under the pause contract in `scripts/lib-pause.sh`, `tr-enqueue` exit 3 means the workspace is paused or uninitialized (missing `STATE.md` and/or `loop/`).
