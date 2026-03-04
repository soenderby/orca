# Orca Design Review Template (Pre-Implementation)

Use this template to review design proposals while architecture is still fluid.

---

## 1) Problem statement

- What concrete failure mode or opportunity is being addressed?
- What evidence indicates this is real (not anecdotal)?

## 2) Proposed change (design-level)

- What changes conceptually?
- What does *not* change?

## 3) Alternatives considered

- Alternative A:
- Alternative B:
- Why the current option is preferred *for now*:

## 4) Invariant/policy classification

- Does this touch correctness invariants?
- Which parts are policy and should remain easy to vary?

## 5) Authority and boundary impact

- What new read/write authority is introduced?
- Are boundaries explicit and testable?

## 6) Failure modes and costs of being wrong

- Top 3 failure modes:
- Blast radius if wrong:
- Ease of rollback/reversal:

## 7) Evidence plan

- What evidence will increase confidence?
- What evidence would disconfirm this design?
- How long until decision revisit?

## 8) Decision output

- Decision status: Adopt (provisional) / Hold / Reject
- Confidence: Low / Medium / High
- Revisit trigger:
- Linked hypothesis IDs:
- Ledger entry ID:

---

## Review quality checks

A review is incomplete if:

- no alternative was considered,
- no disconfirming evidence is specified,
- no boundary/safety implications are identified,
- or there is no revisit trigger.
