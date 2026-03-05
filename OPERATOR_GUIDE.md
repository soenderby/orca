# Orca Operator Guide

## Purpose

Orca is a local, multi-worktree execution harness for running autonomous coding agents in parallel. It manages session transport and observability while leaving task policy and judgment to agents.

Use Orca when you want to:

1. run multiple agents concurrently with isolated git worktrees
2. keep a durable run loop without manual re-launch for every issue
3. preserve strong observability via logs, summaries, and metrics

## Intent and Design Principles

1. Transport over cognition:
   - Orca scripts handle execution plumbing (`tmux`, loop lifecycle, artifact paths, lock primitives).
   - Agents handle decisions (issue selection, status transitions, merge/close strategy, discovery handling).
2. Explicit primitives over hidden heuristics:
   - Provide lock, summary, and logging primitives.
   - Avoid encoding behavioral policy in scripts.
3. Agent-owned lifecycle:
   - Agents claim work, update issue status, merge/push, and close issues.
4. Operational clarity:
   - Every run leaves traceable artifacts (`run.log`, `summary.json`, `metrics.jsonl`, discovery logs).

## When to Use Orca

Use Orca when:

1. the queue has multiple independent tasks
2. you want predictable per-run artifacts and postmortem visibility
3. a human operator is available to monitor and intervene on hard failures

Avoid Orca when:

1. tasks are highly coupled and require frequent manual pair-design
2. a single high-risk migration needs tightly controlled sequential execution

## Prerequisites

From repo root environment, ensure:

```bash
git --version
br --version
tmux -V
jq --version
flock --version
codex --version
```

Also ensure:

1. you are authenticated in agent tooling (`codex login` if needed)
2. repo has push access to `origin`
3. queue workspace exists (`br init`, once)
4. queue ID prefix is configured (`br config set id.prefix orca`, once)
5. queue has actionable work (`br ready --json`)

## Core Workflow

### 1) Setup

```bash
./bb orca setup-worktrees 2
```

### 2) Start Loop Sessions

```bash
./bb orca start 2 --continuous
```

`orca start` validates the local `br` workspace (`.beads/`) and fails fast when the queue workspace is missing/unhealthy or a non-running agent worktree is dirty.

Bounded mode:

```bash
./bb orca start 2 --runs 5
```

### 3) Monitor

```bash
./bb orca status
find agent-logs/sessions -type f | sort | tail -n 20
tail -n 10 agent-logs/metrics.jsonl
```

`orca status` includes a `br` queue section (version, workspace health, sync status) plus agent-worktree hygiene alerts.

### 4) Stop

```bash
./bb orca stop
```

`orca stop` stops running Orca sessions (if any).

## What the Loop Does vs What Agents Do

Orca loop (`agent-loop.sh`) does:

1. run one agent pass per iteration
2. provide prompt + run artifact paths
3. parse summary JSON and append metrics
4. continue until run limit or agent-requested stop

Agent does:

1. choose and claim issues
2. implement and validate
3. update issue states and notes
4. merge/push using `ORCA_WITH_LOCK_PATH` against `ORCA_PRIMARY_REPO`
5. close issues
6. record discoveries and summary JSON

Orca injects `ORCA_WITH_LOCK_PATH` and `ORCA_PRIMARY_REPO` into each run so merge scripts can use stable absolute paths and avoid worktree-relative path mistakes.

## Operating Playbook

### Daily Start

```bash
git pull --rebase
br sync --import-only
./bb orca start 2 --continuous
./bb orca status
```

### Live Checks

```bash
br ready --json
br list --status in_progress --limit 50
br list --status closed --sort updated --reverse --limit 20
```

Dependency-merge guard for a candidate issue:

```bash
./check-closed-deps-merged.sh <issue-id>
```

If this guard fails, closed blocking dependencies are not yet represented on `main`; treat the issue as not executable in the current run.

Attach to a session:

```bash
tmux attach -t bb-agent-1
# detach: Ctrl+b then d
```

### Scale Up / Down

Scale up:

```bash
./bb orca start 3 --continuous
```

Scale down cleanly:

```bash
./bb orca stop
./bb orca start 2 --continuous
```

## Failure Handling

1. Agent requests stop (`loop_action=stop`):
   - expected for no-work or explicit shutdown conditions
   - inspect latest `summary.json` / `summary.md` under `agent-logs/sessions/.../runs/...`, then restart if needed
2. Agent claim races:
   - normal in parallel operation; agent should select another issue
3. Merge/push failures:
   - agent-owned; inspect logs and issue notes, then restart sessions as needed
   - ensure lock-guarded merge scripts use `set -euo pipefail` so early command failures cannot be masked
   - require a pre-merge cleanliness check on `ORCA_PRIMARY_REPO` (`git diff --quiet` and `git diff --cached --quiet`) so dirty `main` fails before fetch/merge
4. Immediate agent command failures:
   - verify CLI auth/config and `AGENT_COMMAND`
5. Run branch setup failure due dirty worktree:
   - check `git -C worktrees/agent-N status --short`
   - commit/stash/discard changes in that worktree, then rerun `./bb orca start`

## Safety Rules

1. avoid destructive git commands during active swarm sessions
2. avoid manually editing multiple agent worktrees at once unless deliberate
3. keep `br` queue state as source of truth for issue state and dependencies
4. keep shared-target writes inside `ORCA_WITH_LOCK_PATH` lock-guarded commands

## Operator Checklist

Before ending a session:

1. active failures are understood and noted
2. blockers are reflected in issue notes
3. important follow-up work is represented in `br` issues
4. local repo state is synchronized and pushed per `AGENTS.md`
