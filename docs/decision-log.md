# Orca Decision Log

This file records explicit architecture and operating decisions, including why they were made, what alternatives were considered, and what evidence would trigger a change.

---

## DL-001 — Agent constraints model: Option C (enable over enforce)

- **Date:** 2026-03-09
- **Status:** Active
- **Owner:** Operator

### Decision

Adopt **Option C** for now: treat queue/merge/coordination helpers primarily as enabling tools for agents, not hard enforcement boundaries.

In practical terms:
- keep helper-first guidance in prompts/docs,
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
