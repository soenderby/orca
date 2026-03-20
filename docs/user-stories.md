# Usage Scenarios

Concrete workflow narratives for the orca/watch/lore ecosystem.
See `docs/ecosystem.md` for tool definitions, boundaries, and design principles.

## Operator Profile

Single developer. Works on one primary project at a time with active development, plus maintenance and small features across several other projects. Runs multiple agent sessions in parallel — both batch execution (orca) and interactive conversations (pi in tmux sessions). Manages cognitive load by keeping things up to date throughout the day rather than batching review at the end.

Preferences: keyboard-driven (emacs background), no desktop notifications or sounds, prefers manual polling when focused and a visible notification buffer when not. Maintains a chronological log in emacs organized by day and project.

Environment: single machine at a time, synced across machines via git. All agent activity runs in tmux sessions (one session per agent/task/project). One "home" session for watch and control.

## Tmux Topology

Everything is a tmux session:

- **Home session**: where watch runs (TUI mode). The operator's primary location.
- **Project sessions**: interactive pi conversations, one per project or task.
- **Orca agent sessions**: created by orca per agent run (naming convention: `orca-agent-N-<timestamp>`).
- **Ad-hoc sessions**: transient tasks, one-off investigations.

The operator navigates between sessions. Watch provides awareness of all sessions and shortcuts to jump between them. Returning "home" brings the operator back to the global view.

## Orca Scope

Orca is per-project. Each project repo that uses orca has its own queue, worktrees, agent loops, and artifacts. Orca does not span projects. When the operator wants batch execution on project X, they run orca commands in project X's repo.

Watch is the tool that provides cross-project awareness by monitoring all tmux sessions — including multiple orca instances running in different repos.

---

## 1. Starting the Day

The operator opens a terminal. They start or attach to their home tmux session. Watch is running in TUI mode, showing the state of all tmux sessions — which ones exist, which are active, which have new output since last seen.

If orca agents were left running overnight (rare but possible), watch shows their completion state. The operator sees at a glance: everything finished, or something needs attention.

The operator may switch to a project session and talk to an agent about the day's plan. They review their emacs log for yesterday's notes. They decide which project gets primary attention.

**What matters:** Time from "sit down" to "know what's happening" should be seconds.

## 2. Planning and Breaking Down Work

The operator is in a project session (pi). They discuss a feature or change with the agent. This is iterative — back and forth about design, tradeoffs, approach. The conversation produces:

- A plan or spec (markdown, stored in the project repo)
- A set of concrete tasks broken down from the plan
- Issues created in the br queue, with dependencies and contention labels where needed

The queue is shallow — typically under 20 issues. The operator prefers small, well-specified batches over deep queues, because agent-implemented work can deviate when there are too many issues to track.

**What matters:** The quality of task specification drives execution quality. This step is where leverage comes from.

## 3. Running a Batch

The operator starts orca from their project session or from a command pane:

```
cd /path/to/project
orca start 2 --runs 1
```

Orca assigns issues to agents, launches tmux sessions, and runs. The operator switches back to watch (home session) to see the new orca sessions appear. Watch shows the agent sessions as active.

Typical batch: 1-2 agents, 1-3 runs each. Small and bounded. The operator wants to review results before running more.

Sometimes, for well-specified queues, the operator runs a continuous drain:

```
ORCA_ASSIGNMENT_MODE=self-select orca start 2 --continuous
```

Or uses the dispatch loop to auto-relaunch waves:

```
./dispatch-loop.sh --max-slots 2 --poll-interval 20
```

**What matters:** Starting a batch should be one command. The operator should be able to start it and immediately return to other work.

## 4. Monitoring While Working

The operator is in their home session with watch running. They are primarily working on something else — an interactive conversation in another project session, reading code, thinking.

Watch's TUI shows the state of all sessions. When an orca agent finishes a run, watch updates its display. The operator glances at it when they choose to, not when forced to.

When the operator wants to actively monitor:
- They look at the watch TUI which shows session states and recent events.
- They see an agent has completed — they press a key to jump to that session and review the output.
- They jump back to home when done.

When the operator is deeply focused and does not want to look at watch:
- They run a command to poll: `watch status` (or similar) — a one-line answer to "is anything done?"
- They return to what they were doing.

Events accumulate in watch's notification buffer. The operator can scroll through them when they have attention to spare.

**What matters:** Monitoring must not interrupt focus. The operator pulls information when ready; the system does not push.

## 5. Reviewing Completed Work

An orca batch has finished. The operator reviews:

1. Quick check via watch or `orca status` — did agents succeed, fail, or get blocked?
2. For each completed agent run, the operator may:
   - Jump to the agent session to see the final output
   - Have an agent in a project session read the run summaries and code changes
   - Test the actual behavior of the implemented changes themselves

The operator's review is primarily behavioral — they run the system and see if it does what they expected. Detailed code review is delegated to agents.

If something is wrong, the operator creates a new issue (via conversation with an agent) to fix or revert it, and runs another batch.

**What matters:** The review → fix → re-run cycle should be fast. Creating a corrective issue and re-running orca should be minutes, not an ordeal.

## 6. The Test-and-Fix Cycle

After a batch of feature work, the operator tests the system. They do this interactively, with agent help. Testing reveals:

- Bugs (things that are broken)
- Unintended behavior (things that work but are wrong)
- Refinements (things that work but could be better)
- Reversions (things that should be undone entirely)

Each of these becomes an issue in the queue — created through conversation with an agent. The operator then runs another orca batch to address them.

This cycle repeats: implement → test → discover → issue → implement. The queue never gets very deep because each cycle produces a small batch.

**What matters:** The feedback loop between "discover a problem" and "an agent is working on it" should be tight. Issue creation through conversation should be natural, not ceremonial.

## 7. Switching Projects

The operator is working on project A but needs to handle something on project B — a bug report, a quick feature, a maintenance task.

They switch to project B's tmux session (or create one). If project B has queued work, they run orca in project B's repo:

```
cd /path/to/project-b
orca start 1 --runs 1
```

Watch, running in the home session, now shows sessions for both project A and project B. The operator can see at a glance which project has active agents and which has finished.

The operator addresses the project B issue, then switches back to project A. Watch continues monitoring both.

**What matters:** Project switching should be a tmux session switch, not a context-loading ceremony. Watch should make it obvious what's happening across all projects simultaneously.

## 8. Quick Ideas and Notes

The operator has an idea about project C while working on project A. They switch to project C's session (or create one), type the idea to an agent, have a brief exchange, maybe create an issue. Then they switch back to project A.

This interaction is seconds to minutes. No setup, no orientation. Just capture the thought and return.

**What matters:** The cost of capturing an idea must be near zero. If it's high, ideas get lost.

## 9. Ad-Hoc Tasks

The operator needs to do something specific and short-lived: investigate a dependency, test a configuration, run a benchmark. They create a tmux session, run an agent or script in it, and want to know when it's done.

Watch shows this session alongside everything else. When it finishes, the operator sees it in the notification buffer or the session state display.

When done, the operator kills the session. Watch notices it's gone.

**What matters:** Ad-hoc sessions should not require registration or ceremony. Watch discovers tmux sessions automatically.

## 10. Ending the Day

The operator has been keeping their emacs log up to date throughout the day. There is no large end-of-day review burden.

They check watch one last time: are any agents still running? If so, they either wait for completion or stop them. They make any final notes in their log. They shut down.

The project state is committed and pushed so it's available on their other machine if needed.

**What matters:** No end-of-day ceremony beyond what's already been done throughout the day.

---

## Watch-Specific Scenarios

### W1. TUI Mode (Primary)

Watch runs in a tmux pane in the home session. It displays:

- All tmux sessions, grouped or labeled by type (orca agent, project, ad-hoc)
- Current state of each session (active/idle/finished/gone)
- Recent events (session started, run completed, run failed)

Keyboard shortcuts allow the operator to:
- Jump to a session (tmux switches to that session)
- Filter/search sessions
- Scroll through the event/notification buffer

The TUI updates live but does not aggressively redraw or flash. Changes appear; the operator notices when they choose to look.

### W2. CLI Mode (Scripting and Polling)

Watch can be invoked as a CLI for quick answers:

```
watch status              # one-line summary: 3 active, 2 finished, 0 failed
watch list                # all sessions with state
watch list --json         # machine-readable
```

This is for when the operator is in another pane or session and wants a quick answer without switching to the TUI.

### W3. Cross-Project Awareness

Watch discovers all tmux sessions. It does not need to know about orca specifically — it monitors tmux sessions, and orca agent sessions happen to be tmux sessions.

However, watch can recognize orca sessions by naming convention and display them with enriched information (run state, issue ID, last summary result) by reading orca's artifact directories.

For non-orca sessions, watch shows basic tmux state (exists, has recent output, etc.).

### W4. Session Jump and Return

The operator is in the home session looking at watch. They see an orca agent has finished. They press a key (or run `watch jump <target>`), and tmux switches to that agent's session. They review the output.

To return, the operator switches back to the home session (standard tmux navigation, or a watch-provided shortcut).

---

## Lore-Specific Scenarios (Research Phase)

These scenarios describe desired outcomes, not committed designs.

### L1. Resume Work Next Day

The operator sits down and starts a new agent session for project A. The agent immediately knows: what the project is, what we're currently working on, what was accomplished yesterday, what's queued, and what the open questions are. The operator did not have to brief the agent manually.

### L2. New Project Orientation

The operator points lore at a new project repo. Lore examines the codebase, existing documentation, and project structure. It produces a structured knowledge base that future agent sessions can query. The operator reviews and corrects it.

### L3. Session Knowledge Capture

An agent session ends after significant investigation or discussion. The knowledge gained — about the codebase, about design tradeoffs, about what was tried and failed — is captured in a form that future sessions can access. Not injected into their context, but queryable when relevant.

### L4. Emacs Log Integration

The operator's chronological log contains project-specific entries with plans, observations, and decisions. Lore can read the project-view of this log and surface relevant recent entries when an agent starts work on that project.

---

## Anti-Scenarios (What the Tools Should Not Do)

### A1. Interrupt Focus

No tool should push information at the operator. No desktop notifications, no sounds, no modal alerts. The operator pulls information when ready.

### A2. Require Ceremony

Starting a batch, checking status, jumping to a session, capturing an idea — these should be single commands or keystrokes. Multi-step workflows for routine operations indicate a design problem.

### A3. Lose Track of Scope

Orca agents should not add unbounded functionality beyond their assigned issue. The task specification must constrain scope. When agents consistently expand scope, the problem is in how tasks are defined, not in the execution engine.

### A4. Create End-of-Day Burden

The system should support keeping things up to date throughout the day. If the operator must batch-review, batch-document, or batch-groom at end of day, the workflow is failing.

### A5. Require Global Coordination

Each orca instance is independent. Watch observes without controlling. Lore provides context without mandating structure. No tool should require the others to function.
