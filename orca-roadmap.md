# Orca Redesign Implementation Roadmap

This roadmap translates `orca-redesign.md` into an implementation sequence with clear milestones, dependencies, and acceptance criteria.

## Outcomes

By the end of this roadmap, Orca should have:

1. A strict split between mandatory coordination context and optional operational knowledge.
2. Mechanical enforcement of correctness invariants (not prompt-only guidance).
3. Role-specific prompts for worker/inspector/librarian workflows.
4. A usable knowledge lifecycle (append, discover, curate).
5. Instrumentation that supports future A/B testing and harness evolution.

## Milestone Plan

## M0. Baseline + Prerequisites (Week 1)

Status: Completed on February 25, 2026 (commit `0204648`).

Goal: lock in observability and compatibility before behavior changes.

Deliverables:

1. Add `harness_version` to `agent-logs/metrics.jsonl` rows (`git describe --always --dirty`).
2. Add strict run-summary schema validation in `agent-loop.sh` for required fields:
   - `issue_id` (string)
   - `result` (`completed|blocked|no_work|failed`)
   - `issue_status` (string)
   - `merged` (boolean)
   - `discovery_ids` (array of strings)
   - `discovery_count` (int, equals `discovery_ids` length)
   - `loop_action` (`continue|stop`)
   - `loop_action_reason` (string)
   - `notes` (string)
3. Add explicit `summary_schema_status` and reason codes to metrics rows.
4. Add a short migration note in Orca docs describing upcoming prompt split.

Primary files:

- `scripts/orca/agent-loop.sh`
- `scripts/orca/status.sh`
- `scripts/orca/README.md`

Exit criteria:

1. Completed: new runs write `harness_version`.
2. Completed: invalid summaries are marked with deterministic reason codes.
3. Completed: `orca status` works on mixed old/new metrics rows.
4. Completed: no regression in start/stop/status flow.

---

## M1. Mandatory vs Optional Context Split (Week 2)

Goal: make coordination protocol minimal/authoritative and move operational guidance out.

Deliverables:

1. Create worker mandatory prompt (new `scripts/orca/AGENTS.md` for Orca worker role).
2. Convert current `AGENT_PROMPT.md` into:
   - mandatory protocol content in `scripts/orca/AGENTS.md`
   - optional guidance in `scripts/orca/knowledge/` docs.
3. Create knowledge index and starter docs:
   - `scripts/orca/knowledge/INDEX.md`
   - `scripts/orca/knowledge/workflow.md`
   - `scripts/orca/knowledge/tools.md`
   - `scripts/orca/knowledge/pitfalls.md`
4. Ensure mandatory prompt explicitly points agents to `knowledge/`.
5. Keep existing discovery logging flow compatible during migration window.

Primary files:

- `scripts/orca/AGENT_PROMPT.md` (shrink or redirect)
- `scripts/orca/agent-loop.sh`
- `scripts/orca/knowledge/*`

Exit criteria:

1. Mandatory prompt fits roughly one screen and contains only invariants + pointers.
2. Worker runs still complete end-to-end with no extra operator steps.
3. Prompt/docs clearly define temporary coexistence of discovery logs and `knowledge/`.

---

## M1.5 Knowledge Ingestion + Read Path (Week 3)

Goal: ensure the knowledge base is actually used, not just written.

Deliverables:

1. Define migration from run discovery logs to `knowledge/` append entries:
   - keep run-local discovery logs for traceability
   - append distilled lessons to `knowledge/` post-run.
2. Add a lightweight read-path mechanism for optional context:
   - pre-run knowledge hint selection by issue keywords or tags, or
   - explicit worker step requiring at least one relevant `knowledge/` read.
3. Add observability for knowledge usage:
   - metric field(s) for knowledge reads and knowledge appends
   - `status.sh` surface for recent knowledge usage.
4. Document failure mode from redesign Risk 1 and mitigation options.

Primary files:

- `scripts/orca/agent-loop.sh`
- `scripts/orca/AGENTS.md`
- `scripts/orca/knowledge/*`
- `scripts/orca/status.sh`
- `scripts/orca/README.md`

Exit criteria:

1. At least one concrete read-path mechanism is implemented and measurable.
2. Workers can append distilled knowledge without losing run-local trace logs.
3. Operator can see whether knowledge is being read in recent runs.

---

## M2. Enforce Harness Invariants in Code (Weeks 4-5)

Goal: correctness requirements become impossible (or hard) to skip.

Deliverables:

1. Add enforcement telemetry hooks needed for invariant checks:
   - lock-evidence signal from lock-guarded merge step
   - claim-evidence signal linked to run issue id.
2. Enforce merge lock usage before accepting a run as `completed`.
3. Enforce claim-before-coding:
   - run must include a claimed issue id
   - run cannot close/merge unclaimed issue work.
4. Add explicit run failure reasons for invariant violations.
5. Build and run a script-level invariant test harness (happy path + failure modes).

Primary files:

- `scripts/orca/agent-loop.sh`
- `scripts/orca/with-lock.sh`
- `scripts/orca/check-closed-deps-merged.sh`
- `tests/orca/*` (or equivalent Orca script test harness)

Exit criteria:

1. A run that skips lock usage is rejected.
2. A run that skips claiming is rejected.
3. Failures are visible in logs/metrics with actionable reason codes.
4. Invariant tests simulate and verify skip-lock and skip-claim failures.

---

## M3. Role Prompts and Invocation Surface (Week 6)

Goal: support inspector and librarian workflows without adding a dashboard.

Deliverables:

1. Add role prompt templates:
   - `scripts/orca/prompts/worker.md`
   - `scripts/orca/prompts/inspector-status.md`
   - `scripts/orca/prompts/inspector-review.md`
   - `scripts/orca/prompts/inspector-steer.md`
   - `scripts/orca/prompts/librarian.md`
2. Add lightweight invocation support (`orca` subcommand or documented command recipes).
3. Encode inspector-steer write boundary (`open` issues only; no edits to `in_progress`).

Primary files:

- `scripts/orca/orca.sh`
- `scripts/orca/README.md`
- `scripts/orca/OPERATOR_GUIDE.md`
- `scripts/orca/prompts/*`

Exit criteria:

1. Each role can be run with one command and clear inputs.
2. Read/write boundaries are documented and testable.
3. Worker loop behavior remains unchanged unless explicitly using non-worker roles.

---

## M4. Knowledge Lifecycle + Librarian Triggers (Week 7)

Goal: make knowledge base operational, not just a folder.

Deliverables:

1. Append protocol for workers (entries include date, issue id, concise lesson).
2. `INDEX.md` append-only guard for worker runs.
3. Trigger logic for librarian suggestion:
   - size threshold (lines/files/entries)
   - optional periodic fallback.
4. Implement threshold computation and expose it in `status.sh` output.
5. Define relationship between discovery log artifacts and curated `knowledge/` state.
6. Add docs for curation workflow and rollback expectations.

Primary files:

- `scripts/orca/knowledge/*`
- `scripts/orca/status.sh` (surface trigger signal)
- `scripts/orca/README.md`

Exit criteria:

1. Workers append knowledge entries without merge pain.
2. Librarian trigger appears when threshold exceeded.
3. `orca status` reports knowledge trigger state and threshold values.
4. Knowledge edits are auditable and easy to revert via Git.

---

## M5. Self-Improvement Suggestion Loop (Week 8)

Goal: capture harness friction systematically.

Deliverables:

1. Standardize `harness-improvement` issue creation format.
2. Update worker instructions to explicitly create these issues when friction appears.
3. Add one canonical operator command for review (for example `bd list --type harness-improvement` or `./bb orca improvements`).
4. Document the review workflow and triage labels/states.

Primary files:

- `scripts/orca/AGENTS.md` or worker prompt
- `scripts/orca/README.md`

Exit criteria:

1. Agents can file harness-improvement issues consistently.
2. Operator can review them with one command.
3. Examples exist in docs.

---

## M6. Artifact Quality Gates (Week 9)

Goal: protect inspector/librarian usefulness from summary quality drift.

Deliverables:

1. Add summary semantic minimums (attempted, succeeded, failed/blocked, next step).
2. Add validation feedback in run logs when summary quality is insufficient.
3. Add simple quality metric to `metrics.jsonl` (pass/fail and reason).

Primary files:

- `scripts/orca/agent-loop.sh`
- `scripts/orca/status.sh`

Exit criteria:

1. Low-quality summaries are detectable at run time.
2. Status output can show quality trends.
3. No false-positive flood in normal operation.

---

## M7. Evaluation Foundations (Future Track, Weeks 10+)

Goal: enable principled A/B comparisons before autonomous promotion.

Deliverables:

1. `orca snapshot` / `orca restore-snapshot` design + prototype.
2. Dry-run isolation mode for comparison experiments.
3. Experiment template:
   - predefined metric
   - run count
   - report format (mean/stddev + interpretation).

Primary files:

- `scripts/orca/orca.sh`
- new snapshot/experiment scripts
- experiment docs

Exit criteria:

1. Two harness versions can be compared from equivalent starting state.
2. Results can be attributed by `harness_version`.
3. Promotion remains manual until reliability is proven.

## Dependency Order

1. `M0 -> M1 -> M1.5 -> M2` is strict (do not reorder).
2. `M3` can start after `M1`, but should finish after `M2`.
3. `M4` depends on `M1.5` and benefits from `M3`.
4. `M5` depends on `M1` and `M3`.
5. `M6` depends on `M0` and `M2`.
6. `M7` depends on `M0` and should start only after `M2-M6` stabilize.

## Suggested Beads Epic Breakdown

1. `orca-epic-context-split` (M1)
2. `orca-epic-knowledge-readpath` (M1.5)
3. `orca-epic-invariants-enforcement` (M2)
4. `orca-epic-role-prompts` (M3)
5. `orca-epic-knowledge-lifecycle` (M4)
6. `orca-epic-harness-improvement-loop` (M5)
7. `orca-epic-summary-quality-gates` (M6)
8. `orca-epic-ab-foundations` (M7)

## Scope Guardrails

1. Do not build UI/dashboard work in this roadmap.
2. Do not automate harness self-modification before A/B foundations exist.
3. Preserve merge-lock correctness invariants throughout.
