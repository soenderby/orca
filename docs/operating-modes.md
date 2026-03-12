# Orca Operating Modes (Proposed)

## Purpose

Define a small, explicit way to switch Orca behavior between throughput-biased and autonomy-biased operation **without** turning the harness into a policy engine.

This keeps the long-term architecture stable:
- harness owns transport/coordination
- agents own reasoning
- hard constraints stay minimal and focused on shared/irreversible boundaries

Assignment-first planning is the baseline architecture for launch/claim behavior.
`execute|explore` profiles and approach snippets are optional overlays and must not
weaken assignment invariants.

## Long-Term Stance

1. Default to agent autonomy.
2. Keep hard guardrails only where failures are expensive and shared:
   - serialized writes to `main`
   - queue/code separation (`.beads` guards)
   - required run artifacts for auditability
3. Express everything else as optional defaults, tools, and feedback loops.
4. Promote changes based on measured outcomes, not checklist compliance.

## Proposed Modes

Modes are profile defaults, not rigid behavior contracts. Agents can deviate with rationale in run summaries.

### 1) `execute` mode (throughput-biased)

Use when work is well-defined and operator wants efficient completion.

Default profile intent:
- minimize idle runs/token waste
- keep scope tight
- stop cleanly when queue is drained

Example defaults (implementation-target):
- `ORCA_NO_WORK_DRAIN_MODE=drain`
- lower no-work retry budget
- optional focused work-approach snippet

### 2) `explore` mode (autonomy-biased)

Use when work is ambiguous/discovery-heavy and operator wants initiative.

Default profile intent:
- tolerate ambiguity and discovery
- allow wider investigation loops
- avoid premature stop in sparse/arriving queues

Example defaults (implementation-target):
- `ORCA_NO_WORK_DRAIN_MODE=watch`
- higher no-work retry tolerance (or polling)
- optional exploration-oriented approach snippet

## Work Approach Snippets (Experimental)

Approach guidance should remain optional and lightweight:
- injected from `ORCA_WORK_APPROACH_FILE` when set
- empty by default (current behavior preserved)
- treated as advisory defaults, not hard policy

Design constraint:
- if approach guidance conflicts with issue acceptance criteria, issue criteria win
- deviation should be noted in run summary `notes`

## Observability Requirements (Mandatory for Experiments)

Any mode/approach experiment must be attributable in artifacts:
- mode identifier per run/session
- approach file path (or identifier)
- approach content hash (e.g., SHA256)

Without attribution, comparisons are not trustworthy.

## Evaluation Criteria

Evaluate on outcome quality and efficiency, not compliance:
- `no_work` rate and token burn
- completed vs failed/blocked ratio
- follow-up discovery quality/volume
- rework signals (reopens, corrective follow-ups)
- operator intervention frequency

Run at least 10+ comparable issues per profile before changing defaults.

## Non-Goals

- no runtime issue-type classification in shell scripts
- no per-agent autonomous mode routing in harness
- no controller/daemon reconciliation loop by default

## Rollout Plan

1. Keep assignment-first planner flow as the default launch architecture.
2. Keep observability attribution for assignment/mode/approach in run artifacts.
3. Add optional approach snippet injection (advisory only).
4. Add `execute|explore` mode selector as default bundles with explicit override semantics.
5. Run comparative experiments and keep/tune/remove defaults based on measured results.
