# Orca Planning Stance (Pre-Implementation)

Status: Active

Purpose: define how planning is done while the design is still uncertain.

---

## Primary Optimization Target

Optimize for **learning velocity** and **decision quality**, not implementation throughput.

This phase exists to reduce the chance of building the wrong system quickly.

## What this phase is for

- Clarifying goals, boundaries, and failure modes
- Testing assumptions with existing evidence where possible
- Choosing between alternative design directions
- Defining reversible experiments (not production milestones)

## What this phase is not for

- Milestone implementation roadmaps
- Task breakdowns by week/sprint
- Committing to concrete interfaces too early
- Building infrastructure because it seems generally useful

## Working rules

1. Every major design claim should be expressed as a hypothesis.
2. Prefer low-cost probes (log analysis, one-off sessions, tiny skills) before architecture.
3. Separate invariant decisions from policy/experimentation decisions.
4. Keep decisions reversible unless there is strong evidence otherwise.
5. Record uncertainty explicitly; avoid implied certainty through polished prose.

## Decision threshold guidance

A planning decision is "ready" when:

- the problem statement is specific,
- at least one alternative was seriously considered,
- the cost of being wrong is understood,
- and a clear revisit trigger exists.

Otherwise, keep it in hypothesis state.

## Deliverables expected from this phase

- Capability catalog with authority envelopes
- Invariants vs policy classification
- Hypothesis backlog with evidence plans
- Decision ledger with confidence + revisit triggers
- Design review template/checklist

No implementation roadmap is expected until these artifacts stabilize.
