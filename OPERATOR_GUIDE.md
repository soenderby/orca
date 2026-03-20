# Orca Operator Guide

## What Orca Does

Orca is a batch execution engine for autonomous coding agents. It takes a queue of issues, assigns them to parallel agent slots, executes agents in isolated git worktrees with safe locking and merge primitives, captures structured run artifacts, and stops when work is done.

Orca is per-project. Each repo has its own queue, worktrees, and artifacts. See `docs/ecosystem.md` for how orca fits with other tools (watch, lore).

## Prerequisites

```bash
git --version && br --version && tmux -V && jq --version && flock --version
```

Your configured `AGENT_COMMAND` must be available and authenticated. The repo needs push access to `origin`.

For guided setup on Ubuntu/WSL:

```bash
./orca.sh doctor
./orca.sh bootstrap --yes
./orca.sh doctor
```

## Core Workflow

### 1. Queue Work

Create issues via `br`:

```bash
br create "Fix the widget parser" --description "..." --priority 1
```

Add contention labels when issues touch shared subsystems:

- `px:exclusive` — must run alone
- `ck:<key>` — contention key; issues with same key won't run in parallel
- `meta:tracker` — coordination issue, excluded from agent assignment

### 2. Run a Batch

```bash
./orca.sh start 2 --runs 1
```

This assigns ready issues to agents via the planner, launches tmux sessions, and runs. Default mode is `assigned` with `--runs 1` (one issue per agent, then stop).

For continuous drain of a well-specified queue:

```bash
ORCA_ASSIGNMENT_MODE=self-select ./orca.sh start 2 --continuous
```

Or auto-relaunch waves:

```bash
./dispatch-loop.sh --max-slots 2 --poll-interval 20
```

### 3. Check Status

```bash
./orca.sh status          # human-readable
./orca.sh status --json   # machine-readable
```

To attach to a running agent session:

```bash
tmux attach -t orca-agent-1
# detach: Ctrl+b then d
```

### 4. Stop

```bash
./orca.sh stop
```

### 5. Review

Check run artifacts:

```bash
find agent-logs/sessions -name summary.json -newer /tmp/last-check | xargs jq '.result, .issue_id, .notes'
tail -5 agent-logs/metrics.jsonl | jq '{result, issue_id, tokens_used}'
```

### 6. Cleanup

```bash
./orca.sh gc-run-branches          # dry-run
./orca.sh gc-run-branches --apply  # delete merged run branches
```

## What Orca Does vs What Agents Do

**Orca does:** validate environment, prepare run branches, render prompts, execute agents, parse summaries, append metrics, enforce drain policy, manage locks and merges.

**Agents do:** claim issues, implement changes, run validation, update queue state, merge code, create follow-up issues, write summary JSON.

## Queue Safety

- Queue mutations go through `queue-write-main.sh` (lock-guarded on `main`).
- Merges go through `merge-main.sh` (lock-guarded, rejects `.beads` in source branches).
- Run branches are local transport state; they are not pushed to origin.
- Both operations share one writer lock to serialize all `main` writes.

## Failure Handling

1. **Agent requests stop** — inspect latest `summary.json`, restart if needed.
2. **Claim races** — expected when multiple agents compete. Losing agent retries.
3. **Merge failures** — inspect logs. `merge-main.sh` auto-cleans merge state.
4. **Dirty worktree on start** — `git -C worktrees/agent-N status --short`, then commit/stash/discard.

## Runtime Knobs

Key knobs (see README.md for full list):

- `AGENT_MODEL` — model for agent command (default `gpt-5.3-codex`)
- `AGENT_REASONING_LEVEL` — optional reasoning effort level
- `MAX_RUNS` — upper bound on runs per agent loop
- `ORCA_ASSIGNMENT_MODE` — `assigned` (default) or `self-select`
- `ORCA_NO_WORK_DRAIN_MODE` — `drain` (default) or `watch`

## Documentation

- `README.md` — commands and configuration reference
- `docs/design.md` — design principles
- `docs/ecosystem.md` — broader tool ecosystem (orca, watch, lore)
- `docs/artifact-contract.md` — output format specification
- `docs/decision-log.md` — architecture decisions
- `AGENT_PROMPT.md` — agent contract
