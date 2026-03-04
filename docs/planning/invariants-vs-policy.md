# Orca Invariants vs Policy Classification

Status: Draft

Purpose: prevent accidental promotion of preferences into hard constraints.

---

## Classification rule

- **Invariant:** If skipped, correctness/safety can fail. Must be mechanically enforced by harness/runtime boundaries.
- **Policy:** If skipped, quality/efficiency may degrade. Should remain adjustable and experiment-friendly.

---

## Current classification (draft)

| Topic | Class | Why | Enforcement expectation | Notes |
|---|---|---|---|---|
| Claim before coding/closing | Invariant | Prevents duplicate/conflicting work and queue corruption | Structural checks in harness flow | Details still under design |
| Lock before merge/push | Invariant | Prevents race conditions and merge-state corruption | Mechanical lock at merge boundary | Already aligned with current practice |
| Dirty worktree before run start | Invariant | Prevents state contamination and ambiguous diffs | Start-time hard check | Keep strict |
| Summary JSON presence/schema | Invariant (interface) | Downstream tooling depends on machine-readable artifacts | Deterministic validation | Semantic quality is separate |
| Summary narrative quality | Policy with quality gate option | Impacts usefulness, not raw correctness | Light checks possible; tune carefully | Avoid brittle over-constraint |
| Knowledge read requirements | Policy (experiment) | Affects learning efficiency, not safety | Start with soft nudges and telemetry | Revisit if write-only drift persists |
| Knowledge curation cadence | Policy | No single universally correct schedule | Trigger via observed need | Keep operator-driven initially |
| Role/capability realization style | Policy | Tooling form is still uncertain | No hard standard yet | Skills/prompts/scripts all valid |
| Plan-then-execute checkpoint | Policy (candidate) | Potentially high value, not always required | Trial before hardening | Evaluate overhead vs reduction in rework |

---

## Revisit criteria

Reclassify policy to invariant only when:

1. repeated failure mode is observed,
2. failure has meaningful correctness/safety impact,
3. mechanical enforcement is possible with low collateral damage,
4. and enforcement is expected to be net positive under normal workload.
