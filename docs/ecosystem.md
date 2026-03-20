# Agent-Augmented Development

A single developer operating autonomous coding agents to build software.

The bottleneck is not agent capability — it is the friction surrounding agent work:

- **Orientation friction**: How long until an agent is productive on a task?
- **Execution friction**: How safely can multiple agents work in parallel?
- **Supervision friction**: How quickly can the operator understand what is happening and intervene?

Three tools, each attacking one friction point. Each independently useful. Together, they form a feedback loop: context improves execution, execution produces artifacts, artifacts become context.

See `docs/user-stories.md` for concrete usage scenarios that drive design decisions.

## The Tools

### Orca — Batch Execution Engine

Orca takes a queue of issues and runs agents against them in parallel with safety guarantees. It manages worktree isolation, queue locking, merge serialization, and structured artifact capture. It does not help the operator watch agents or give agents project context — other tools do that.

**Boundary:** Queue in, completed work and structured artifacts out. Orca is finished when the queue is drained and artifacts are written.

**Scope:** Per-project. Each project repo that uses orca has its own queue, worktrees, agent loops, and artifacts. Orca does not span projects.

**Language:** Bash. The execution layer works and composes naturally with its dependencies (git, tmux, br, codex).

**Current state:** Working. Needs pruning of operator-cockpit surface that does not belong in a batch engine.

### Watch — Operator Supervision

Watch gives the operator real-time awareness of all agent activity across projects — orca batch sessions, interactive conversations, ad-hoc tasks. It provides both a persistent TUI for continuous awareness and a CLI for quick polling and scripting.

**Boundary:** Read-only consumer of tmux state and orca artifacts. Watch does not mutate execution state — it observes and navigates.

**Scope:** Global. Watch monitors all tmux sessions on the machine. It recognizes orca agent sessions by naming convention and enriches them with artifact data. Non-orca sessions are shown with basic tmux state. This is how the operator gets cross-project awareness — watch is the global view, orca stays scoped to one project.

**Interface:** Two modes — a persistent TUI that stays running in the home session, and a stateless CLI for scripting and quick polling. The TUI provides live state, an event/notification buffer, and keyboard shortcuts for session navigation. The CLI provides machine-readable snapshots.

**Language:** Go. Single binary, no runtime dependencies. Good concurrency primitives for the "poll multiple sources, merge events" workload. Also serves as a test of whether moving beyond bash provides meaningful benefit for this class of tool.

**Current state:** Prototyped inside Orca as follow, observe, targets, jump, wait, and heavy status. Needs extraction into a standalone binary.

### Lore — Agent Context and Knowledge

Lore manages the accumulated knowledge that makes agents productive: project structure, design decisions, past work, current goals, the operator's chronological log. It prepares context for new agent sessions and captures knowledge from completed ones.

**Boundary:** Produces structured context that can be injected into agent sessions. Consumes orca artifacts and operator knowledge sources. Does not execute agents or manage sessions.

**Language:** TBD.

**Current state:** Unsolved. The problem is understood but the approach is not yet clear. Research phase. Working on orca and watch may clarify what good context injection looks like through accumulated operational experience.

## Tmux Topology

Everything is a tmux session:

- **Home session**: where watch runs in TUI mode. The operator's primary location and global view.
- **Project sessions**: interactive pi conversations, one per project or task.
- **Orca agent sessions**: created by orca per agent run (naming convention: `orca-agent-N-<timestamp>`).
- **Ad-hoc sessions**: transient tasks, one-off investigations.

The operator navigates between sessions. Watch provides awareness of all sessions and shortcuts to jump between them. Returning to the home session brings the operator back to the global view.

## How They Compose

```
    lore prepares context
         │
         ▼
    orca executes agents with that context
         │
         ▼
    orca produces structured artifacts
         │              │
         ▼              ▼
    watch reads     lore captures knowledge
    artifacts       from artifacts
         │                    │
         ▼                    │
    operator gains            │
    awareness & intervenes    │
                              │
              ┌───────────────┘
              ▼
    next session starts better
```

**Artifacts are the integration surface.** Tools communicate through files and CLI output, not shared libraries or IPC. Each tool can evolve independently as long as it respects the artifact contracts.

The artifact contract is owned by the producer. Orca defines its output specification (session log hierarchy, summary JSON schema, metrics format) in a dedicated contract document. Watch and lore are consumers and reference that contract. If a shared package is extracted later, contract ownership can move there.

## Ecosystem Design Principles

These govern the relationship between tools, not the internals of any single tool.

**1. Each tool is independently useful.**
Orca works without watch or lore. Watch works without lore. An operator who only needs batch execution should not have to install or understand the full ecosystem.

**2. Artifacts are the integration contract.**
Tools integrate by reading each other's file outputs and CLI responses. The session log hierarchy, summary JSON schema, and metrics format are the API. Changes to these formats are breaking changes across the ecosystem.

**3. No tool owns another's lifecycle.**
Watch does not start or stop orca. Lore does not launch agents. Each tool manages its own processes. Composition happens through the operator's workflow, not through tool coupling.

**4. Shared abstractions are extracted, not designed upfront.**
When two tools need the same capability (tmux session queries, artifact path resolution, git worktree management), extract it after both tools exist and the shared need is proven. Not before.

**5. CLI is the universal interface.**
Every tool is CLI-first. Tools can call each other via CLI. This keeps the integration surface inspectable and scriptable.

**6. Prefer files over services.**
No daemons, no databases, no message queues unless a concrete need demands them. Files on disk, queried by tools. This matches the single-developer, single-machine operating model.

**7. No interruptions.**
No tool pushes information at the operator. No desktop notifications, no sounds, no modal alerts. The operator pulls information when ready. Notification buffers accumulate events; the operator reads them on their own schedule.

## Sequencing

### Phase 1: Prune Orca ✓

Completed. Deleted operator-cockpit surface (follow, observe, targets, jump, wait, monitor — scripts, libs, tests, docs). Rewrote `status.sh` to minimal batch-engine reporting (1,748 → 234 lines). Rewrote README (649 → 126 lines) and OPERATOR_GUIDE (353 → 134 lines). Extracted artifact contract to `docs/artifact-contract.md`.

### Phase 2: Build Watch

- Go binary, separate repository.
- Start with two capabilities: live session state display (TUI) and CLI status polling.
- Consume orca's existing artifact format and tmux state directly.
- Do not change orca to serve watch's needs. If watch cannot work with orca's existing output, that is a watch problem.
- Add session jump (keyboard shortcut in TUI, `watch jump` in CLI) once the display layer works.
- Add notification buffer once jump works.

### Phase 3: Evaluate and Extract

- Identify what is genuinely duplicated between orca and watch (tmux queries, artifact path resolution, etc.).
- Extract shared abstractions into a form both can consume.
- Decide whether orca benefits from language migration based on real evidence from the watch build.

### Phase 4: Lore

- The orientation/context problem is the highest-value unsolved problem but also the least understood.
- The emacs chronological log integration is a concrete starting thread when ready.
- Operational experience from phases 1–3 will inform what good context injection means in practice.
