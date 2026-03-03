# Orca Redesign Plan

## Core Intent

Orca exists to let a single developer use multiple autonomous agents to implement a project in parallel. The aim is not to automate away developer judgment, but to amplify it. A developer should be able to describe what needs to be done, point agents at it, and then spend their time reviewing, steering, and making architectural decisions rather than writing every line of code themselves.

The harness's job is transport and safety, not cognition. It manages loops, worktrees, artifacts, locks, and coordination protocol. It does not decide what agents should do, how they should do it, or what constitutes a good outcome. Those decisions belong to agents and, at a higher level, to the human developer. A harness that encodes too much policy becomes a constraint that prevents agents from finding better approaches. Over-specification is a form of lock-in.

At the same time, some constraints are not policy. Coordination invariants — claiming work before coding, holding a lock before merging — are correctness requirements. If agents can discover their own approach to these, the system will occasionally produce data loss or race conditions, which is not an acceptable evolutionary outcome. These invariants must be mechanically enforced by the harness, invisible to agents as a surface they could choose to change. Everything else should be as open as possible.

The system should improve over time. Agents run into friction, discover better approaches, and accumulate operational knowledge. That knowledge should not be discarded at the end of each session. Agents should be able to suggest changes to how the system works, and those suggestions should have a clear path to becoming real. In early stages this path runs through human review; eventually, with the right evaluation infrastructure, it could be more automated.

Minimal and functional is not a constraint imposed on this design — it is a value the design actively upholds. Every added mechanism must justify its complexity against the cost of carrying it. The right amount of infrastructure is the minimum that makes agents reliably effective.

---

## Part 1: Proposed Design

### 1. Mandatory vs. Optional Context

Context is expensive. A large mandatory context crowds out task context, causes agents to anchor on guidance that isn't relevant to their current work, and makes it harder for agents to discover better approaches because the approach is already prescribed.

The current `AGENT_PROMPT.md` conflates two things with different authority levels:

- **Coordination protocol**: must be followed; correctness depends on it.
- **Implementation guidance**: useful starting point, but agents should be able to deviate if they have reason to.

These must be split.

#### Mandatory context (`AGENTS.md` / harness-injected prompt)

Short, stable, human-curated. Contains only what every agent must know to function correctly:

- The coordination protocol: how to claim work, how to use the merge lock.
- The run summary JSON contract: the harness validates this structurally; agents must emit it.
- Pointers to optional context: where the knowledge base lives, how to search it.
- Fundamental project facts: repo layout, primary branch name, beads queue entry point.

Target: fits comfortably in one screen. An agent that reads nothing else can still function correctly.

#### Optional context (agent knowledge base)

A structured directory of documents that agents may read when relevant and ignore when not. Written primarily by agents, not humans. Contains accumulated operational knowledge: what approaches have worked, what patterns have been found effective, what pitfalls have been encountered.

Agents must be pointed at this from mandatory context — a line saying "see `knowledge/` for accumulated operational guidance" is enough. Without this pointer, agents will not know to look. The content is optional; the pointer is mandatory.

The knowledge base is not AGENTS.md. It does not have the authority of AGENTS.md. It is reference material. An agent that reads the knowledge base and disagrees with what it says should deviate and may update the knowledge base with what it learned.

#### Discovery mechanism

Agents discover optional context through:
1. A short index document (`knowledge/INDEX.md`) listing what topics are covered and in which files.
2. Direct file reads when a topic seems relevant to current work.
3. Search over the knowledge base directory if needed.

The index is what makes optional context actually discoverable rather than just theoretically available.

#### What this is not

This split does not mean "give agents less guidance." It means guidance has different status. Coordination protocol is a hard constraint. Operational knowledge is a starting point. Implementation decisions are free.

---

### 2. Harness Invariants: Enforced, Not Described

Several things that currently live in `AGENT_PROMPT.md` as instructions should instead be structurally enforced by the harness. If an invariant is important enough to be in mandatory context, it is important enough to be in code.

**Invariants that should move to mechanical enforcement:**

- **Dirty worktree = no start.** Already enforced in `start.sh`. Keep this.
- **Lock before merge.** Currently described in the prompt as a pattern to follow. Should be enforced: the harness either wraps the merge phase automatically, or at minimum validates that the merge lock was held before accepting a successful run.
- **Claim before coding.** Currently instructed. Could be made structural: the harness does not provide a run branch until the agent has written a claimed issue ID to the summary stub. This is worth designing carefully — the goal is to make it impossible to accidentally skip, not to add ceremony.

The principle: if skipping it causes a correctness failure, the agent should not be able to skip it. If skipping it is merely suboptimal, leave it to agent judgment.

---

### 3. Agent Knowledge Base

The knowledge base is the inheritance mechanism for operational learning. When an agent discovers something useful — a more efficient approach to a common task, a pitfall to avoid, a tool that helps — that discovery should become available to future agents without requiring human intervention.

**Structure:**

```
knowledge/
├── INDEX.md          -- short list of topics and file paths
├── workflow.md       -- discovered patterns for the work loop
├── tools.md          -- useful tools, scripts, and commands
├── pitfalls.md       -- things that have gone wrong and why
└── <topic>.md        -- added by agents as new topics emerge
```

**Write protocol:**

Agents append to knowledge files at the end of a run, after the main work is done. They do not edit others' entries — they append their own. No extra locking is needed beyond the existing merge lock: agents work in isolated worktrees, and the merge lock serializes the merge step. Git's merge machinery auto-resolves concurrent appends cleanly since they add to different positions or both append to the end with differing content.

**INDEX.md must be append-only.** New entries go at the bottom. Agents do not reorganize or rewrite the index during regular runs. Any restructuring of the index is the librarian's job (see section 4, Agent Roles). This ensures the merge lock alone covers all knowledge base writes without conflict.

**Curation:**

The knowledge base is maintained by the librarian role (see section 4). Over time, entries may become stale or contradictory. The librarian consolidates, resolves contradictions, distills verbose entries, and removes outdated content. Librarian runs are triggered by knowledge base size thresholds or developer initiative, not by a fixed schedule.

**What does not belong here:**

- The coordination protocol. That is mandatory context.
- Project specifications. Those live in `SPEC.md` or equivalent.
- Task tracking. That is beads.

---

### 4. Agent Roles and Purpose-Specific Prompts

Rather than building a monitoring dashboard or UI, human oversight and system maintenance are achieved by spawning fresh agent sessions with purpose-specific prompts. This reuses existing infrastructure and adds no new components.

Each role gets a short, focused prompt that tells the agent exactly what it has access to, what its job is, and what it should not touch. The worker prompt is AGENTS.md. The others are invoked by the developer when needed.

#### Role taxonomy

| Role | Purpose | Read/Write scope |
|---|---|---|
| **Worker** | Implement issues from the queue | Code + own run artifacts |
| **Inspector (status)** | Report on current system state | Read-only: artifacts, metrics, beads |
| **Inspector (review)** | Evaluate plan and priorities | Read-only: beads, knowledge base |
| **Inspector (steer)** | Redirect priorities | Read/write: open beads issues only |
| **Librarian** | Maintain the knowledge base | Read/write: knowledge/ directory |

#### Why multiple templates instead of one

The three inspector use cases and the librarian have genuinely different needs. A status query needs to know where run artifacts and metrics live and what format they're in. A plan review needs beads state and the knowledge base — different data sources entirely. A steering session needs write access and must understand the write-boundary constraint. A librarian needs deep knowledge of the knowledge base structure but no access to beads or code.

A single "standard template" that covers all roles would either be so generic it provides little value, or so comprehensive that it reproduces the context-bloat problem AGENTS.md already has. Purpose-specific templates keep each prompt short and relevant. Freeform invocation is the escape hatch for one-off queries that don't fit a template.

#### Worker

The standard agent role. Pulls issues from the beads queue, implements them in an isolated worktree, and merges via the merge lock. Prompt is AGENTS.md — the mandatory context described in section 1. All coordination protocol, pointers to optional context, and project facts live here.

#### Inspector (status)

Reads run artifacts, metrics.jsonl, in-progress beads issues, and recent logs. Synthesizes a snapshot of current system state. Answers questions like "What are agents working on? Are any stuck? How many runs have succeeded recently?"

Read-only. Does not modify any state.

#### Inspector (review)

Reads beads state and the knowledge base. Evaluates whether the current plan and priorities make sense given what has been discovered. Answers questions like "Does the ordering of the queue make sense? Are there dependencies that should exist but don't?"

Read-only. Does not modify any state.

#### Inspector (steer)

Responds to developer intent to redirect priorities. Updates beads issues, priorities, dependencies, and notes. Creates new issues as needed.

**Write boundary:** Must not modify issues that are currently `in_progress`. May update `open` issues (priority, notes, dependencies) and create new ones. This constraint belongs in the prompt.

#### Librarian

Maintains the knowledge base. This is a first-class role, not janitorial work — the SWE-ContextBench finding (section D of research background) established that summarized knowledge outperforms raw knowledge, and the librarian is the distillation step that makes this happen.

**What the librarian does:**

- **Consolidation**: three agents independently discovered the same pitfall in slightly different words. The librarian synthesizes them into one authoritative entry.
- **Contradiction resolution**: agent A wrote "always use approach X" and agent B wrote "approach X fails when Y." The librarian reconciles this into a nuanced entry or removes the one that's wrong.
- **Structural maintenance**: keeps INDEX.md accurate, splits files that have grown too large, creates new topic files when a theme emerges across scattered entries.
- **Distillation**: turns verbose agent-written entries into concise, actionable knowledge.

**When to run the librarian:**

The librarian is not scheduled on a fixed timer. Two triggers:

1. **Size-based**: when the knowledge base exceeds a threshold (total lines, number of entries, number of files), the harness suggests a librarian run. This scales with actual activity.
2. **Developer-initiated**: the developer notices knowledge base quality degrading during inspector queries and kicks off a librarian session.

A periodic fallback (every N runs) can exist as a safety net, but the primary triggers should respond to actual need.

**Safety:** The librarian has destructive write access — it can delete, rewrite, and restructure. Git makes this safe. The librarian works in a worktree like any other agent. If the result is bad, you don't merge it.

#### What these roles are not

- **Real-time monitors.** They read snapshots of artifacts. They do not have a live view of agent activity.
- **Agent supervisors.** They do not send signals to running agents, interrupt them, or modify their in-flight context.
- **Persistent processes.** Each is a one-shot agent invocation, like any other run.

**Implication for artifact quality:** All non-worker roles are only as useful as the artifacts they can read. This means run summaries, beads notes, and knowledge base entries need to be meaningful and consistently written. Agents that write vague or empty summaries degrade the usefulness of every other role. This is a quality expectation, not a technical constraint.

---

### 5. Agent Self-Improvement (Suggestions Phase)

Agents should be able to identify friction in their workflow and surface it. This is the early stage of a self-modifying system, where the modification path runs through human review.

**Mechanism:**

When an agent encounters friction — a missing tool, an awkward workflow, a harness behavior that forced a suboptimal path — it creates a beads issue tagged `type=harness-improvement` with:
- What the friction was.
- What change would address it.
- Why it would be an improvement.

This is already technically possible. What is needed is:
1. Explicit encouragement in mandatory context: agents are expected to surface harness friction, not just work around it.
2. A convention for these issues to be easily filterable: `bd list --type=harness-improvement`.

Human developers review these issues as part of their normal workflow. Promising ones are implemented, A/B tested (see Part 2), and if validated, become part of the harness.

This is not an autonomous change mechanism. It is a structured feedback channel. Autonomous change requires the evaluation infrastructure described in Part 2 and should not be built before that foundation exists.

---

## Design Decisions

Explicit records of choices made and why, so they are easy to find and easy to revisit when circumstances change.

---

### DD-1: Serialized merge locking

**Decision:** All agent merges are serialized through a single `flock`-based lock (`orca-global.lock` in the git common directory). Only one agent may fetch, merge, and push at a time. All others wait.

**Rationale:** The workload orca targets — independent issues on a well-decomposed beads queue — results in agents working on disjoint files the vast majority of the time. In this regime, serialized locking is nearly never contested and has negligible throughput cost. It completely eliminates merge conflicts without requiring any coordination between agents at the task-selection layer.

Alternative approaches considered:

| Approach | Upside | Downside |
|---|---|---|
| Serialized lock (current) | No conflicts, simple | Throughput bottleneck if many agents complete simultaneously |
| Task isolation by file ownership | No lock needed | Requires upfront decomposition; brittle when tasks have cross-cutting scope |
| Optimistic merge + conflict resolution | Higher throughput in no-conflict case | Conflict resolution is hard; automated resolution is unreliable for semantic conflicts |
| Integration branch / merge queue | Decouples agent throughput from main | Adds latency for dependent tasks; staging branch lifecycle complexity |

**When to revisit:** If metrics show that lock contention is a meaningful fraction of session wall-clock time, or if task structure regularly produces overlapping file scope. The A/B infrastructure (see Part 2, section B) is the right tool for evaluating any proposed change.

---

### DD-2: Harness version identifier uses `git describe`

**Decision:** The harness version recorded in `metrics.jsonl` is the output of `git describe --always --dirty`. No semantic versioning is maintained.

**Rationale:** The primary consumer of the version identifier is metrics attribution, not human comprehension. For attribution, what matters is: (a) unique, (b) traceable to the exact code, (c) automatic. `git describe --always --dirty` gives all three with zero maintenance.

Semantic versioning would require someone to bump a version number every time the harness changes. If they forget, the version identifier is wrong — a worse outcome than having no human-readable version at all. `git describe` avoids this failure mode entirely.

When human-readable versions are wanted (e.g., for A/B testing), developers tag the relevant commits. `git describe` then produces output like `orca-v2-3-gc58377b` — human-readable *and* traceable. When no tags exist, it falls back to a bare SHA, which is still unique and traceable.

| Approach | Upside | Downside |
|---|---|---|
| `git describe` (chosen) | Zero maintenance, always correct, human-readable when tagged | Bare SHAs are opaque when untagged |
| Semantic versioning | Human-readable always | Requires manual bumps; wrong when forgotten |
| SHA only | Always unique and traceable | Never human-readable |

**When to revisit:** If harness versions are frequently discussed in human conversation (not just recorded in metrics), the opacity of untagged SHAs may become a friction point. Tagging more often is the first remedy; switching to semver is the last resort.

---

## Part 2: Future Ideas

### A. Evolutionary Self-Modification

**The idea:**

The system should be able to improve itself over time. Agents run in varying conditions, encounter different problems, and accumulate knowledge about what works. If a better approach is discovered, it should be possible for that approach to propagate — to become the new default for future agents. The analogy is evolutionary selection: variation (different approaches tried), selection (fitness function evaluates outcomes), inheritance (winning approach becomes the starting point).

**Why this is compelling:**

- Breaks the lock-in problem. A harness that can change in response to real performance data will not get stuck in a locally optimal but globally suboptimal configuration.
- Reduces the burden on the human designer. Instead of trying to specify the right approach upfront, you specify the evaluation criterion and let the system find the approach.
- Aligns with the ZFC principle: if the harness is dumb, the intelligence that improves it should also come from models, not from human engineering.
- An agent suggesting a harness improvement it has actually tried is stronger evidence than a human guessing what would work.

**Why this is hard:**

- **The inheritance problem is unsolved.** For the winning approach to propagate, something has to write it somewhere, something has to read it, and future runs have to actually behave differently as a result. The knowledge base can carry operational knowledge. But structural harness changes (changes to shell scripts, new lock primitives, changed loop behavior) require code changes, which require a review-and-merge path. There is no clean mechanism for a validated improvement to automatically become the new harness default.

- **Selection requires a fitness function, and the fitness function is hard.** What makes one harness version better than another? Completion rate? Time per issue? Code quality? Cost? These are not the same metric, and they trade off against each other. Without an agreed evaluation metric, "better" is undefined, and selection cannot operate.

- **Agents cannot reliably distinguish coordination invariants from policy.** An agent that suggests "we don't need the merge lock because I never had a conflict" has made a valid observation in its isolated experience and a dangerously wrong generalization. The harness must not allow the evolutionary surface to include correctness-critical invariants. This requires either agent understanding of the distinction (fragile) or mechanical exclusion (requires upfront classification of what is invariant vs. policy).

- **The system is not yet ready for autonomous change.** Autonomous structural change to the harness before the evaluation infrastructure exists is irresponsible. An incorrectly applied change could break all future runs silently. The suggestion mechanism described in Part 1 is the correct precursor: surface candidates for human review, build evaluation capability, then consider automated promotion.

**Recommended approach when pursued:**

1. Build the comparison infrastructure first (see below).
2. Define a small set of explicit evaluation metrics and encode them in metrics.jsonl.
3. Classify all harness behaviors as invariant (not evolvable) or policy (evolvable). Document this classification.
4. Design a staged promotion path: agent suggestion → human review → A/B test → validation → merge.
5. Only after all of the above: consider removing human from the loop for low-risk policy changes.

---

### B. Version Comparison / A/B Testing

**The idea:**

Run two versions of the orca harness — or two different configurations — on the same task and compare results. This is the evaluation mechanism that makes harness improvement principled rather than intuitive. Without it, you cannot know whether a change actually made things better.

**Why this is critical:**

Every other improvement in this document depends on knowing whether changes work. The suggestion mechanism produces candidates; the comparison infrastructure validates them. Without comparison, the system can only accumulate changes, never evaluate them. Improvements based on feel rather than measurement will eventually degrade the system.

It is also the mechanism that allows the evolutionary idea to close the loop. Variation is easy. Selection requires measurement.

**What it requires:**

1. **Reproducible starting state.** The task queue must be snapshotable. Running "the same task" means starting from identical beads state and repo state. This requires `orca snapshot` and `orca restore-snapshot` primitives that capture queue state at a point in time. Without this, two runs are not actually comparable.

2. **Isolation between versions.** If both harness versions merge to `main`, the task queue is consumed by whichever finishes first. Options:
   - Separate forks/repos for each run.
   - A no-merge "dry-run" mode where agents implement but do not push.
   - Separate integration branches per version.
   Each option has tradeoffs. Dry-run is simplest but changes agent behavior (agents know they are not merging).

3. **Defined evaluation metrics.** What is being measured must be agreed before the test runs. Candidates: tasks completed per N runs, failed runs per success, mean issue cycle time, cost per completed issue, code quality grade from a reviewer agent. The right metric depends on what the harness change is trying to improve.

4. **Harness version in metrics.** Current `metrics.jsonl` does not record which harness version produced the run. This is a prerequisite for attribution. Every run record should include a `harness_version` field (a git ref or explicit version tag).

5. **Statistical rigor.** One run of each version tells you almost nothing. Model outputs are stochastic. A harness that looks better after one run may be worse on average. You need N runs of each version, where N is large enough to distinguish signal from noise. This has real cost implications.

**Why this is hard:**

- Reproducible task queue state is a non-trivial addition to the beads/Dolt infrastructure.
- Isolating two runs such that neither affects the other requires either resource duplication or a mode change that alters agent behavior.
- Controlling for model non-determinism requires repeated runs, which multiply cost.
- The fitness function problem from the evolutionary discussion applies here too. Without an agreed metric, comparison produces numbers that cannot be interpreted.

**Recommended approach when pursued:**

1. Add `harness_version` to `metrics.jsonl` immediately — low cost, high value as a prerequisite.
2. Design the snapshot/restore primitive as a standalone `bd` or `orca` subcommand, separate from the core loop.
3. Define one primary evaluation metric before building the comparison infrastructure. Start simple: completed issues per session.
4. Build dry-run mode as the isolation mechanism. Acknowledge that it changes agent behavior slightly and factor this into interpretation.
5. Run comparisons manually at first: human interprets the metrics, human decides what to promote. Automated promotion comes later.

---

## Research Background & Inspiration

Organized by topic. Each section notes what is most relevant to orca's design problems and lists sources worth reading.

---

### A. Multi-Agent Orchestration Frameworks

The landscape of existing frameworks reveals a consistent pattern: systems that start with flexible, conversational multi-agent architectures tend to migrate toward more explicit, structured control as they mature. LangGraph's explicit graph approach and OpenHands' append-only event stream both represent learned lessons from the fragility of LLM-driven routing.

**Key insight for orca:** The git-worktree-per-agent isolation primitive is independently convergent across multiple projects (orca, ComposioHQ, ccswarm). This is strong evidence it is the right isolation boundary. The agent-computer interface (ACI) insight from SWE-agent — that purpose-built tool interfaces outperform raw shell access by a measurable, ablatable margin — applies directly to any tool orca exposes to agents.

**Emerging consensus (early 2026):**
- Git worktrees are the standard isolation primitive for parallel coding agents
- Explicit shared state (typed dicts, append-only event logs, files on disk) outperforms implicit conversational state
- Interface design matters as much as model quality — well-designed tool outputs prevent context flooding
- Human approval gates are present in every mature framework

| Source | What's relevant |
|---|---|
| [SWE-agent NeurIPS 2024](https://arxiv.org/abs/2405.15793) | ACI ablation study: quantifies how much interface design matters. Linting after edits, bounded search results, windowed file views each contribute measurably. |
| [OpenHands ICLR 2025](https://arxiv.org/abs/2407.16741) | Event stream as universal state primitive. Append-only log = both memory and audit trail. |
| [LangGraph multi-agent](https://blog.langchain.com/langgraph-multi-agent-workflows/) | Checkpoint/resume for long-running agents. State persistence at every step enables replay and human-in-the-loop. |
| [ComposioHQ agent-orchestrator](https://github.com/ComposioHQ/agent-orchestrator) | Closest analog to orca: worktree-per-agent, agent-agnostic, CI-event-triggered. Plugin architecture. |
| [ccswarm](https://github.com/nwiizo/ccswarm) | Rust-based worktree orchestrator with TUI monitoring. 93% token reduction via session-persistent manager. |
| [Awesome Agent Orchestrators](https://github.com/andyrewlee/awesome-agent-orchestrators) | Catalog of 40+ parallel coding agent runners — useful for surveying the space. |
| [Anthropic: Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) | Anthropic's own lessons: incremental progress discipline, structured feature lists as scope control, browser-based acceptance verification. |
| [Martin Fowler: Context Engineering for Coding Agents](https://martinfowler.com/articles/exploring-gen-ai/context-engineering-coding-agents.html) | Context window management strategies: when to summarize, when to RAG-inject, how to bound tool outputs. |
| [Why Multi-Agent LLM Systems Fail](https://arxiv.org/pdf/2503.13657) | Empirical taxonomy of failure modes — mismatch between reasoning and action (13.2%), wrong assumptions (6.8%), task derailment (7.4%). Design for these failure modes explicitly. |
| [Cognition SWE-1.5](https://cognition.ai/blog/swe-1-5) | Harness and model co-designed as a single system. 13x speed improvement. Argues harness is a first-class engineering artifact. |

---

### B. Agent Evaluation and A/B Testing

The most rigorous evaluation infrastructure in this domain comes from safety-focused organizations (METR, UK AISI) rather than product teams, because their evaluation needs are the most demanding. Their tooling (Vivaria, Inspect) is open source and directly usable.

**Key insight for orca:** SWE-bench's Docker-per-task-instance approach is the gold standard for reproducible starting state — each task has a hermetic environment image. This is the pattern orca's snapshot/restore primitive should approximate for the beads queue. The DFAH finding that temperature=0 is necessary but not sufficient for determinism (large models require 3.7x larger sample sizes for the same reliability as small models) is critical for interpreting version comparison results.

**On controlling for non-determinism:** temperature=0 reduces but does not eliminate variance. Even with seed parameters, API providers cannot guarantee bit-exact reproduction across calls. The practical methodology: run N trials of each version, report mean±stddev, choose N based on expected effect size and acceptable type-I/II error rates.

| Source | What's relevant |
|---|---|
| [SWE-bench GitHub](https://github.com/SWE-bench/SWE-bench) | Reference implementation for reproducible coding agent tasks. Three-layer Docker architecture (base → env → instance) achieves 99.78% reproduction rate. |
| [METR Vivaria](https://github.com/METR/vivaria) | Open-source eval infrastructure: Docker-based task environments, PostgreSQL result storage, web UI. The reference implementation for structured agent evaluation. |
| [UK AISI Inspect](https://inspect.aisi.org.uk/) | 100+ pre-built evaluations, supports arbitrary external agents. Becoming the standard eval framework; METR is migrating to it. |
| [AgentRR paper](https://arxiv.org/abs/2505.17716) | Record-and-replay for agent sessions. Generalizes traces into abstract "Experiences" that can be enforced during replay. |
| [DFAH paper](https://arxiv.org/abs/2601.15322) | Most directly relevant to version comparison: 74 configurations tested, T=0 determinism findings, positive correlation between determinism and faithfulness. Open-source harness. |
| [Langfuse A/B testing](https://langfuse.com/docs/prompt-management/features/a-b-testing) | Open-source, self-hostable. Labels prompt versions, routes traffic, tracks metrics per version. |
| [Hamel Husain: Eval tool selection](https://hamel.dev/blog/posts/eval-tools/) | Practitioner-written guide to choosing between eval frameworks. |
| [METR: Measuring AI task length](https://arxiv.org/html/2503.14499v1) | Metric: length of tasks an agent can complete end-to-end. Has been doubling every 7 months. A natural primary metric for orca version comparison. |

---

### C. Self-Improving Systems

The field has converged on six distinct mechanisms for agents to improve their own future behavior from past experience. These are not mutually exclusive and can be composed.

**Key insight for orca:** The most immediately applicable pattern is **verbal reinforcement (Reflexion)**: convert environmental feedback into a natural-language lesson appended to an episodic memory buffer, then prepend the buffer to future episodes. This maps directly to the knowledge base: agents write lessons from failed or suboptimal runs; future agents read them. No infrastructure beyond filesystem appends is needed.

The ADAS/Meta Agent Search result — that a meta-agent maintaining an archive of agent designs (expressed as code) can outperform hand-designed agents — is the most relevant to evolutionary self-modification. It suggests the long-term path: not evolving prompts, but evolving agent designs as code, evaluated against a benchmark archive.

The Tessl finding is notable: **cooperative refinement outperforms parallel competition**. Agents sharing and critiquing each other's solutions beats running many agents in parallel and picking the best. This argues against pure "run N agents and keep the winner" as an improvement strategy.

| Source | What's relevant |
|---|---|
| [Reflexion (NeurIPS 2023)](https://arxiv.org/abs/2303.11366) | Verbal RL: convert feedback to natural-language lessons, accumulate in episodic buffer, prepend to future runs. +22% AlfWorld, +11% HumanEval. No weight updates. |
| [ExpeL (AAAI 2024)](https://arxiv.org/abs/2308.10144) | Combines episodic recall (store successful trajectories) with generalization (extract insights across many trajectories). Performance improves as experience accumulates. |
| [OPRO (Google DeepMind)](https://arxiv.org/abs/2309.03409) | Feed (prompt, score) history to an LLM and ask it to propose a better prompt. The LLM optimizes by reading its own performance curve. Up to 50% improvement on BIG-Bench Hard. |
| [DSPy](https://dspy.ai/) | Production-grade prompt optimization. Runs pipeline against training examples, collects high-scoring trajectories, uses them to bootstrap few-shot examples, then does Bayesian optimization. |
| [ADAS / Meta Agent Search](https://arxiv.org/abs/2408.08435) | Archive of agent designs (as code). Meta-agent reads archive, programs a new design, evaluates, adds to archive. Discovers agents that outperform hand-designed ones. The long-term path for harness evolution. |
| [Voyager](https://arxiv.org/abs/2305.16291) | Skills library indexed by natural-language descriptions, retrieved by embedding similarity. New skills can call prior skills. The pattern for accumulating reusable operational procedures. |
| [EvoPrompt (ICLR 2024)](https://arxiv.org/abs/2309.08532) | Evolutionary algorithm over prompts. LLM performs mutation/crossover. Up to 25% improvement on BIG-Bench Hard. |
| [Tessl: From Prompts to AGENTS.md](https://tessl.io/blog/from-prompts-to-agents-md-what-survives-across-thousands-of-runs/) | Empirical study across thousands of agent runs. Key finding: cooperative refinement > parallel competition. Ephemeral prompt tweaks that work get promoted to persistent rule files. |
| [OpenAI Self-Evolving Agents Cookbook](https://cookbook.openai.com/examples/partners/self_evolving_agents/autonomous_agent_retraining) | Practical patterns for agents that retrain themselves: session trace storage, rule extraction, instruction file updates. |

---

### D. Agent Memory and Knowledge Sharing

The field has a useful taxonomy (from the CoALA paper) for thinking about memory types. The key split for orca is **procedural/operational memory** (how to work in this codebase, which patterns are effective) vs. **factual memory** (what things are). Factual memory is largely a solved problem; procedural memory is the open frontier.

**Key insight for orca:** The SWE-ContextBench finding is the most practically important: *summarized prior trajectories outperform raw trajectories and outperform no memory at all.* The distillation step — turning raw experience into actionable summaries — is what makes procedural memory usable. This directly informs how the knowledge base should be written: agents should summarize and distill, not just log.

The A-MEM (Zettelkasten) approach — giving memories contextual descriptions, keywords, and explicit links to related memories — is worth noting as a structural model for the knowledge base: not a flat append log, but a linked network of notes that accumulates cross-references over time.

The shared memory problem: naive shared appends create a noisy commons. Hierarchical approaches (agents promote local learnings to shared memory selectively) reduce noise.

| Source | What's relevant |
|---|---|
| [CoALA taxonomy](https://arxiv.org/abs/2309.02427) | Foundational four-type memory taxonomy: working (context window), episodic (past events), semantic (facts), procedural (how to act). Orca's knowledge base targets episodic + procedural. |
| [Letta Code](https://www.letta.com/blog/letta-code) | Sleep-time memory reflection: background process reviews recent history, writes procedural notes to persistent memory blocks. The closest existing system to what orca's knowledge base aims to do. |
| [Letta Context Repositories](https://www.letta.com/blog/context-repositories) | Git-based memory for coding agents. Codebase exploration builds persistent, versioned memory about architecture and conventions. |
| [Letta: Benchmarking agent memory](https://www.letta.com/blog/benchmarking-ai-agent-memory) | Is a filesystem all you need? Benchmark results comparing memory approaches. |
| [Graphiti/Zep temporal KG](https://arxiv.org/abs/2501.13956) | Bi-temporal knowledge graph: tracks when events occurred AND when they were ingested. Hybrid retrieval (semantic + BM25 + graph traversal). 300ms P95 latency. Outperforms MemGPT on DMR. |
| [A-MEM (NeurIPS 2025)](https://arxiv.org/abs/2502.12110) | Zettelkasten-style agent memory: memories get contextual descriptions, keywords, links to related memories. Network accumulates cross-references. Richer retrieval than flat vector stores. |
| [SWE-ContextBench](https://arxiv.org/html/2602.08316) | Critical finding: summarized prior trajectories > raw trajectories > no memory. Distillation is essential. |
| [SWE-Bench-CL](https://arxiv.org/pdf/2507.00014) | Continual learning benchmark for coding agents. Measures whether agents accumulate procedural knowledge across a sequence of related tasks. |
| [Episodic memory position paper](https://arxiv.org/abs/2502.06975) | Argues episodic memory (specific past occurrences with context) is the specifically neglected component. Relevant for the "last time I tried X in this codebase it failed because Y" use case. |
| [Collaborative memory with access control](https://arxiv.org/abs/2505.18279) | Multi-agent shared memory with asymmetric and dynamic access constraints. Relevant when multiple agents write to the same knowledge base. |

---

### E. Cross-Domain Inspiration

Five domains outside AI/software engineering provide concrete mechanisms that map onto orca's design problems.

#### Stigmergy (Ant Colony / Swarm Intelligence)

Indirect coordination via environment modification. Agents deposit signals in a shared substrate; other agents sense and respond to signal intensity. No direct agent-to-agent communication. Signals decay over time (automatic garbage collection of stale state).

**Direct mapping:** beads issues *are* a stigmergic substrate — agents claim issues by modifying them, other agents avoid claimed issues. The knowledge base, if structured as an intensity-weighted log (entries gain weight when multiple agents converge on the same lesson), is a procedural pheromone trail. Pheromone evaporation maps to the stale-entry problem: old entries should decay unless reinforced.

| Source | |
|---|---|
| [Ant Algorithms and Stigmergy — Dorigo et al.](https://lia.disi.unibo.it/courses/2006-2007/PSI-LS/pdf/roli/dorigo2000-ant_algorithms_and_stigmergy.pdf) | Foundational paper. |
| [Stigmergy as generic coordination mechanism](https://www.academia.edu/2860075/Stigmergy_as_a_generic_mechanism_for_coordination_definition_varieties_and_aspects) | Formalizes the mechanism for software applications. |

#### Auftragstaktik / Mission Command

Give objectives + context, never method. Subordinates are obligated to deviate from orders when deviation better serves the intent. Trust is pre-built through shared doctrine.

**Direct mapping to orca:** a task spec should contain (a) the end state, (b) why it matters and what constraints are real, (c) available resources — never the method. The critical failure mode: freedom without competence produces chaos. Agents given autonomy they cannot use productively behave worse than agents given tighter constraints. Autonomy grants should be proportional to demonstrated capability.

| Source | |
|---|---|
| [Mission-type tactics — Wikipedia](https://en.wikipedia.org/wiki/Mission-type_tactics) | Overview with historical context. |
| [The Trouble with Mission Command — Joint Force Quarterly](https://ndupress.ndu.edu/Portals/68/Documents/jfq/jfq-86/jfq-86_94-100_Hill-Niemi.pdf) | Failure modes: reverts to detailed orders under pressure; collapses when subordinate judgment is poor. |

#### Toyota Production System — Andon / Pull / WIP Limits

Andon: any worker can stop the line when a defect is detected. Pull: work is requested downstream, not pushed upstream. WIP limits: explicit cap on in-flight work; hitting the cap forces completion before new starts.

**Direct mappings:** Andon → agents should halt and signal rather than produce low-quality output silently. Pull → agents pull work from the queue when ready, not pushed by a scheduler. WIP limits → global cap on simultaneously in-progress beads issues prevents the system from having many partially-completed tasks and no finished ones.

| Source | |
|---|---|
| [Andon Cord — Toyota](https://mag.toyota.co.uk/andon-toyota-production-system/) | Original mechanism. |
| [Kanban (development) — Wikipedia](https://en.wikipedia.org/wiki/Kanban_(development)) | David Anderson's software translation of pull systems and WIP limits. |

#### MVCC (Multi-Version Concurrency Control)

Readers never block writers; writers never block readers. Each transaction operates on a versioned snapshot of state. Conflicts detected at commit time, not at read time. Old versions retained until no active transaction can see them.

**Direct mapping:** git branching *is* MVCC for source trees. Each agent worktree is a snapshot. The merge step is the commit. The flock-based lock is the serialization point. MVCC's optimistic model — assume no conflict, detect at commit — is already what orca implements. The version retention property is relevant to A/B testing: both versions of the harness can operate on concurrent snapshots of the task queue without contaminating each other.

| Source | |
|---|---|
| [CMU 15-445 MVCC lecture](https://15445.courses.cs.cmu.edu/spring2023/notes/18-multiversioning.pdf) | Thorough technical explanation. |
| [Implementing MVCC — Phil Eaton](https://notes.eatonphil.com/2024-05-16-mvcc.html) | Accessible implementation walkthrough. |

#### Clinical Trial Methodology

Randomization distributes confounders across groups. Pre-registration prevents post-hoc metric selection. Blinding prevents observer bias. Primary endpoint selection controls multiple-comparison error inflation. Sample size / power calculation determines how many trials are needed.

**Direct mapping to version comparison:** assign tasks randomly to versions A and B (not cherry-pick). Define the primary metric before running (not after seeing results). Have the evaluator assess results without knowing which version produced them. Calculate required N before running. The CONSORT 25-item checklist for trial reporting is directly adaptable as a template for documenting orca version comparison experiments.

| Source | |
|---|---|
| [Randomized controlled trial — Wikipedia](https://en.wikipedia.org/wiki/Randomized_controlled_trial) | Method overview. |
| [CONSORT 2010 — PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC2844943/) | The reporting standard. Adaptable as a version comparison documentation template. |

#### The Auftragstaktik / PID Windup Convergence

The cross-domain research revealed a non-obvious unification: **the failure mode of mission command and the failure mode of integral windup in PID control are structurally identical.** Both describe a system where authority to act has been granted in excess of the system's actual capacity to use it well. Auftragstaktik collapses when subordinates lack the trained judgment to exercise initiative usefully. PID windup collapses when the integrator accumulates correction authority the actuator cannot apply. The design principle in both cases: bound autonomy grants to demonstrated capability, and build in saturation detection that prevents runaway accumulation when the system is not responding.

For orca: the degree of autonomy granted to agents (in task scope, in self-modification authority, in harness change access) should be calibrated to demonstrated agent capability at each level, with explicit caps on accumulated authority when corrections are not having the intended effect.

| Source | |
|---|---|
| [PID Theory — NI](https://www.ni.com/en/shop/labview/pid-theory-explained.html) | Clear explanation of P/I/D terms and failure modes. |
| [Integral Windup — Wikipedia](https://en.wikipedia.org/wiki/Integral_windup) | The specific failure mode and anti-windup approaches. |

---

## Known Risks and Watch Points

Risks identified during design review. These are not blockers — they are behavioral and emergent properties that may or may not materialize. Each has a detection signal and a potential response.

---

### Risk 1: Knowledge base becomes write-only

**The concern:** The design makes it easy to write to the knowledge base (agents append at end of run) and has a curation plan (the librarian). But there is no mechanism ensuring agents actually *read* the knowledge base during work. The mandatory context has a pointer — "see `knowledge/` for accumulated operational guidance" — but a pointer is weak. An agent under context pressure will skip optional reads. If agents rarely read the knowledge base, writing to it is wasted effort, and the librarian is maintaining a library nobody visits.

**Detection signal:** Knowledge base entries are not reflected in agent behavior. The same mistakes recur despite being documented. The librarian finds entries that no agent has ever referenced.

**Potential response if detected:** Strengthen the pointer. Options range from mild (make the pre-run prompt more directive about reading relevant entries) to structural (a pre-run step that injects relevant knowledge base entries based on the claimed issue's topic or keywords). The right strength depends on how severe the problem is in practice.

---

### Risk 2: Artifact quality degrades silently

**The concern:** All non-worker roles depend on artifact quality — run summaries, beads notes, knowledge base entries. The document correctly classifies this as "a quality expectation, not a technical constraint." This means quality will be exactly as good as agents' intrinsic tendency to write good summaries, which in practice varies. Structural validation (fields present, types correct) is not the same as semantic quality (the summary actually describes what happened). If summary quality is low, the inspector roles become unreliable and the librarian has poor raw material to work with.

**Detection signal:** Inspector queries return vague or unhelpful answers. The developer finds that reading run artifacts directly is more useful than asking the inspector. Librarian runs produce thin output because there is little substance to consolidate.

**Potential response if detected:** Add mechanical quality checks without overstepping into policy. Options: minimum summary length, required presence of specific semantic fields (what was attempted, what succeeded, what failed), or a lightweight post-run LLM evaluation of summary quality before accepting the run as complete. Start with the simplest check that addresses the observed gap.

---

### Risk 3: No feedback loop from inspector to in-flight workers

**The concern:** The inspector can observe problems. The steer role can reprioritize the queue. But if the inspector notices a *pattern* — agents are consistently making a certain kind of mistake, or consistently ignoring a knowledge base entry — there is no mechanism to turn that observation into a change in worker behavior within the current session. The inspector would need to create a knowledge base entry or a harness-improvement issue and hope a future agent reads it. The developer is the real-time feedback loop.

**Detection signal:** The developer finds themselves repeatedly relaying inspector findings to workers manually, or stopping and restarting agents to pick up corrected guidance.

**Potential response if detected:** This is intentionally not solved in the current design — inter-agent communication during runs adds significant complexity and fragility. The first response should be to improve the knowledge base read path (see Risk 1), so that corrections written by inspectors are picked up by workers on their next run. If that is insufficient, a lightweight signaling mechanism (e.g., a file that workers check at loop boundaries) could be considered, but this is a significant design change that should be evaluated carefully before building.

---

## Resolved Questions

Questions that were open during design and have been settled. Kept here as a record of the reasoning.

---

**Q: What is the right lock granularity for concurrent knowledge base writes?**

**A: No extra locking needed.** Agents work in isolated worktrees and the existing merge lock serializes the merge step. Git's merge machinery auto-resolves concurrent appends cleanly. The one risk — concurrent edits to INDEX.md — is eliminated by making INDEX.md append-only by convention, with restructuring reserved for the librarian role. See section 3 (write protocol) and section 4 (librarian role).

---

**Q: Should the inspector prompt be templated or freeform?**

**A: Multiple purpose-specific templates, with freeform as the escape hatch.** A single template covering all inspector use cases would either be too generic to be useful or reproduce the context-bloat problem. The design uses a role taxonomy (section 4): inspector-status, inspector-review, inspector-steer, and librarian each get a focused prompt. Freeform invocation handles one-off queries that don't fit a template.

---

**Q: What is the minimum harness version identifier?**

**A: `git describe --always --dirty`.** Zero maintenance, always correct, human-readable when tagged. See DD-2 for the full rationale and alternatives considered.

---

**Q: How should stale knowledge base entries be handled?**

**A: The librarian role.** Knowledge base maintenance is a first-class agent role, not a periodic timer or an agent afterthought. The librarian consolidates, resolves contradictions, distills verbose entries, and removes stale content. Runs are triggered by knowledge base size thresholds or developer initiative. See section 4 (librarian role) for details.
