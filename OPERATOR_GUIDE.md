# Orca Operator Guide

## Purpose

Orca is a local, multi-worktree execution harness for running autonomous coding agents in parallel. It manages session transport and observability while leaving task policy and judgment to agents.

Use Orca when you want to:

1. run multiple agents concurrently with isolated git worktrees
2. keep a durable run loop without manual re-launch for every issue
3. preserve strong observability via logs, summaries, and metrics

## Intent and Design Principles

See `docs/design.md` for Orca's design principles and architectural constraints.
See `docs/operating-modes.md` for the proposed `execute|explore` profile model and experiment plan.
Mode/approach profile work is sequenced as optional overlays after the assignment-first planner baseline; it does not alter assignment/claim invariants.

Current operating stance: autonomy with explicit protocol guidance (Option C; see `docs/decision-log.md`, DL-001). Operators should monitor protocol deviations through run artifacts and escalate to stronger enforcement only when violations become costly or frequent.

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
```

Also ensure:

1. your configured `AGENT_COMMAND` is available and authenticated
2. repo has push access to `origin`
3. queue workspace exists (`br init`, once)
4. queue ID prefix is configured (`br config set id.prefix orca`, once)
5. queue has actionable work (`br ready --json`)

For guided setup on Ubuntu/WSL:

```bash
./orca.sh bootstrap --yes
./orca.sh bootstrap --yes --dry-run
```

Run a preflight before first launch (or after environment changes):

```bash
./orca.sh doctor
./orca.sh doctor --json
```

`doctor` is read-only and returns a non-zero exit code only for hard requirement failures.
`bootstrap` is mutating unless `--dry-run`; it fails hard when Codex authentication is still required.

## Queue Sync and Concurrency Model

1. `br` collaboration is git-based and async (`.beads/issues.jsonl`), not a central queue server.
2. `--claim` is atomic per SQLite DB snapshot.
3. Orca agents run in separate worktrees, so stale snapshots can still race unless claims are published centrally.
4. Orca policy uses `queue-write-main.sh` on `ORCA_PRIMARY_REPO/main` for queue mutations before/after coding as needed.
5. Run branches must not carry `.beads/` changes; integration is code-only.
6. Sync expectations:
   - import before claim/select (`br sync --import-only`)
   - queue helper performs import/flush around each queue mutation
   - commit/push `.beads/` updates on `main` as part of helper workflow

Queue mutation and merge/push share one writer lock scope (`ORCA_LOCK_SCOPE`, default `merge`) so all local `main` writes serialize.
Local source-of-truth policy: local `main` is the default base for local setup and per-run branch creation; `origin/main` remains a sync peer and fallback. If they diverge, Orca warns with ahead/behind counts and still defaults to local `main`.

Run branches (`swarm/agent-*`, `swarm/*-run-*`) are local transport state in this model; do not push them to origin during normal local operation.

Cross-machine note: lock files are local to each clone. Global contention resolves through git publication order on `main`; failed claim publication should be treated as a race and retried with a fresh import.

## Issue Parallel-Safety Metadata

Orca supports lightweight label metadata to describe whether issues are safe to run concurrently.

Label taxonomy:

1. `px:exclusive`: the issue must run alone.
2. `ck:<key>`: contention key; issues with the same key should not run in parallel.

Precedence:

1. `px:exclusive` always overrides `ck:*`.
2. Unlabeled issues are considered parallel-allowed by default.

Authoring guidance:

1. Use `px:exclusive` for work with broad blast radius or uncertain overlap.
2. Use `ck:<key>` for bounded contention areas (for example `ck:queue`, `ck:docs`, `ck:agent-loop`).
3. Reuse stable keys by subsystem so scheduling behavior stays predictable across sessions.
4. Do not add labels by default; only label when you know there is real contention risk.

## Core Workflow

### 1) Setup

```bash
./orca.sh setup-worktrees 2
```

`setup-worktrees` picks base refs in this order: `ORCA_BASE_REF`, local `main`, `origin/main`, then current branch fallback. When `ORCA_BASE_REF` is set, setup fails fast if it does not resolve to a commit. When local `main` and `origin/main` differ, setup emits a warning with ahead/behind counts and still defaults to local `main`.

### 2) Start Loop Sessions

```bash
./orca.sh start 2 --continuous
```

`orca start` validates the local `br` workspace (`.beads/`) and fails fast when the queue workspace is missing/unhealthy or a non-running agent worktree is dirty.
In default `assigned` mode, `start.sh` calls `plan.sh` to deterministically select launch assignments using queue labels (`px:exclusive`, `ck:*`) and writes an audit artifact under `agent-logs/plans/YYYY/MM/DD/`.
Launch logs include planned per-session issue IDs, held/skipped reason codes, and per-issue planner decisions, so reduced launch counts are explainable from a single run log.
Default no-work behavior is drain mode: after a small retry budget for transient races, loops stop on sustained `no_work`.
Use `--watch` to keep polling on `no_work` instead.

Bounded mode:

```bash
./orca.sh start 2 --runs 5
```

`--runs N` is an upper bound (maximum iterations per agent loop), not a requirement to consume all runs when earlier stop conditions apply.

Watch/poll mode override:

```bash
./orca.sh start 2 --continuous --watch
```

### 3) Monitor

```bash
./orca.sh status            # quick mode (default)
./orca.sh status --full     # detailed diagnostics
./orca.sh status --quick --session-prefix "orca-agent-1-20260311T07"   # scope to matching sessions
./orca.sh status --full --session-id "<session-id>"                     # scope to one exact session
./orca.sh wait --session-id "<session-id>" --timeout 900 --json         # block for completion
find agent-logs/sessions -type f | sort | tail -n 20
tail -n 10 agent-logs/metrics.jsonl
```

`orca status` defaults to quick mode for frequent checks. Use `--full` when you need complete `br` diagnostics, worktree hygiene detail, and extended metrics sections. Both modes show scoped active run state (`state=running|idle`) and support session scoping with `--session-id` / `--session-prefix`.
`orca wait` is the non-interactive blocking primitive for automation. It supports the same session scoping (`--session-id` / `--session-prefix`) and returns deterministic exit codes (`0` success, `2` timeout, `3` scoped failure, `4` invalid usage/config). When no scoped sessions exist at invocation time, it returns immediate success with reason `no_scoped_sessions`.

### 4) Stop

```bash
./orca.sh stop
```

`orca stop` stops running Orca sessions (if any).

## What the Loop Does vs What Agents Do

Orca loop (`agent-loop.sh`) does:

1. validate explicit `ORCA_BASE_REF` overrides, then prepare a per-run branch (`ORCA_BASE_REF`, otherwise `main`, then `origin/main`, then current branch; warns when `main` and `origin/main` diverge) and run one agent pass per iteration
2. provide prompt + run artifact paths
3. parse summary JSON and append metrics
4. in default `drain` mode, stop on sustained `no_work` after `ORCA_NO_WORK_RETRY_LIMIT + 1` consecutive `no_work` results
5. continue until an early stop condition is met (`MAX_RUNS` upper bound, no-work drain stop, or agent-requested stop)

Agent does:

1. choose issues and publish claims via `ORCA_QUEUE_WRITE_MAIN_PATH`
2. implement and validate
3. update issue states/notes/follow-up issues via `ORCA_QUEUE_WRITE_MAIN_PATH`
4. merge/push via `ORCA_MERGE_MAIN_PATH`
5. close issues via `ORCA_QUEUE_WRITE_MAIN_PATH`
6. create follow-up issues when needed and write summary JSON

Orca injects `ORCA_WITH_LOCK_PATH`, `ORCA_PRIMARY_REPO`, `ORCA_LOCK_SCOPE`, `ORCA_LOCK_TIMEOUT_SECONDS`, `ORCA_QUEUE_WRITE_MAIN_PATH`, `ORCA_MERGE_MAIN_PATH`, `ORCA_BASE_REF`, `ORCA_NO_WORK_DRAIN_MODE`, and `ORCA_NO_WORK_RETRY_LIMIT` into each run so helper scripts can use stable absolute paths.
`ORCA_PRIMARY_REPO` defaults to repo root and must be a valid git worktree; `ORCA_WITH_LOCK_PATH` defaults to `<repo-root>/with-lock.sh` and must be executable.

## Operating Playbook

### Daily Start

```bash
git pull --rebase
br sync --import-only
./orca.sh start 2 --continuous
./orca.sh status
```

### Live Checks

```bash
br ready --json
br list --status in_progress --limit 50
br list --status closed --sort updated --reverse --limit 20
```

Run-branch cleanup (dry-run by default):

```bash
./orca.sh gc-run-branches
./orca.sh gc-run-branches --apply
```

`gc-run-branches` only prunes local `swarm/*-run-*` branches that are already merged into `main` and not active in any worktree or active agent tmux session.

Attach to a session:

```bash
tmux attach -t orca-agent-1
# detach: Ctrl+b then d
```

### Scale Up / Down

Scale up:

```bash
./orca.sh start 3 --continuous
```

Scale down cleanly:

```bash
./orca.sh stop
./orca.sh start 2 --continuous
```

## Failure Handling

1. Agent requests stop (`loop_action=stop`):
   - expected for no-work or explicit shutdown conditions
   - inspect latest `summary.json` / `summary.md` under `agent-logs/sessions/.../runs/...`, then restart if needed
2. Claim publication failures/races:
   - expected signal when multiple agents/machines compete for same issue
   - winning claim is the one successfully published to `main`
   - losing agent should re-import queue state and select another issue
3. Merge/push failures:
   - agent-owned; inspect logs and issue notes, then restart sessions as needed
   - `merge-main.sh` enforces dirty-tree precheck and rejects source branches containing `.beads/` changes
   - `merge-main.sh` performs merge-failure cleanup (`merge --abort` / reset path) so primary repo does not stay conflicted
4. Immediate agent command failures:
   - verify CLI auth/config and `AGENT_COMMAND`
5. Run branch setup failure due dirty worktree:
   - check `git -C worktrees/agent-N status --short`
   - inspect for leftover `.beads/` or partial code edits
   - commit/stash/discard changes in that worktree, then rerun `./orca.sh start`
6. Protocol drift (deviations from queue/merge protocol):
   - inspect `summary.json`/`summary.md` notes and `run.log` for justification
   - if repeated and costly, record incident and reopen constraint strategy per `docs/decision-log.md` DL-001

## Safety Rules

1. avoid destructive git commands during active swarm sessions
2. avoid manually editing multiple agent worktrees at once unless deliberate
3. keep `br` queue state as source of truth for issue state and dependencies
4. keep queue writes in `ORCA_QUEUE_WRITE_MAIN_PATH` and merges in `ORCA_MERGE_MAIN_PATH` (both lock-guarded)

## Operator Checklist

Before ending a session:

1. active failures are understood and noted
2. blockers are reflected in issue notes
3. important follow-up work is represented in `br` issues
4. local repo state is synchronized and pushed per normal repository workflow
