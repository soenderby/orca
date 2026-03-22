# Agent-Augmented Development

A single developer operating autonomous coding agents to build software.

The bottleneck is not agent capability — it is the friction surrounding agent work:

- **Orientation friction**: How long until an agent is productive on a task?
- **Execution friction**: How safely can multiple agents work in parallel?
- **Supervision friction**: How quickly can the operator understand what is happening and intervene?

Three tools, each attacking one friction point. Each independently useful. Together, they form a feedback loop: context improves execution, execution produces artifacts, artifacts become context.

See `docs/user-stories.md` for concrete usage scenarios that drive design decisions.

## Core Concept: Agent-Centric Model

The ecosystem is built around **agents**, not sessions. An agent is a persistent identity — defined by its priming context — that may have multiple concurrent instances (tmux sessions). The agent is the conceptual unit the operator cares about. Sessions are infrastructure.

This model unifies orca batch workers and interactive conversations. An orca agent is just an agent that happens to get its sessions launched by orca. An interactive pi session is just an agent that happens to get its sessions launched by the operator. The difference is in tooling support, not in kind.

Agent identity is defined by priming context: the AGENTS.md file, the initial prompt, the project, the files the agent reads at session start. Two sessions are "the same agent" when they start from the same priming. Some agents have strong identity (heavily primed, consistent role). Others are lightweight (a throwaway task agent with minimal priming).

The identity registry is currently implemented in watch (`internal/identity`) and is planned for extraction into lore when that tool is built. See `docs/decision-log.md` DL-003 for the full rationale.

## The Tools

### Orca — Batch Execution Engine

Orca takes a queue of issues and runs agents against them in parallel with safety guarantees. It manages worktree isolation, queue locking, merge serialization, and structured artifact capture. It does not help the operator watch agents or give agents project context — other tools do that.

**Boundary:** Queue in, completed work and structured artifacts out. Orca is finished when the queue is drained and artifacts are written.

**Scope:** Per-project. Each project repo that uses orca has its own queue, worktrees, agent loops, and artifacts. Orca does not span projects. Cross-project operation is supported via `ORCA_HOME` — orca's scripts can live in one location and operate on any target repo.

**Language:** Bash (current). Go rewrite in progress — see `docs/go-rewrite-plan.md` and `docs/decision-log.md` DL-004.

**Current state:** Working. Pruned to batch-engine scope. Cross-project operation enabled via `ORCA_HOME`. Go rewrite planned and designed.

### Watch — Operator Supervision

Watch gives the operator real-time awareness of all agent activity across projects. It builds an agent-centric view from tmux sessions, project config, agent identities, and orca artifacts.

**Boundary:** Read-only consumer of tmux state and orca artifacts. Watch does not mutate execution state — it observes and navigates.

**Scope:** Global. Watch monitors tmux sessions that match registered agent identities. Unmatched tmux sessions are invisible to watch. This is how the operator gets cross-project awareness — watch is the global agent view, orca stays scoped to one project.

**Interface:** Two modes — a persistent TUI that stays running in the home session, and a stateless CLI for scripting and quick polling. The TUI provides live state with zoom-based hierarchical navigation (overview → agent detail → instance detail). The CLI provides machine-readable snapshots.

**Language:** Go. Single binary, no runtime dependencies.

**Current state:** Working. Agent-centric snapshot pipeline, event diffing, CLI and TUI implemented. See the [watch repo](https://github.com/soenderby/watch) for design docs and implementation.

### Lore — Agent Context and Knowledge

Lore manages the accumulated knowledge that makes agents productive: project structure, design decisions, past work, current goals, the operator's chronological log. It prepares context for new agent sessions and captures knowledge from completed ones.

**Boundary:** Produces structured context that can be injected into agent sessions. Consumes orca artifacts and operator knowledge sources. Does not execute agents or manage sessions.

**Language:** TBD.

**Current state:** Unsolved. The agent identity registry (currently in watch's `internal/identity` package) is the first concrete seed — it will be extracted into lore when the tool is built. The approach for knowledge capture and context injection is not yet clear. Operational experience from orca and watch continues to inform the design space.

## Tmux Topology

Everything is a tmux session:

- **Home session**: where watch runs in TUI mode. The operator's primary location and global view.
- **Project sessions**: interactive pi conversations, one per project or task.
- **Orca agent sessions**: created by orca per agent run (naming convention: `orca-agent-N-<timestamp>`).
- **Ad-hoc sessions**: transient tasks, one-off investigations.

The operator navigates between sessions. Watch provides awareness of agent-associated sessions and shortcuts to jump between them. Tmux sessions not associated with a registered agent identity are invisible to watch. Returning to the home session brings the operator back to the global agent view.

## How They Compose

```
    lore prepares agent context
         │
         ▼
    orca executes agent instances with that context
         │
         ▼
    orca produces structured artifacts
         │              │
         ▼              ▼
    watch reads     lore captures knowledge
    artifacts       from artifacts
         │                    │
         ▼                    │
    operator sees agents      │
    and their state,          │
    jumps to instances        │
                              │
              ┌───────────────┘
              ▼
    next agent session starts better
```

**Artifacts are the integration surface.** Tools communicate through files and CLI output, not shared libraries or IPC. Each tool can evolve independently as long as it respects the artifact contracts.

**Agent identity is the shared concept.** Orca creates agent instances. Watch displays agents and their instances. Lore manages agent knowledge. The identity registry — currently in watch, planned for extraction — is the shared data that connects them.

The artifact contract is owned by the producer. Orca defines its output specification (session log hierarchy, summary JSON schema, metrics format) in `docs/artifact-contract.md`. Watch and lore are consumers and reference that contract.

## Ecosystem Design Principles

These govern the relationship between tools, not the internals of any single tool.

**1. Each tool is independently useful.**
Orca works without watch or lore. Watch works without lore. An operator who only needs batch execution should not have to install or understand the full ecosystem.

**2. Artifacts are the integration contract.**
Tools integrate by reading each other's file outputs and CLI responses. The session log hierarchy, summary JSON schema, and metrics format are the API. Changes to these formats are breaking changes across the ecosystem.

**3. No tool owns another's lifecycle.**
Watch does not start or stop orca. Lore does not launch agents. Each tool manages its own processes. Composition happens through the operator's workflow, not through tool coupling.

**4. Shared abstractions are extracted, not designed upfront.**
When two tools need the same capability (tmux session queries, artifact path resolution, agent identity), extract it after both tools exist and the shared need is proven. Not before.

**5. CLI is the universal interface.**
Every tool is CLI-first. Tools can call each other via CLI. This keeps the integration surface inspectable and scriptable.

**6. Prefer files over services.**
No daemons, no databases, no message queues unless a concrete need demands them. Files on disk, queried by tools. This matches the single-developer, single-machine operating model.

**7. No interruptions.**
No tool pushes information at the operator. No desktop notifications, no sounds, no modal alerts. The operator pulls information when ready. Notification buffers accumulate events; the operator reads them on their own schedule.

**8. Go is the ecosystem language.**
Validated through the watch build. Go provides: single-binary deployment, type-safe data models, clean package boundaries, fast tests, and natural composition with CLI tools. Orca is being rewritten from bash to Go (see DL-004).

## Sequencing

### Phase 1: Prune Orca ✓

Completed. Deleted operator-cockpit surface (follow, observe, targets, jump, wait, monitor). Rewrote status to minimal batch-engine reporting. Consolidated documentation. Extracted artifact contract.

### Phase 2: Build Watch ✓

Completed. Go binary in separate repository. Agent-centric data model with snapshot pipeline:

- `internal/model` — Snapshot, Agent, Instance, Run, Event types
- `internal/identity` — Agent identity registry (global + project-local, planned for extraction to lore)
- `internal/snapshot` — SnapshotBuilder assembles snapshots from tmux + artifacts + identity
- `internal/events` — Snapshot diffing and per-agent event store
- `internal/poller` — Periodic snapshot production
- `internal/tui` — Zoom-based hierarchical TUI (overview → agent detail → instance detail)

CLI: `watch list`, `watch status`, `watch project add/remove/list`. TUI: `watch` with no args.
42 tests across 6 packages.

Key insight from this phase: the agent-centric model (agents, not sessions) emerged during watch design and became a foundational concept for the ecosystem. See DL-003.

### Phase 3: Rewrite Orca in Go

In progress. See `docs/go-rewrite-plan.md` for the full plan.

The watch build validated Go as the right language for the ecosystem. Orca's bash is the remaining barrier to shared abstractions between tools. The rewrite follows a test-first, incremental approach: pure logic first, then tool wrappers, then core operations, then CLI.

This replaces the original Phase 3 ("evaluate and extract") — the evaluation is complete, and the answer is to rewrite rather than extract piecemeal.

### Phase 4: Extract Shared Packages

After orca is in Go, identify genuinely shared code between orca and watch (tmux management, artifact parsing, agent identity) and extract into shared packages or a shared module. This was the original Phase 3 intent, deferred until both tools are in the same language.

### Phase 5: Lore

The orientation/context problem is the highest-value unsolved problem but also the least understood. The agent identity registry (currently in watch) is the first concrete seed. The emacs chronological log integration is a concrete starting thread when ready. Operational experience from earlier phases continues to inform what good context injection means.
