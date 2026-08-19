# Proposal Ledger Specification v0.1

Source of truth for the self-growth proposal ledger: record schema, topic identity,
state machine, and the single-writer protocol. Implements governance rules R1, R2, R9
(+ R5, R11–R14 schema fields) of the engine's
[governance-rules.md](https://github.com/caty-ai/caty-agent-harness/blob/main/docs/governance-rules.md)
(spec of record; the rules were originally drafted on the pre-release engine's private
tracker, issue #26, kept here only as a historical citation).
Tracked by issue #1 of this project's own pre-release private tracker (historical citation).

Data plane (convention seam 4): all ledger DATA lives in the shared family-vault,
never in this repo.

```
family-vault/
  45_ai-systems/self-growth/
    proposals/<topic-key>.md      # one file per proposal (this spec)
    council/<topic-key>/          # council verdict bundles (council issue)
  25_review-pending/
    self-growth-queue.md          # queue report written by growth-lint (visibility issue)
```

## 1. Topic identity (R2)

A proposal's id **is** its topic-key. Feed items are sightings; adoption topics are
subjects. Many feed items → one topic.

```
topic-key = <subject-slug> "__" <vendor-slug> [ "__v" <major> ]
```

Normalization rules (applied in order):

1. Subject = the tool/technique being adopted, not the article title
   (e.g. "Claude Code v2.1.212 permissions hardening" → subject `claude-code`).
2. Lowercase; ASCII; spaces and punctuation → `-`; collapse repeats; trim `-`.
3. Vendor = maintaining org (`anthropic`, `openai`, `aws`, `community` when none).
4. `major` = major version **only when the topic is version-specific** (an engine
   upgrade), omitted for techniques/patterns. A new major version is a NEW topic
   (materially new by definition); minor/patch versions append to the same topic.
5. When unsure, the proposer MUST search `proposals/` for candidate keys
   (`grep -il <subject fragment>`) before minting a new one. Near-miss keys found
   at review time are merged by the writer of record (newer file's events appended
   to the older file; newer file replaced by a one-line `MERGED_INTO: <key>` stub).
   Tooling MUST follow stubs: an intake against a stubbed key is redirected to the
   canonical file (one hop; a stub pointing at a stub or at a missing file is an
   error, not a silent success).
6. `propose.sh` validates key *format* but does not normalize subjects — resolving
   "is this the same topic?" is the caller's job (rule 5). The queue report lists
   keys alphabetically precisely so near-miss forks are visible to a human daily.

Examples:
- `claude-code__anthropic__v2` — Claude Code v2.x update train
- `remote-mcp-gateway-pattern__community` — architecture pattern, no version
- `soniox-stt__soniox` — vendor tool, version-agnostic adoption

## 2. Record schema (R1 + R5/R11/R12/R13/R14)

One Markdown file per proposal: YAML frontmatter = **current state** (mutable, only
by the writer of record), body = **append-only event log**. Same topic-key → same
file; a second sighting appends a `SIGHTING` event, never forks a file.

```yaml
---
topic_key: claude-code__anthropic__v2
title: "Claude Code v2.1.212 permissions & runaway-agent hardening"
state: PROPOSED            # see §3
state_entered_at: 2026-07-20T07:05:00Z  # SLA clock (§3): set on CREATE and on every
                           # state transition; NEVER touched by sightings/suppressions.
                           # growth-lint computes overdue from this field only.
risk_tier: T0              # T0 | T1 | T2 (see below)
identity_critical: false   # governance-R12a: true → council + Sho + agent presentation, ALWAYS
tiebreak: T0               # R14: ambiguity resolves DOWN to this tier (flippable later)
proposer: mine             # slug, [a-z0-9_-] only (tool-validated; injection guard)
executor_agent: ""         # AGENT identity holding the TRIALING quota slot (§5);
                           # REQUIRED (non-empty) for the transition into TRIALING
executor_model: ""         # model identity that runs the trial/adoption (set at TRIALING)
created: 2026-07-20
updated: 2026-07-20
cooldown_until: ""         # set on REJECTED / trial-path EXPIRED; suppresses re-proposal (§5)
retry_count: 0             # council-ordered RETRYs consumed (max 2, §3)
source_items:              # feed sightings (url + date + report ref)
  - url: https://example.com/item
    seen: 2026-07-20
    report: 25_review-pending/2026-07-20-mine-newsfeed-report.md
links:
  trial_bundle: ""         # engine artifacts dir once TRIALING (loop/artifacts/<task-id>/)
  council_verdicts: ""     # council/<topic-key>/
  adoption_entry: ""       # 30_decisions/ entry once ADOPTED
backup_ref: ""             # R5: fresh verified backup BEFORE self-adoption; ADOPTING
                           # entry precondition enforced by the writer entering ADOPTING
effect_metric: ""          # R11: declared BEFORE rollout, e.g. "review turnaround -20%"
report_due: ""             # R11: effect report deadline; growth-lint tracks overdue
reversibility: ""          # R13: QUANTITATIVE rollback criteria, e.g.
                           # "rollback = git revert 1 commit + relink, <10 min, no data loss"
---

## Judgement

One paragraph: why this is worth adopting, and the proposer's recommendation
(ADOPT-NOW / TRIAL / WATCH as judged at intake).

## Events (append-only)

- 2026-07-20T07:05Z alpha PROPOSED — intake from Mine 2026-07-20 report (ADOPT-NOW)
- 2026-07-21T06:40Z alpha SIGHTING — Mine 2026-07-21 report, same topic (+1 source_item)
```

### v2 closure

The v2 record shape is closed at exactly 23 top-level keys:

`schema`, `topic_key`, `title`, `state`, `state_entered_at`, `risk_tier`,
`identity_critical`, `tiebreak`, `proposer`, `executor_agent`, `executor_model`,
`created`, `updated`, `cooldown_until`, `retry_count`, `proposal_attempt`,
`owner_confirmation`, `source_items`, `links`, `backup_ref`, `effect_metric`,
`report_due`, `reversibility`

The `proposal_attempt` field is a nonnegative integer. Attempt 0 is
initialization-only. Every fresh `PENDING_OWNER` transition increments it once and
starts a new pending owner-confirmation mapping.

The `owner_confirmation` mapping is exactly seven keys in this order:

`status`, `assurance`, `reference`, `proposal_digest`, `decision`, `principal`,
`verified_at`

It has two valid forms:

- `pending`: `status: pending`, `assurance: standard`, and the other five fields
  are empty strings.
- `verified`: `status: verified`, `assurance: standard`, and the other five
  fields are populated under their recorded domains.

The state/form matrix is closed:

| State | Allowed form | Rule |
|---|---|---|
| `PROPOSED`, `TRIALING`, `COUNCIL` | pending or verified | preserve incoming; fresh `PENDING_OWNER` increments and resets pending |
| `PENDING_OWNER` | pending only | issuance / consume precondition |
| `ADOPTING`, `ADOPTED`, `WATCH` | verified only | produced / preserved after consumed disposition; `ADOPTED` is terminal governance-only |
| `EXPIRED` | pending only | unconfirmed SLA transition preserves pending |
| `DLQ`, `REJECTED` | pending or verified | preserve across council/SLA or adoption rollback paths |

For one-release compatibility, legacy `PENDING_SHO` is accepted on read in the
record state field and legacy T0 prose artifact/backup bytes until v1.0; all
writes use `PENDING_OWNER`.

Any state/form combination outside this table is damaged and exits 3. The legacy
20-key schema from §9 is closed separately and does not migrate in place to v2;
terminal legacy records remain terminal. `ADOPTED` is governance-only: once a
record reaches it, the v2 issuance path does not re-enter it. `ADOPTED` is not
target-owned `APPLIED`, not a later `reverted` fact, and not metric-backed
`EFFECTIVE`; those are subsequent external facts. If the external evidence is
missing, they remain unknown.

Risk tiers (R13 — criteria must be quantitative, not vibes):
- **T0** — reversible in ≤ 10 minutes by a single mechanical action (revert/uninstall/
  config flip), no shared-state migration, blast radius = one runtime.
- **T1** — reversible but requires coordination (multi-runtime rollout, data
  re-index, cron changes) or blast radius > one runtime.
- **T2** — practically irreversible or identity/memory-touching. `identity_critical:
  true` forces T2 routing regardless of mechanical reversibility (governance-R12a);
  tooling MUST clamp `risk_tier` to T2 whenever `identity_critical: true` — a record
  with `identity_critical: true, risk_tier: T0|T1` is invalid. This clamp is unaffected
  by the governance v1.1 amendment (the engine's `docs/governance-rules.md`): the only exemption
  is the persona growth-overlay lane (governance-R12b, rendered phrase data only),
  which is outside sgl; **the sgl approval flow is unchanged**.
- Ambiguity resolves DOWN to the `tiebreak` tier (R14; default T0 — but note the
  arrow: unclear-if-T1 becomes T0 only while `tiebreak: T0` stands; Sho may flip the
  default to T1 later, per-proposal values are never edited retroactively).

Event log line format (grep-parseable, one line per event):

```
- <ISO8601Z> <actor> <EVENT|FROM→TO> — <rationale / evidence link>
```

## 3. State machine (R9)

```
                       ┌────────── RETRY (≤2, council-ordered) ──────────┐
                       ▼                                                 │
PROPOSED ──► TRIALING ──► COUNCIL ──► PENDING_OWNER ──► ADOPTING ──► ADOPTED
   │             │           │             │              │
   │ 14d         │ 7d        │ 3d          │ 30d          │ 7d
   ▼             ▼           ▼             ▼              ▼
 EXPIRED        DLQ         DLQ         EXPIRED          DLQ

 WATCH (parking) ──► PROPOSED   only on materially-new (§4)
 any non-terminal except ADOPTING ──► REJECTED  (council NO-GO or Sho veto)
 any non-terminal except ADOPTING ──► WATCH     (council/Sho "not now")
 ADOPTING exits ONLY to ADOPTED or DLQ — a started rollout is never parked or
 rejected directly; abort = ADOPTING → DLQ, which mandates the rollback evaluation
 below. (Closes the half-applied-rollout bypass.)
```

| State | Meaning | Owner (advances it) | Timeout | Timeout → |
|---|---|---|---|---|
| PROPOSED | Intake done, awaiting trial slot (quota §5) | Alpha (writer of record) | 14 d | EXPIRED |
| TRIALING | Engine task enqueued via `tr-enqueue`; trial running | Assigned agent (result via Task Packet); Alpha records | 7 d | DLQ (zombie trial) |
| COUNCIL | Cross-model verdict in progress | Alpha (council runner) | 3 d | DLQ |
| PENDING_OWNER | Human gate; surfaced in queue report §top | **Sho** | 30 d | EXPIRED **without cooldown** (council work is preserved; growth-lint re-surfaces a reminder at 14 d before expiry; re-entry needs only a human bump, not the full §4 test) |
| ADOPTING | Approved; executing rollout. **Precondition: `backup_ref` non-empty (R5) and `effect_metric`+`report_due` set (R11)** | Alpha | 7 d | DLQ |
| WATCH | Parked; not in any quota | growth-lint (re-entry check only) | none | — |
| ADOPTED / REJECTED / EXPIRED / DLQ | Terminal | — | — | — |

Rules:
- **RETRY**: COUNCIL may order → TRIALING with revised instructions, at most **2**
  retries per proposal (`retry_count` frontmatter counter, incremented on each
  RETRY); the 3rd NO-GO is REJECTED.
- **Timeout transitions are executed by growth-lint** (the only writer besides the
  writer runtime, §6) and always leave an event line naming the SLA that fired.
- DLQ is a terminal *for the record*, not for the topic: un-DLQ = a fresh PROPOSED
  event on the same file after human review (Sho, or Alpha with rationale; §4
  human-bump). `propose.sh` treats DLQ like REJECTED for intake: sightings are
  suppressed-but-traced, re-entry requires `--materially-new`.
- **ADOPTING → DLQ always triggers a rollback evaluation**: growth-lint opens the
  DLQ event with `rollback_required` naming the declared `reversibility` action;
  Alpha executes or explicitly waives it (event line either way) — a half-applied
  rollout must never be parked silently. Rollback executed → REJECTED with a
  `rolled back` event instead of remaining DLQ.
- **TRIALING → WATCH/DLQ must name the engine task**: the transition event MUST
  contain `task <task-id> aborted` or `task <task-id> abandoned to engine DLQ`.
  Quota (§5) is counted on **current state only** (state=TRIALING occupies the
  `executor_agent` slot; any transition out frees it); a transition event missing
  the task token is a protocol violation that growth-lint surfaces in the queue
  report until an amending event is appended.
- **SLA clock** (§2 `state_entered_at`): every transition sets `state_entered_at`
  to the transition timestamp. Sightings, suppressions, and flags never touch it.
  If `state_entered_at` is missing/malformed, growth-lint treats the record as
  **overdue now** and reports it as damaged (fail-visible, never fail-fresh).
- `ADOPTED` closes the governance loop only. The separate R11 effect-report
  obligation starts from the ADOPTING→ADOPTED event. Owner of the report = the
  actor recorded on that event (default Alpha). growth-lint flags `report_due`
  overdue in the queue report; at 14 d overdue it appends an `effect report
  overdue — escalated to Sho` event and pins the item in the pending-Sho section
  until an `EFFECT_REPORT` event (or a `SHO_WAIVER` event) lands. Until then,
  `EFFECTIVE` is unproven, and missing external application/reversion facts stay
  unknown.

## 4. Materially-new test (re-entry & suppression override)

A topic in REJECTED / EXPIRED / DLQ / WATCH / cooldown can move forward again on
exactly three grounds, with two distinct destinations:

1. **Version change** → **NEW topic-key** (never same-file re-entry): a new major
   version is a new topic per §1. The tool call carries `--supersedes <old-key>`;
   it creates `<subject>__<vendor>__v<N>.md` and appends a `SUPERSEDED_BY <new-key>`
   event to the old file (state of the old file unchanged).
2. **Security fix** → same-file re-entry: the sighting addresses a vulnerability
   affecting our stack. `--evidence <advisory-url>` is REQUIRED and recorded.
3. **Human bump** → same-file re-entry: Sho (or an agent relaying Sho) explicitly
   asks. `--evidence <ref>` is REQUIRED — provenance only, a pointer to where Sho
   said so (message, issue, packet). It never satisfies owner disposition
   authorization by itself; the caller still owns that obligation. A human-bump
   event with a dangling evidence ref is a protocol violation surfaced by
   growth-lint.

Everything else is a SIGHTING append (source_items grows; state unchanged).
A same-file re-entry records a **PROPOSED** event (rationale:
`re-entry (<reason>) evidence <ref> via <url>`), sets `state_entered_at`, and MUST
append the triggering sighting to `source_items`. **Re-entry from DLQ is a
destructive rewrite per §6**: the tool takes the tar backup first and records the
backup path in the event line.
ADOPTED topics never re-enter; a new sighting appends an "already adopted, vN" note
event — visible in the queue report as confirmation the loop closed correctly.

## 5. Anti-#11 consultation rule + quotas

Before creating any proposal, the proposer (or Alpha ingesting a report) MUST:

1. Resolve the topic-key (§1) and check `proposals/<topic-key>.md`.
2. If it exists: append SIGHTING (or invoke §4 if claiming materially-new).
3. If `state ∈ {REJECTED, EXPIRED, DLQ}` or `cooldown_until` is in the future:
   suppress (no new proposal, sighting traced) unless §4 passes. Default cooldown on
   REJECTED and trial-path EXPIRED: **30 d**. PENDING_OWNER-path EXPIRED carries **no
   cooldown** (§3) — a human bump alone re-enters it.
4. If `state = ADOPTED`: append the already-adopted note event, never re-propose.

Quotas (enforced at transition time by the writer of record; surfaced by growth-lint):
- Max **1 concurrent TRIALING per agent** — counted over records with current
  `state: TRIALING`, keyed by `executor_agent` (§2; non-empty required to enter
  TRIALING).
- Max **3 proposals entering TRIALING per week** family-wide (throughput guard; the
  rest queue in PROPOSED ordered by proposer priority then age).

## 6. Single-writer protocol (R9)

- **Writer of record = the writer runtime** (the operator's designated writer host,
  see INTEGRATION.md). All frontmatter mutations and event appends go through
  `scripts/propose.sh` / future transition tooling run by Alpha.
- **Other agents never write ledger files.** They submit proposals and trial results
  via the proven Task Packet round-trip (vault `25_review-pending/` packets) or via
  morning reports; Alpha ingests.
- **growth-lint is the only second writer**, restricted to: timeout transitions
  (§3), overdue flags, and WATCH re-entry checks. Nothing else. **growth-lint is
  bound by the same lock protocol below** — any writer that touches a ledger file
  without holding the lock violates this spec.
- Concurrency guard (belt & braces even with one writer): writers take
  `mkdir proposals/.lock` before create-or-append and write an `owner` file inside
  it (`<pid> <host> <tool>`), release on exit. A lock older than 5 min may be
  broken only after a liveness check on the recorded pid (same host); breaking it
  is logged in the tool output. **Single-host assumption**: the ledger is written
  only from the writer-of-record host (the writer runtime + growth-lint cron).
  Cross-host writes (e.g. a remote agent) are out of contract until a shared-lock
  design lands — remote agents always go through the Task Packet route.
- The vault is append-type and not under git: **before any destructive ledger
  operation (merge per §1.5, un-DLQ rewrite), tar-backup the `self-growth/` dir**
  (standing family-vault rule) and record the backup path in the event line.

## 7. Intake sources (v0.1)

- Mine morning newsfeed reports (`25_review-pending/YYYY-MM-DD-mine-newsfeed-report.md`),
  sections ADOPT-NOW / TRIAL / WATCH → initial states PROPOSED / PROPOSED / WATCH
  (ADOPT-NOW is a proposer recommendation, not a state — everything walks the same
  machine; the recommendation lives in Judgement and orders the PROPOSED queue).
- Ad-hoc proposals from any family agent via Task Packet.

### Sensor status contract

Sensors append one line for each run to
`45_ai-systems/self-growth/sense-status.log` in the vault:
`<ISO8601Z> <sensor> <OK|FAIL> <detail>`. `growth-lint` reads the latest line for
each sensor and makes a missing, stale (over 36 hours), or failed status
fail-visible in the review queue.

## 8. Out of scope here

Trial bundle format (trial issue), council verdict format (council issue), queue
report format (visibility issue). This spec only fixes the fields they hang off
(`links.*`, states).
