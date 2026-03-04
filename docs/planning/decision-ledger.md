# Orca Decision Ledger

Status: Active (living document)

Use this ledger to track architecture decisions **before** they are converted into implementation plans.

---

## How to use

- Add one row per decision topic.
- Keep confidence honest (Low/Medium/High).
- Define what evidence would invalidate the current bet.
- Add a revisit trigger so decisions do not become permanent by neglect.

## Ledger

| ID | Topic | Current bet | Confidence | Why this bet | What would disconfirm it | Revisit trigger | Owner | Status |
|---|---|---|---|---|---|---|---|---|
| DL-001 | Planning mode | Stay in pre-implementation mode; no roadmap yet | High | Design uncertainty still high; prior roadmap drifted from repo reality | Stable decisions across capabilities/invariants and repeated evidence from runs | Capability catalog + invariants matrix stable for 2 review cycles | Operator | Active |
| DL-002 | Functional framing | Use capability + authority envelopes instead of fixed roles | Medium | Preserves intent while keeping implementation open | If capabilities consistently require tightly coupled orchestration that ad-hoc realizations cannot provide | Two failed low-cost trials for same capability | Operator | Active |
| DL-003 | Knowledge curation realization | Start with lightweight/on-demand realization (skill or focused prompt), not permanent automation | Medium | Low cost, reversible, aligns with current maturity | If knowledge quality degrades despite repeated curation attempts or usage remains near zero | Evidence of repeated stale/contradictory knowledge causing execution failures | Operator | Active |
| DL-004 | Experimentation infrastructure | Formal A/B infra is deferred | Medium | Current bottleneck is task specification, not benchmark rigor | If design choices become blocked by unresolved performance disputes that cannot be answered with existing telemetry | 3+ unresolved architecture debates requiring controlled comparison | Operator | Active |
| DL-005 | Task-spec support priority | Prioritize task-spec support capability over execution-layer complexity | Medium | Failures appear upstream in specs and constraints | If improved specs do not reduce rework/failure patterns | After first structured spec-quality intervention trial | Operator | Active |

---

## Proposed status values

- **Active**: current working decision
- **Superseded**: replaced by a newer decision
- **Rejected**: explicitly dropped
- **Needs evidence**: cannot decide yet
