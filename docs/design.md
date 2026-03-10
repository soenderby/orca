# Orca

Orca is a local execution harness for running autonomous coding agents in parallel. It manages transport — tmux sessions, git worktrees, locking, task coordination, logging — so that agents can focus on doing work. It is built for a single developer operating multiple agents against a shared codebase.

Orca is not an agent framework. It does not abstract over LLM providers, manage prompt chains, or provide agent-building primitives. It manages the environment agents run in, not the agents themselves.

Its goal is to help a developer learn and operationalize how to use autonomous agents effectively to build software.

The execution layer works. In past use, failures and rework traced primarily to task specification quality — unclear intent, missing constraints, absent design context — not to execution mechanics. Providing agents with specific tools for recurring tasks was the other significant factor in effectiveness. These observations should inform where effort is spent, but they are not permanent truths — revisit as the system matures.

## Design Principles

### 1. The harness handles transport and coordination tools; agents handle decisions

The harness manages loops, worktrees, artifacts, locks, and coordination — and provides tools that help agents coordinate safely (lock helpers, queue mutation helpers, merge helpers). The harness may enforce execution protocol and safety invariants, but must not encode task-selection, solution-strategy, or quality-judgment heuristics.

### 2. Safety guardrails are mechanical where practical; protocol is explicit and observable

Orca runs in autonomy-first mode (see `docs/decision-log.md`, DL-001). The harness enforces cheap, deterministic guardrails where reliable, and treats the rest as protocol expectations supported by helpers and observability.

Current hard guardrails:
- Run branches carrying `.beads/` changes are rejected during merge (`merge-main.sh` guard).
- Primary repo must be clean before queue/merge helper operations.
- Clean worktree required before starting a non-running agent session.
- Run summary JSON is required and schema-validated by the loop.

Current protocol expectations (explicit, not hard-blocked in all paths):
- Publish claims via `queue-write-main.sh` on `ORCA_PRIMARY_REPO/main` before coding.
- Perform queue mutations via `queue-write-main.sh`.
- Perform integration via `merge-main.sh`.

Protocol adherence is expected, measured through run artifacts, and revisited when violations become costly or frequent.

### 3. Keep mandatory context minimal; make optional context discoverable

A large mandatory prompt crowds out task context and anchors agents on prescribed approaches. The agent coordination protocol (how to claim, merge, report) must be short and stable. Operational knowledge and guidance are optional — agents read them when relevant and ignore them when not.

Growth in mandatory context must be justified by a correctness need, not by a desire to improve quality.

### 4. Do not encode runtime reasoning in the harness

The harness is a thin, deterministic shell. Ranking, scoring, selecting, classifying, inferring complexity, deciding what should happen next at runtime — these are reasoning tasks that belong to the model, not to shell scripts or heuristics. When the harness reaches a runtime decision point, the answer is to give the decision to an agent, not to write a conditional.

### 5. Every run must leave a queryable trace

The system must produce structured, machine-readable artifacts for every run — logs, summaries, metrics, queue state changes. If a behavior can't be observed after the fact, it can't be diagnosed, compared, or improved. Reject any feature that doesn't leave a trace. Reject any trace that can't be queried.

### 6. Prefer the cheapest realization that tests the idea — unless correctness or observability is at stake

A prompt change before a script. A script before a subsystem. A manual experiment before automation. The right time to build infrastructure is after a lightweight version has proven the idea works.

The exception: when correctness (principle 2) or observability (principle 5) is at stake, do the safe thing, not the cheap thing.

### 7. The system improves through use, not through planning

Design documents that are not motivated by observed problems in real runs are speculative. Run the system, observe what fails, fix what matters. Planning is valuable when it processes evidence; it is waste when it precedes evidence.
