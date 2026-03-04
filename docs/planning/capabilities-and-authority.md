# Orca Capabilities and Authority Envelopes

Status: Draft

This document defines desired functionality without committing to implementation style.

---

## Framing

Each capability is specified by:

1. **Outcome** — what value it should produce
2. **Authority envelope** — what it may read/write
3. **Safety constraints** — what it must not do
4. **Candidate realizations** — possible implementation styles (non-binding)

---

## C-1 Execution

- **Outcome:** complete queued work safely and with minimal operator intervention.
- **Authority envelope:** read/write code and run artifacts; obey coordination invariants.
- **Safety constraints:** no bypass of claim/merge correctness requirements.
- **Candidate realizations:** existing batch loop (default), variant prompts, minimal runtime profile variants.

## C-2 State synthesis

- **Outcome:** answer "what is happening now" from artifacts.
- **Authority envelope:** read-only access to logs, summaries, metrics, queue state.
- **Safety constraints:** no state mutation.
- **Candidate realizations:** ad-hoc query prompt, report skill, scripted summaries.

## C-3 Plan/queue review

- **Outcome:** evaluate priority/dependency quality and identify planning risks.
- **Authority envelope:** read-only queue, notes, and relevant history.
- **Safety constraints:** no edits to queue in this capability.
- **Candidate realizations:** focused review session; optional structured review checklist.

## C-4 Queue steering

- **Outcome:** apply intentional priority/dependency changes to open work.
- **Authority envelope:** write access to `open` queue items only.
- **Safety constraints:** cannot modify `in_progress` work items.
- **Candidate realizations:** constrained skill; interactive session with explicit write policy.

## C-5 Knowledge curation

- **Outcome:** improve usefulness of accumulated operational knowledge (consolidate, resolve contradictions, prune stale entries).
- **Authority envelope:** read/write knowledge store only.
- **Safety constraints:** no code or queue mutation while curating knowledge.
- **Candidate realizations:** on-demand curation session; periodic lightweight skill; occasional maintenance run.

## C-6 Task-spec support

- **Outcome:** transform ambiguous goals into constrained, testable task specs that reduce overengineering.
- **Authority envelope:** read project context; write proposed specs/checklists/templates.
- **Safety constraints:** does not execute production code changes as part of spec drafting.
- **Candidate realizations:** interactive decomposition assistant; design-intent checklist skill.

---

## Notes on implementation choice

At this stage, realization choice should be judged by:

- reversibility,
- measurable effect on outcomes,
- and clarity of boundary enforcement.

Do not promote a realization to a permanent subsystem before those criteria are met.
