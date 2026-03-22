# Orca

Batch execution engine for autonomous coding agents. Manages transport — tmux sessions, git worktrees, locking, task queue coordination, structured artifact capture — so agents can focus on doing work.

See `docs/ecosystem.md` for how orca fits with watch (operator supervision) and lore (context management).

## Setup

```bash
./orca.sh doctor
./orca.sh bootstrap --yes
./orca.sh doctor
```

See `docs/setup.md` for detailed onboarding on Ubuntu/WSL.

## Usage

```bash
# Queue work
br create "Fix the widget parser" --description "..." --priority 1

# Run agents
./orca.sh start 2 --runs 1

# Check status
./orca.sh status

# Stop
./orca.sh stop
```

See `OPERATOR_GUIDE.md` for the full operating playbook.

## Cross-Project Operation

Orca can operate on any git repo, not just the repo it is installed in. Use `ORCA_HOME` or invoke orca by its full path:

```bash
cd /path/to/other-project
/path/to/orca/orca.sh doctor
/path/to/orca/orca.sh start 1 --runs 1
```

The target repo needs:
- A `br` queue workspace (`br init && br config set id.prefix <prefix>`)
- Optionally, an `ORCA_PROMPT.md` tailored to the project (orca's default is used as fallback)

Orca resolves scripts relative to `ORCA_HOME` (defaults to the directory containing `orca.sh`). The target repo provides worktrees, queue state, and agent logs.

## Commands

| Command | Purpose |
|---|---|
| `bootstrap [--yes] [--dry-run]` | Guided Ubuntu/WSL setup |
| `doctor [--json]` | Preflight readiness checks |
| `start [count] [--runs N] [--reasoning-level LEVEL]` | Launch agent sessions |
| `stop` | Stop active sessions |
| `status [--json]` | Session state and last results |
| `plan [--slots N] [--output PATH]` | Compute assignment plan |
| `dep-sanity [--strict]` | Check dependency graph hazards |
| `gc-run-branches [--apply]` | Prune merged run branches |
| `setup-worktrees [count]` | Create agent worktrees |

Helper commands (used by agents and scripts):

| Command | Purpose |
|---|---|
| `with-lock [--scope NAME] [--timeout S] -- <cmd>` | Scoped file lock |
| `queue-read-main [--fallback MODE] -- <cmd>` | Lock-guarded queue read on main |
| `queue-write-main [--actor NAME] -- <cmd>` | Lock-guarded queue mutation on main |
| `queue-mutate [--actor NAME] <mutation> [args]` | Safe queue mutation wrapper |
| `merge-main [--source BRANCH]` | Lock-guarded merge to main |

## Architecture

- `agent-loop.sh` — per-agent run loop: create branch, render prompt, execute agent, parse summary, append metrics
- `start.sh` — validates environment, runs planner, launches tmux sessions
- `plan.sh` — deterministic issue-to-slot assignment using queue labels (`px:exclusive`, `ck:*`, `meta:tracker`)
- `with-lock.sh` — shared lock primitive; queue mutations and merges both use this
- `queue-write-main.sh` + `queue-mutate.sh` — lock-guarded queue operations on main
- `merge-main.sh` — lock-guarded merge with `.beads` source-branch guard

## Artifacts

Orca produces structured artifacts for every run. See `docs/artifact-contract.md` for the full specification.

```
agent-logs/
├── metrics.jsonl                    # append-only metrics stream
└── sessions/YYYY/MM/DD/<session>/
    └── runs/<run-id>/
        ├── run.log                  # full run output
        ├── summary.json             # structured result (required)
        ├── summary.md               # human-readable summary
        └── last-message.md          # agent's final message
```

## Queue Safety

- All queue mutations go through `queue-write-main.sh` (lock-guarded on main)
- All merges go through `merge-main.sh` (lock-guarded, rejects `.beads` in source branches)
- Run branches are local transport state; not pushed to origin
- Both operations share one writer lock scope to serialize main writes
- Run-time `br` guard shim blocks direct mutation commands in agent worktrees

## Runtime Knobs

| Knob | Default | Purpose |
|---|---|---|
| `AGENT_MODEL` | `gpt-5.3-codex` | Model for agent command |
| `AGENT_REASONING_LEVEL` | (none) | Optional reasoning effort |
| `MAX_RUNS` | (from `--runs`) | Upper bound on runs per loop |
| `ORCA_ASSIGNMENT_MODE` | `assigned` | `assigned` or `self-select` |
| `ORCA_NO_WORK_DRAIN_MODE` | `drain` | `drain` or `watch` |
| `ORCA_NO_WORK_RETRY_LIMIT` | `1` | Retry budget for transient no-work |
| `ORCA_LOCK_SCOPE` | `merge` | Writer lock scope name |
| `ORCA_LOCK_TIMEOUT_SECONDS` | `120` | Lock acquisition timeout |
| `ORCA_PRIMARY_REPO` | repo root | Primary repo for lock-guarded ops |
| `ORCA_BASE_REF` | (auto) | Override base ref for worktrees/branches |
| `ORCA_FORCE_COUNT` | `0` | Bypass ready-queue launch cap |
| `ORCA_DEP_SANITY_MODE` | `enforce` | `enforce`, `warn`, or `off` |
| `ORCA_BR_GUARD_MODE` | `enforce` | `enforce` or `off` |
| `ORCA_MODE_ID` | (none) | Mode identifier for metrics |
| `ORCA_WORK_APPROACH_FILE` | (none) | Approach guidance for metrics |
| `ORCA_HOME` | (script dir) | Where orca scripts live (for cross-project use) |
| `SESSION_PREFIX` | `orca-agent` | Tmux session name prefix |
| `RUN_SLEEP_SECONDS` | `2` | Sleep between iterations |

## Documentation

| Document | Purpose |
|---|---|
| `OPERATOR_GUIDE.md` | Operating playbook |
| `ORCA_PROMPT.md` | Agent contract |
| `docs/design.md` | Design principles |
| `docs/ecosystem.md` | Tool ecosystem (orca, watch, lore) |
| `docs/artifact-contract.md` | Output format specification |
| `docs/decision-log.md` | Architecture decisions |
| `docs/user-stories.md` | Usage scenarios |
| `docs/setup.md` | Ubuntu/WSL onboarding |
| `docs/operating-modes.md` | Execute/explore mode profiles |
| `docs/dispatch-loop.md` | External auto-relaunch utility |
