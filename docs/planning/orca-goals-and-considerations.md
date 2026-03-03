# Orca: Goals, Considerations, and Design Principles

Working document. Captures what has been established through analysis of the existing system, its redesign plan, and critical examination of what the project is actually trying to achieve.

Status: Draft — establishing foundations before implementation.

---

## What Orca Is

Orca is an umbrella for a set of related tools that help a single developer use LLM agents effectively. The tools share infrastructure but serve different purposes and have different stability requirements.

Orca is also a learning vehicle. Building and operating these tools develops the operator's mental models for how to use LLM agents well. This is a legitimate and primary goal, not a secondary effect.

## The Core Problem

The developer has large tasks to complete. LLM agents can execute these tasks, but getting agents to execute them *well* requires significant upstream work: task definition, constraint communication, information organization. The primary bottleneck is not agent execution — it is task specification.

Observed failure modes in agent execution trace back to specification gaps:

- Agents overengineer because the task spec doesn't communicate design intent (e.g., "minimal first pass, no premature abstractions").
- Agents miss constraints because constraints weren't explicitly stated.
- Agents pick a direction without validating it because nothing in the workflow forces a checkpoint before execution.
- Agents build enterprise-grade implementations by default because their training prior favors production-style code.

The batch farm (autonomous agent execution) works. The existing system achieved approximately 80% success rate across 30–50 runs with 2 parallel agents, implementing a project end-to-end. The 20% failure rate and the need for significant rework on some successes are primarily upstream problems, not execution problems.

## What Orca Is Not

Orca is not a single monolithic system. The different capabilities it provides have different UX patterns, reliability requirements, and rates of change. Treating them as one system couples experimental components to stable ones.

Orca is not an AI agent framework. It does not abstract over LLM providers, manage prompt chains, or provide agent-building primitives. It is a *harness* — it manages the environment agents run in, not the agents themselves.

Orca is not a mature system that needs mature-system infrastructure. A/B testing with statistical rigor, evolutionary self-modification, and automated prompt optimization are future possibilities. They should not be designed into the foundation.

---

## The Three Layers

Orca's capabilities separate into three layers with shared infrastructure but independent interfaces and lifecycles.

### Layer 0: Shared Primitives

Worktree management, lock helpers, metrics logging, session management (tmux), and agent invocation. These are plumbing. They do not encode policy. They are the most stable layer and should change the least.

This layer largely exists already in the current Orca implementation.

### Layer 1: The Batch Farm (`orca run`)

Autonomous multi-agent execution against a work queue. Agents pull tasks, implement them in isolated worktrees, and merge results. The harness manages the loop, records artifacts, and handles coordination invariants (locking, claiming).

This is the most mature component. Its job is throughput and reliability. It should remain the simplest layer in terms of policy — the harness handles transport, agents handle decisions.

Key properties:
- Fire-and-forget from the operator's perspective
- Needs robustness — should not require babysitting
- Produces artifacts (logs, summaries, metrics) that other layers consume

### Layer 2: Interactive Agents (`orca ask`)

On-demand, single-shot or short-lived agent sessions with purpose-specific context. Examples:

- A critic that stress-tests an idea or plan
- A librarian that helps find and organize information
- A decomposer that helps break large goals into well-specified tasks
- A reviewer that analyzes batch farm output

These are interactive, conversational, and don't need batch infrastructure. They share worktree primitives and metrics logging with Layer 1 but little else.

Key properties:
- Interactive — the operator is in the loop
- Experimental — new agent types are added and discarded frequently
- Highest rate of change of any layer

### Layer 3: Analysis (`orca inspect`)

Read-only tools that operate over artifacts produced by other layers. "What went wrong in the last 10 runs?" "Which tasks took longest?" "What patterns appear in failures?"

This layer turns raw stdout files, metrics, and summaries into queryable information. It is where the operator's learning happens.

Key properties:
- Read-only — never modifies state
- Value grows with accumulated data
- Can be as simple as grep and jq, or as sophisticated as an LLM analyzing logs

---

## Design Principles

These are derived from experience operating the existing system, not from theory.

### 1. Remove friction before adding constraints

Removing friction (e.g., the merge lock) is almost always safe — it doesn't change what agents can do, it makes what they already do cheaper. Adding constraints is dangerous because it limits behaviors that may be useful in ways the constraint designer didn't anticipate.

Evidence: the merge lock reduced ~20% of wasted agent effort with no downside. Overly restrictive fixes added later had to be removed because they reduced agent effectiveness to avoid rare edge cases.

Rule: only add constraints when there is repeated evidence of the same specific failure mode, and instrument them so their impact can be measured.

### 2. Enforce invariants mechanically, not instructionally

If skipping something causes a correctness failure, the agent should not be able to skip it. If skipping it is merely suboptimal, leave it to agent judgment.

The merge lock is a good example: it is mechanically enforced, invisible to agents as a choice they could make. Contrast with "always run tests before merging" — that's guidance, not an invariant, and should not be enforced the same way.

### 3. The harness handles transport; agents handle decisions

The harness manages loops, worktrees, artifacts, locks, and coordination. It does not decide what agents should do, how they should approach a problem, or what constitutes good output. Over-specification in the harness is a form of lock-in that prevents agents from finding better approaches.

### 4. Optimize for learning speed, not system completeness

The project is experimental. The operator's understanding of how to use agents effectively is still developing. Decisions about what to build should prioritize generating insight over building permanent infrastructure.

This means: analyze existing data before building new features. The 30–50 runs of raw stdout are a dataset. Failure analysis, pattern recognition, and hypothesis formation are higher-value per hour than infrastructure work.

### 5. Separate stable from experimental

Components with different rates of change should not be coupled. Layer 0 (primitives) should be stable. Layer 1 (batch farm) changes slowly. Layer 2 (interactive agents) changes constantly. Layer 3 (analysis) grows incrementally.

Experimentation with new approaches should not require modifying stable components. The architecture should allow swapping prompts, agent types, and workflows without touching the core loop.

### 6. Task specification is the bottleneck

The batch farm's effectiveness is bounded by the quality of what it's given to work on. Improving agent execution from 80% to 90% matters less than improving task specification so the 20% failure cases don't arise.

This means tools that help the operator create better task specifications (Layer 2 interactive agents) may deliver more value than improvements to the execution layer (Layer 1).

### 7. Strategy is architectural; plans are tactical and revisable

Strategic docs define architecture and durable principles. Tactical plans execute pieces of that strategy (for example, a runtime migration) with bounded scope and measurable outcomes.

The environment is not static: model/runtime behavior, repository structure, and workflow pressures change over time. Tactical execution can surface information that invalidates earlier assumptions. Both plans and strategy should therefore be updateable through an explicit evidence loop: hypothesis -> canary -> measurement -> decision (promote/hold/rollback) -> document update.

---

## Open Questions

### What is the right task granularity?

Hypothesis: too-small tasks were a significant detriment in the existing system. Possible mechanisms:

- **Coordination overhead dominates.** Small tasks mean more merges, more context switches, more claiming, more summary-writing relative to useful work.
- **Small tasks lose architectural context.** An agent working on a narrow task doesn't see the broader design.
- **Decomposition introduces interface errors.** Assumptions about how sub-tasks connect may be wrong.

The raw stdout from existing runs could answer which mechanism dominates. This analysis should happen before building new infrastructure.

### How should success be measured?

Candidate metrics: features implemented per session, tokens consumed, wall-clock time per task, failure rate, rework rate. Plus subjective operator evaluation.

No single metric captures "better." A composite approach is likely necessary, but the specific metrics and their weights are undefined. Starting simple (completed tasks per session) and adding nuance as patterns emerge is preferable to designing a comprehensive metrics framework upfront.

### How should agents be prevented from overengineering?

The observed pattern — agents defaulting to enterprise-grade implementations — is a task specification problem more than an agent behavior problem. The model's training prior favors production code.

Potential approaches:
- Task specs that explicitly carry design intent ("minimal first pass, no abstractions not justified by current requirements")
- A plan-then-execute workflow where the agent produces a plan that is validated before implementation begins
- Constraints on scope (file count, line count, complexity thresholds) — but these risk the over-restriction problem

The plan-then-execute approach is the most promising because it addresses the "pick a direction and go without checking" failure mode directly. Whether this is a harness feature (the loop enforces a planning phase) or a prompt feature (the task spec asks for a plan first) is an open design question.

### What role does experimentation play?

The operator wants to try different approaches and compare them. This does not require formal A/B testing infrastructure. It requires:

- A design that makes it easy to swap components (prompts, workflows, configurations) without modifying stable infrastructure
- Metrics that are recorded consistently so before/after comparisons are possible
- Version attribution in metrics so runs can be traced to the configuration that produced them

Formal experimentation infrastructure (reproducible starting states, statistical comparison) is a future capability, not a current requirement. The design should not prevent it, but should not build toward it either.

---

## Evidence Base

### What has been tried and worked

- Git worktree per agent as the isolation primitive — independently convergent across multiple projects in the space
- Serialized merge locking via flock — eliminated merge-related friction (~20% of agent effort)
- Raw stdout capture per session — the most valuable observability tool, enabling failure analysis and pattern recognition
- Structured run summary JSON — enables automated metrics and status reporting

### What has been tried and failed

- Overly restrictive behavioral constraints — reduced agent effectiveness to prevent rare edge cases; had to be removed
- Very small task granularity (suspected) — coordination overhead may dominate useful work at small task sizes

### What has not been tried but is hypothesized

- Explicit design intent in task specifications as a fix for overengineering
- Plan-then-execute workflow to catch bad directions early
- Larger task granularity to reduce coordination overhead ratio
- Interactive agents for task specification and information organization (Layer 2)
- LLM-based analysis of existing run data (Layer 3)

---

## Relationship to Existing Work

The redesign document (`orca-redesign.md`) contains valuable research and analysis that remains relevant as reference material. The following elements from it are carried forward:

- The mandatory vs. optional context split (coordination protocol vs. operational knowledge)
- The principle that harness invariants should be enforced mechanically
- The knowledge base concept (though its priority is lower than task specification improvements)
- The agent role taxonomy (reframed as Layer 2 interactive agents rather than permanent system roles)
- The cross-domain insights (stigmergy, Auftragstaktik, Toyota Production System, MVCC) as mental models

The following elements are deferred or deprioritized:

- A/B testing infrastructure with statistical rigor — premature for current system maturity
- Evolutionary self-modification — requires evaluation infrastructure that doesn't exist
- Librarian as a permanent automated role — better served as an on-demand interactive agent
- Formal knowledge base write protocol — optimize for learning speed first

---

## Next Steps

Not prioritized. To be refined based on what analysis of existing run data reveals.

1. Analyze existing run data (stdout logs from 30–50 runs) to characterize failure modes and validate the task-granularity hypothesis
2. Define the Layer 0 primitive interface — what do all layers share?
3. Build a minimal Layer 2 prototype — an interactive agent for task specification that carries explicit design intent
4. Formalize metrics recording with version attribution (harness version in every metrics row — low cost, high prerequisite value)
5. Design the plan-then-execute checkpoint as either a harness or prompt feature
