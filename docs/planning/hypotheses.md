# Orca Planning Hypotheses

Status: Active

Format: hypothesis-driven planning backlog. These are not commitments.

---

## H-001 Task granularity

**Hypothesis:** slightly larger tasks reduce coordination overhead without materially increasing failure severity.

- Signals to watch: merge frequency per completed unit, context-switch count, rework rate.
- Disconfirming evidence: larger tasks materially increase blocked runs or integration conflicts.

## H-002 Design-intent specification

**Hypothesis:** explicit design-intent constraints reduce overengineering and rework.

- Signals to watch: implementation size vs requirement scope, reviewer correction count.
- Disconfirming evidence: no measurable reduction in rework or recurring overbuild patterns.

## H-003 Plan-then-execute checkpoint

**Hypothesis:** requiring a brief plan checkpoint before implementation catches wrong direction early and improves outcome quality.

- Signals to watch: fewer mid-run pivots, fewer discarded large diffs.
- Disconfirming evidence: added latency with no reduction in wrong-direction work.

## H-004 Capability-first realization

**Hypothesis:** capability + authority framing produces better design decisions than fixed role architecture at current maturity.

- Signals to watch: fewer architecture reversals; easier iteration on prompts/skills.
- Disconfirming evidence: repeated confusion or boundary violations due to lack of stable role structure.

## H-005 Lightweight knowledge curation

**Hypothesis:** on-demand curation (skills/sessions) is sufficient before building dedicated automation.

- Signals to watch: contradiction rate, retrieval usefulness, repeated mistake frequency.
- Disconfirming evidence: persistent knowledge decay despite repeated curation efforts.

## H-006 Formal experimentation deferral

**Hypothesis:** deferring full A/B infrastructure does not block high-value decisions in the near term.

- Signals to watch: number of unresolved decisions due to missing controlled comparisons.
- Disconfirming evidence: repeated stalemates where existing telemetry cannot resolve competing designs.

---

## Prioritization guidance

Prefer hypotheses with:

1. high expected decision impact,
2. low evaluation cost,
3. and high reversibility of wrong choices.
