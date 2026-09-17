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

## Scheduling templates

| launchd label | Schedule | Entrypoint | Dead-man coverage |
|---|---|---|---|
| `com.alpha.self-growth.growth-lint` | Daily at 07:00 host-local (system TZ). The invariant is "after the morning feed pull", not a fixed wall-clock hour — adjust to your deployment's rhythm. | `scripts/run-growth-lint.sh` | File heartbeat always + optional external tool. |
| `com.alpha.self-growth.trial-poll` | Hourly (`StartInterval` 3600) | `scripts/run-trial-poll.sh` | File heartbeat always + optional external tool. |

The plists under `ops/` are templates: replace the `{{HOME}}` placeholder with your absolute home directory before installing (launchd does not expand `$HOME` or `~`), e.g. `sed "s|{{HOME}}|$HOME|g" ops/com.alpha.self-growth.growth-lint.plist > ~/Library/LaunchAgents/com.alpha.self-growth.growth-lint.plist`.

Before `launchctl bootstrap`, run `mkdir -p ~/.claude/logs/self-growth`. launchd opens `StandardOutPath` and `StandardErrorPath` before starting the job and does not create their parent directories.

The timestamped `growth-lint-<ts>.log` and `trial-poll-<ts>.log` files are the authoritative job-output logs. The launchd `.out/.err` captures contain wrapper warnings only. Each wrapper prunes its own timestamped logs older than 30 days.

`growth-lint.sh` has the following exit-code contract (also printed by `--help`):

| Exit | Meaning |
|---|---|
| 0 | Clean: no DAMAGED, sensing OK or not requested. |
| 1 | Lock busy — skipped without writes. |
| 2 | Usage / bad option / bad `--now`. |
| 3 | DAMAGED: damaged records or failed actions (`errors > 0`). |
| 4 | SENSE BROKEN while sensing was requested. |
| 5 | Report publication failed. |
| 127 | Ruby missing. |

The queue report is published atomically before exit 3 or 4; damage takes precedence (exit 3) when both apply, and the report shows both banners. `--dry-run` prints the report to stdout with the same codes. Non-zero health exits include a one-line stderr summary. Standalone lint is sensor-less by default: sensing is requested only when `--sensors` is non-empty after trimming or a non-empty `--sense-status` path is supplied. Without either, the report says `Sensing disabled (no sensors requested)`; the PIPELINE QUIET warning remains independent. The scheduled wrapper keeps `SGL_SENSORS=mine` as its default.

The optional external heartbeat interface is `job-heartbeat <job> ok|fail [--reason R] [--duration-ms N]`, provided by the operator via `SGL_HEARTBEAT_TOOL` (unset by default). The growth-lint wrapper reports `ok` only for child exits 0 and 1. Exit 1 means "cron ran, skipped" and prints `lock busy: skipped (heartbeat ok)`. All other child exits report `fail` with `exit N (<meaning>); see <log basename>` (e.g. `damaged`, `sense-broken`, `report-write-failed`, `usage`). The trial-poll wrapper reports `ok` only for exit 0 and `fail` otherwise. Both wrappers preserve the child's exit status, including signal-derived failures.

By default, an unset or non-executable external tool produces a warning and the wrapper continues. Set `SGL_REQUIRE_HEARTBEAT=1` to enforce it: if the tool is missing, the wrapper prints `run-<job>.sh: heartbeat tool required but missing: <path>` and exits 2 before running the child or any other setup. An executable tool that returns failure produces a warning without changing the child's status.

Both wrappers always attempt to write a file heartbeat after the child finishes, before invoking the optional external tool. The default paths are `$SGL_LOG_DIR/growth-lint.heartbeat` and `$SGL_LOG_DIR/trial-poll.heartbeat`, where `SGL_LOG_DIR` defaults to `~/.claude/logs/self-growth`. Override each job's path with `SGL_HEARTBEAT_FILE`; its parent directory must already exist. The file contains one line, published using a temporary file and atomic rename:

```text
status=<ok|fail> at=<UTC ISO8601Z> exit=<N> duration_ms=<N> reason=<text or ->
```

The file uses the same status as the external heartbeat, including `fail` for damaged vaults. File publication failure warns without masking the child's exit. Logfile setup failure also attempts a `fail` heartbeat (exit 2); earlier preflight failures cannot publish a fresh heartbeat, so the observer must check staleness as well as status.

Install these independent checks in an operator-owned cron/launchd job (adjust paths for overrides). They print an alert for a missing, stale, or failing heartbeat; route that output to your monitoring destination. The checks use Bash 3.2 / BSD `find` compatible syntax. Use a 26-hour window for daily growth-lint:

```sh
f=~/.claude/logs/self-growth/growth-lint.heartbeat; [ -n "$(find "$f" -mmin -1560 2>/dev/null)" ] && grep -q '^status=ok ' "$f" || echo "growth-lint dead or failing: $(cat "$f" 2>/dev/null)"
```

Use a 2-hour window for hourly trial-poll:

```sh
f=~/.claude/logs/self-growth/trial-poll.heartbeat; [ -n "$(find "$f" -mmin -120 2>/dev/null)" ] && grep -q '^status=ok ' "$f" || echo "trial-poll dead or failing: $(cat "$f" 2>/dev/null)"
```

**Migration note:** from this version a damaged vault or broken sensing turns the scheduled job red (exit 3/4, heartbeat fail) — the first night after upgrading, expect alerts if your vault already has damaged records or `sense-status.log` is missing.

`RunAtLoad` is false. If the machine is powered off at fire time, launchd does not run this job later as a catch-up; the watchdog staleness alert is the designed catch.

## Linux / WSL2 scheduling

Linux deployments can use the user-level systemd templates in `ops/`:

- `ops/self-growth-growth-lint.service`
- `ops/self-growth-growth-lint.timer`
- `ops/self-growth-trial-poll.service`
- `ops/self-growth-trial-poll.timer`

The service templates use `%h` for the home directory and intentionally do not set `Environment=PATH`; keep `%h` intact when copying them into `~/.config/systemd/user/`. Optional `SGL_PATH` and `SGL_HEARTBEAT_TOOL` overrides are included as commented `Environment=` examples.

Install and enable them as a user:

```sh
mkdir -p ~/.config/systemd/user
install -m 644 ops/self-growth-*.service ops/self-growth-*.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now self-growth-trial-poll.timer self-growth-growth-lint.timer
loginctl enable-linger "$USER"
```

Enable the timers only. The services intentionally have no `WantedBy=default.target`; the timer `[Install]` sections use `WantedBy=timers.target`.

Use the journal for unit-level visibility:

```sh
journalctl --user -u self-growth-trial-poll.service
journalctl --user -u self-growth-growth-lint.service
```

The journal captures wrapper warnings and unit lifecycle events. The wrappers still write the authoritative timestamped child-output logs under `~/.claude/logs/self-growth/`.

The timer mapping mirrors the launchd schedules: `trial-poll` uses `OnBootSec=1h` plus `OnUnitActiveSec=1h`, and `growth-lint` uses `OnCalendar=*-*-* 07:00:00`. `Persistent=true` is intentionally omitted. If the machine is off at fire time, systemd does not replay the run later by default. Example: a VM that is only up from 09:00 to 18:00 never sees the 07:00 `growth-lint` trigger; the watchdog is the catch. Add `Persistent=true` yourself if you want power-off catch-up semantics.

WSL2 needs systemd enabled before these user timers exist:

```ini
[boot]
systemd=true
```

After changing `/etc/wsl.conf`, restart the distro (for example, `wsl.exe --shutdown` from Windows, then reopen the distro) before running the `systemctl --user` commands above.

For hosts that standardize on cron instead of systemd, start from `ops/cron.sample`. Cron shares the same no-catch-up limitation: if the host is down at fire time, the missed run is skipped.

Keep the vault and engine workspace on a local Linux filesystem such as ext4, including on WSL2. Avoid DrvFs/9p or other host-shared mounts for these paths: the lock and owner-confirmation flows rely on 0700/0600 permissions, directory `fsync`, and `File.link`, all of which are less reliable across cross-OS filesystems.

`SGL_ENGINE_WORKSPACE` selects the workspace that `trial-poll.sh` reconciles trial evidence from (default: `$HOME/claude-workspace/sgl-engine-workspace` — a dedicated workspace initialized with the engine's `loop-init`, separate from any engine checkout). It is read-side only: the enqueue workspace is a mandatory `--workspace` flag on `trial-enqueue.sh` / `council-*.sh` with no environment fallback, and the tick workspace is set in the engine's cron driver (operator-owned deployment config). The three must be kept identical by the operator — they are not linked automatically. The workspace must satisfy the pause contract below. Override the variable explicitly for any isolated deployment.

### Workspace switchover invariant

Moving the workspace means flipping three independently-deployed paths (poll env default, cron driver, operator enqueue convention). Execute in one maintenance window with zero `TRIALING` records in the ledger, in this order: (1) merge and pull the poll checkout, (2) deploy the cron driver pointing at the new workspace with `install -m 755` (the launchd job execs the file directly — the exec bit is load-bearing), (3) pause the retired workspace by creating `<old-workspace>/.caty-agent-harness/DISABLED` so stray enqueues fail closed (`tr-enqueue` exit 3), (4) verify all three paths agree and `loop/.deadman/tick.marker` in the new workspace freshens. Do not deploy the cron driver before the poll checkout is pulled: the reverse order delivers evidence into a workspace the poll does not read, and after 7 days growth-lint force-DLQs the record. The deadman probe watches only the workspace the tick is wired to; it cannot detect an enqueue/tick divergence.

## Integration test

Required by convention rule 2: `tests/test-trial-integration.sh` runs the real `tr-enqueue` and `task-runner.sh` from the pinned `v0.6.0` tag against a temporary workspace. **Status: shipped.** The test clones the local engine repository and never writes to its working tree.

### Workspace pause contract

Initialize every engine workspace before enqueueing with `"$engine/scripts/loop-init" --workspace "$workspace"`. Under the pause contract in `scripts/lib-pause.sh`, `tr-enqueue` exit 3 means the workspace is paused or uninitialized (missing `STATE.md` and/or `loop/`).
