# Orca Decision Log

This file records explicit architecture and operating decisions, including why they were made, what alternatives were considered, and what evidence would trigger a change.

---

## DL-001 — Agent constraints model: Option C (enable over enforce)

- **Date:** 2026-03-09
- **Status:** Active
- **Owner:** Operator

### Decision

Adopt **Option C** for now: treat queue/merge/coordination helpers as the standard operational path in prompts/docs, without introducing hard runtime enforcement boundaries.

In practical terms:
- keep protocol guidance explicit in prompts/docs,
- keep observability and traceability strong,
- do not add strict OS/runtime enforcement layers yet.

### Context

Orca has identified a gap between design language (“mechanically enforced invariants”) and current reality (prompt protocol + helper usage + post-run cleanup).

Three options were considered:

1. **Option A — hard enforcement**
   - constrain authority at runtime boundary (permissions, wrappers, mediated operations)
   - makes violations impossible or very hard
2. **Option B — hybrid**
   - keep autonomy, add stronger violation detection and automated consequences
3. **Option C — enable over enforce**
   - prioritize agent autonomy and helper ergonomics
   - rely on guidance, observability, and operator review

### Why Option C now

1. **Observed need is currently low.** No recurring high-cost incidents have yet justified enforcement complexity.
2. **Learning velocity is currently more important than control hardening.** Orca is still in active operational learning mode.
3. **Cost/complexity avoidance.** Strict boundary enforcement introduces significant implementation and operational overhead.
4. **Preserve autonomy experiments.** Current phase is to learn what agents do with high autonomy before constraining behavior.

### Risks accepted

- Protocol violations remain possible (because constraints are mostly social/procedural).
- Safety guarantees are weaker than they would be under runtime authority boundaries.
- Docs must avoid overstating what is mechanically enforced.

### Guardrails while on Option C

- Keep run artifacts machine-readable and queryable (logs, summaries, metrics).
- Keep queue/merge helper usage as default documented path.
- Keep queue/code separation checks that already exist (e.g., `.beads` handling on merge paths).
- Review incidents explicitly; do not normalize repeated protocol drift.

### Revisit triggers

Reopen this decision immediately if any of the following occur:

1. Repeated claim/queue races causing duplicate or conflicting work.
2. Repeated `.beads` contamination in run branches that escapes current safeguards.
3. Material operator overhead from protocol policing.
4. Any corruption/loss incident traceable to lack of hard boundaries.
5. Growth in agent count/concurrency where protocol-only control no longer scales.

### Evidence that would disconfirm Option C

Option C should be considered failed if observed data shows that autonomy-first operation causes recurring correctness/safety failures that cannot be controlled by existing guardrails and review practices.

### Next-step implication

If Option C is disconfirmed, default migration path is to **Option B first** (hybrid detection + consequences), then **Option A** (hard boundary enforcement) if needed.

---

## DL-002 — Contextual operating modes via defaults, not enforcement

- **Date:** 2026-03-11
- **Status:** Active
- **Owner:** Operator

### Decision

Adopt a **two-mode operating model** (`execute`, `explore`) as optional profile defaults, while keeping Orca's core architecture unchanged:

- keep hard constraints minimal and boundary-focused
- use tools/defaults/guidance for behavior shaping
- evaluate outcomes empirically before promoting defaults

This is a directional decision; implementation is staged through queue issues.

### Context

Operator needs shift by task type:
- sometimes throughput and tight scope are desired
- sometimes ambiguous terrain benefits from higher autonomy

A single global behavior posture is too blunt. At the same time, adding extensive runtime checks risks overfitting Orca to current model limitations and reducing long-term adaptability.

### Options considered

1. **Single fixed mode**
   - simple, but mismatched to real operator intent variability
2. **Hard policy enforcement expansion**
   - stronger control, but high complexity and likely long-term drag
3. **Contextual profile defaults (chosen)**
   - lightweight, reversible, keeps reasoning with agents

### Why this option

1. Preserves Orca principle: harness handles transport, agents handle decisions.
2. Supports both throughput-biased and autonomy-biased sessions without a policy engine.
3. Avoids premature fencing while still enabling controlled experiments.
4. Encourages learning loops from observed outcomes instead of speculative constraints.

### Risks accepted

- Mode defaults may be ignored or misapplied by agents.
- Prompt/profile surface can grow if not pruned.
- Experiment conclusions can be wrong without run-level attribution.

### Guardrails for this decision

- Keep mechanical invariants only at shared/irreversible boundaries.
- Any mode/approach experiment must be attributable in metrics/logs.
- Remove defaults that do not show measurable benefit.

### Revisit triggers

Reopen this decision if:
1. profile complexity starts encoding runtime reasoning in harness scripts
2. optional guidance grows into large mandatory prompt ballast
3. experiments repeatedly fail to show outcome improvements
4. repeated safety incidents show boundary guardrails are insufficient

### Disconfirming evidence

DL-002 is disconfirmed if contextual profiles create persistent complexity without measurable gains in throughput, quality, or operator effort relative to a simpler baseline.

### Next-step implication

Implement in stages:
1. observability attribution for mode/approach
2. queue-aware start capping (start-side efficiency)
3. optional work-approach injection
4. mode selector wiring with explicit override semantics

---

## DL-003 — Agent-centric model: agents, not sessions, as the base unit

- **Date:** 2026-03-22
- **Status:** Active
- **Owner:** Operator

### Decision

Adopt agents — persistent identities defined by priming context — as the fundamental unit across the ecosystem. Tmux sessions are instances of agents, not first-class entities. Tmux sessions not associated with a registered agent identity are invisible to watch.

### Context

During watch design, the initial data model was session-centric: tmux sessions were the atomic unit, some enriched with orca data, others standalone. This created an awkward split between "orca sessions" (rich) and "other sessions" (minimal), and didn't match how the operator actually thinks about work.

The operator thinks in terms of ongoing collaborations (agents), not individual terminal sessions. The same agent (e.g., "librarian" in ai-resources) may span many sessions. Orca batch workers are agent instances, not unique entities. Interactive pi conversations about the same project are the same agent in different sessions.

### Options considered

1. **Session-centric (original)** — tmux sessions are the base unit, optionally enriched. Simple but doesn't match the mental model.
2. **Agent-centric with session grouping** — agents own sessions. Requires identity registry but matches the operator's mental model.
3. **Hybrid with auto-discovery** — every tmux session is an agent. Too broad; captures sessions that have nothing to do with agents (htop, builds, etc.).

### Why this option

Option 2 was chosen because:
1. It matches how the operator thinks about work.
2. It unifies orca and non-orca work under a single model.
3. It creates a natural anchor point for lore (knowledge belongs to agents, not sessions).
4. It reduces special-casing — orca agents are just agents with richer tooling, not a different category.
5. Ignoring unmatched sessions keeps watch focused on agents rather than being a general tmux manager.

### Risks accepted

- Agent identity requires explicit registration (ceremony for every agent).
- Non-orca session matching by working directory can produce false positives.
- Global agents (no project association) cannot be automatically matched to sessions yet.
- The identity registry is an additional data structure that must be maintained.

### Revisit triggers

1. The ceremony of registering agents becomes a significant friction that prevents adoption.
2. Working-directory matching produces persistent false positives that degrade watch's usefulness.
3. The agent model creates complexity without measurable benefit over a simpler session list.

### Disconfirming evidence

The agent-centric model is disconfirmed if operators consistently think in sessions rather than agents, or if the identity registry is more burden than benefit.

### Next-step implication

Agent identity is currently implemented in watch's `internal/identity` package. When lore is built, this package is extracted into lore and becomes the authoritative identity registry for the ecosystem.

---

## DL-004 — Rewrite orca from bash to Go

- **Date:** 2026-03-22
- **Status:** Active
- **Owner:** Operator

### Decision

Rewrite orca incrementally from bash to Go, using a test-first approach. See `docs/go-rewrite-plan.md` for the implementation plan.

### Context

Orca is 5,488 lines of bash across 19 scripts. The execution layer works and all 9 regression tests pass. The question is whether the cost of rewriting is justified by the benefit.

The watch build (Phase 2) served as a controlled evaluation of Go for this class of tool. Watch was built from scratch as a Go binary: 4,227 lines, 42 tests, clean package structure, type-safe data model. The experience demonstrated clear benefits over bash for complex stateful logic, JSON processing, and testing.

### Options considered

1. **Stay in bash.** No rewrite cost. But: no shared abstractions with watch, JSON processing via jq subshells, no type safety, testing requires elaborate bash harnesses.
2. **Full Go rewrite (big bang).** Rewrite everything at once. High risk, long period of instability.
3. **Incremental Go rewrite (chosen).** Build Go binary alongside bash scripts. Migrate commands one at a time. Validate against existing regression tests. Cut over when complete.
4. **Partial rewrite (core in Go, helpers in bash).** Lower cost but creates a mixed runtime that is harder to understand.

### Why this option

Option 3 (incremental rewrite) was chosen because:
1. The watch build proved Go works for this domain: type-safe models, clean packages, fast tests, single binary.
2. Shared abstractions between orca and watch require a common language. Bash cannot produce libraries that Go consumes.
3. The incremental approach means orca is never broken — both implementations coexist during transition.
4. Existing regression tests define the expected behavior — they are the rewrite specification.
5. `agent-loop.sh` (1,175 lines) and `start.sh` (656 lines) are painful in bash: complex state machines, 30-argument printf for tmux env injection, JSON parsing via jq subshells.

### Risks accepted

- Rewrite is always more work than expected.
- Opportunity cost: time spent rewriting is time not spent building features.
- The bash implementation works; the rewrite may introduce new bugs.
- Some bash idioms (flock, process management) may be more natural in bash than Go.

### Revisit triggers

1. The rewrite stalls or produces a Go implementation that is more complex than the bash it replaces.
2. Go proves awkward for the process-management and git-interaction patterns that dominate orca.
3. The shared-abstraction benefit does not materialize (orca and watch don't actually share code).

### Disconfirming evidence

The rewrite is disconfirmed if the Go implementation requires significantly more code for the same behavior, or if the testing and maintenance experience is not measurably better than bash.

### Next-step implication

Follow the plan in `docs/go-rewrite-plan.md`. Phase 1 (pure logic) first, then primitives, then core operations, then CLI, then validation and cutover.

---

## DL-005 — Deprecate legacy queue-helper prompt invocation forms

- **Date:** 2026-04-07
- **Status:** Active
- **Owner:** Operator

### Decision

Deprecate prompt helper invocation forms that are intentionally unsupported by the Go helper commands:

- `queue-read-main --fallback ... --worktree ...`
- `queue-write-main --message ...`
- `br --actor ... update ...` (global-flag form) in prompt examples

Use the Go-safe forms instead:

- `queue-read-main -- br <read-command> ...`
- `queue-write-main --actor <name> -- br <mutation-command> ... --actor <name> ...`
- `br update ... --actor ...`

### Context

The rewrite has explicit fail-fast decisions for unsupported compatibility flags. Keeping legacy forms in the prompt while helpers fail fast creates operator confusion and inconsistent agent behavior.

### Options considered

1. Preserve old prompt forms and add compatibility shims in Go helpers.
2. Keep fail-fast helpers and update prompt contract (chosen).

### Why this option

- Aligns prompt behavior with the implemented helper interface.
- Preserves safety constraints (`--actor` explicitness, payload guardrails).
- Avoids silent behavior differences between bash and Go helper paths.

### Risks accepted

- Older agent snippets/docs using deprecated forms will fail until updated.
- This is a controlled prompt contract change and must be communicated.

### Revisit triggers

1. Significant tooling depends on deprecated forms and migration cost is high.
2. Operators report frequent breakage from legacy snippets.

### Disconfirming evidence

If compatibility breakage outweighs safety/clarity gains, reconsider adding explicit compatibility adapters.

### Next-step implication

Keep `ORCA_PROMPT.md` and Go CLI regression tests aligned. Any further helper interface changes require explicit decision-log entry plus regression updates.

---

## Entry template

Use this template for new decisions:

```md
## DL-XXX — <short title>
- Date:
- Status: Active | Superseded | Rejected
- Owner:

### Decision

### Context

### Options considered

### Why this option

### Risks accepted

### Revisit triggers

### Disconfirming evidence

### Next-step implication
```
