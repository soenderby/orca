# Orca Scripts

This directory contains the Orca multi-agent orchestration scripts.

Orca uses transport-focused loop orchestration while agents own task policy and decisions.

## Documentation

Orca intentionally keeps documentation to three markdown files in this directory:

1. `README.md` (this file): technical reference and command/runtime details
2. `AGENT_PROMPT.md`: single consolidated instruction contract for loop agents
3. `OPERATOR_GUIDE.md`: human operator guide, including intent and design principles

## Prompt Migration Note

`AGENT_PROMPT.md` remains the active worker prompt in this phase.

Roadmap migration target:

1. mandatory coordination protocol in `scripts/orca/AGENTS.md`
2. optional operational guidance in `scripts/orca/knowledge/`

M0 adds strict run-summary schema enforcement and metrics version attribution; it does not yet switch prompt files.

## Entrypoints

- Preferred: `./bb orca <command> [args]`
- Direct: `scripts/orca/orca.sh <command> [args]`

## Commands

- `start [count] [--runs N|--continuous] [--reasoning-level LEVEL]`
- `stop`
- `status`
- `setup-worktrees [count]`
- `with-lock [--scope NAME] [--timeout SECONDS] -- <command> [args...]`
- `check-closed-deps-merged <issue-id> [target-ref]`

Helper script (direct invocation):

- `scripts/orca/with-lock.sh [--scope NAME] [--timeout SECONDS] -- <command> [args...]`
- `scripts/orca/check-closed-deps-merged.sh <issue-id> [target-ref]`

## TODO

In no particular order:

1. A/B testing prompts
2. Agent loop metrics in sqlite database
3. Agent loop handoff
4. Sharing or storing lessons learned from run
5. Streamline loop prompt (likely tied to A/B testing)

## Architecture Overview

Orca is a `tmux`-backed multi-agent loop with one persistent git worktree per agent:

1. `setup-worktrees.sh` creates missing `worktrees/agent-N` on branch `swarm/agent-N` and reuses existing worktrees as-is.
2. `start.sh` launches one tmux session per agent, injects runtime env, and ensures the Dolt SQL server container is running for beads server mode.
3. `agent-loop.sh` runs one agent pass per iteration, creates a unique per-run branch, writes per-run logs/metrics, and parses the agent summary JSON.
4. `AGENT_PROMPT.md` defines the agent contract for issue lifecycle, merge, discovery, and summary output.
5. `with-lock.sh` provides a shared lock primitive for agent-owned merge/push critical sections.
6. `status.sh` provides health and observability snapshots, including Dolt database checks.
7. `stop.sh` terminates active sessions and stops the Dolt SQL server container.

## File Roles

- `orca.sh`: command dispatcher
- `setup-worktrees.sh`: creates and verifies persistent agent worktrees
- `start.sh`: launches tmux-backed agent loops
- `agent-loop.sh`: per-agent run loop that executes the prompt, captures run artifacts, and records summary/metrics
- `with-lock.sh`: scoped lock wrapper for commands that must serialize shared git integration operations
- `check-closed-deps-merged.sh`: guard that verifies closed blocking dependencies for an issue are represented on integration history before claim
- `status.sh`: displays sessions, worktrees, queue snapshots, logs, and metrics
- `stop.sh`: stops active agent sessions and Dolt SQL server container
- `AGENT_PROMPT.md`: agent instruction contract used by `agent-loop.sh`
- `OPERATOR_GUIDE.md`: human operator playbook and design rationale

## Lock Pattern (`with-lock.sh`)

For agent-owned integration flows, wrap merge/push critical sections in `with-lock.sh` so only one writer updates shared targets at a time.

```bash
"${ORCA_WITH_LOCK_PATH}" --scope merge --timeout 120 -- \
  bash -lc '
    set -euo pipefail
    repo="${ORCA_PRIMARY_REPO}"
    src_branch="$(git branch --show-current)"
    primary_branch="$(git -C "$repo" branch --show-current)"
    if [[ "$primary_branch" != "main" ]]; then
      echo "[merge-precheck] expected primary repo on main, found: ${primary_branch}" >&2
      echo "[merge-precheck] fix by checking out main in ${repo} before retrying" >&2
      exit 1
    fi
    if ! git -C "$repo" diff --quiet || ! git -C "$repo" diff --cached --quiet; then
      echo "[merge-precheck] primary repo has uncommitted changes; aborting before fetch/merge" >&2
      git -C "$repo" status --short >&2
      echo "[merge-precheck] stash/commit/discard changes in ${repo}, then rerun merge block" >&2
      exit 1
    fi
    git -C "$repo" fetch origin main "$src_branch"
    git -C "$repo" checkout main
    git -C "$repo" pull --ff-only origin main
    git -C "$repo" merge --no-ff "$src_branch"
    git -C "$repo" push origin main
  '
```

Notes:

1. default scope is `merge`
2. default lock file for `merge` scope is `<git-common-dir>/orca-global.lock`
3. non-default scopes use `<git-common-dir>/orca-global-<scope>.lock`
4. keep all shared-target write steps in one lock invocation
5. use `set -euo pipefail` in lock-guarded merge scripts to fail fast
6. run a dirty-tree precheck (`git diff --quiet` and `git diff --cached --quiet`) before fetch/merge

## Run Summary JSON Contract

Agents must write a JSON object to `ORCA_RUN_SUMMARY_PATH` (also provided in prompt placeholder `__SUMMARY_JSON_PATH__`) with these fields:

| Field | Type | Required | Allowed values / notes |
| --- | --- | --- | --- |
| `issue_id` | string | yes | Issue handled in this run. Use empty string when no issue was claimed. |
| `result` | string | yes | `completed`, `blocked`, `no_work`, `failed` |
| `issue_status` | string | yes | Issue status after this run, or empty for `no_work`. |
| `merged` | boolean | yes | `true` only when merge/integration completed in this run. |
| `discovery_ids` | array[string] | yes | Follow-up bead IDs created in this run. Use `[]` when none. |
| `discovery_count` | integer | yes | Must equal `discovery_ids` length. |
| `loop_action` | string | yes | `continue` or `stop` |
| `loop_action_reason` | string | yes | Reason for selected `loop_action`; empty string allowed. |
| `notes` | string | yes | Short run note/handoff summary. |

## Core Loop Logic (`agent-loop.sh`)

Each iteration:

1. creates run artifacts (`run.log`, `summary.json`, optional `summary.md`) under session/run directories
2. renders `AGENT_PROMPT.md` placeholders (agent/worktree/summary/discovery/primary-repo/lock-helper paths)
3. executes agent command once
4. parses summary JSON and validates required schema fields when present
5. appends metrics row to `agent-logs/metrics.jsonl`
6. continues until `MAX_RUNS` or agent requests stop via `loop_action=stop`

## Validation and Safety Checks

### `start.sh`

Startup checks:

1. required commands: `git`, `tmux`, `bd`, `jq`, `flock`, and `AGENT_COMMAND` binary
2. `count` positive integer
3. `MAX_RUNS` non-negative integer
4. `RUN_SLEEP_SECONDS` non-negative integer
5. `ORCA_TIMING_METRICS` and `ORCA_COMPACT_SUMMARY` are `0|1`
6. `ORCA_LOCK_SCOPE` matches `[A-Za-z0-9._-]+`
7. `ORCA_LOCK_TIMEOUT_SECONDS` positive integer
8. `DOLT_READY_MAX_ATTEMPTS` positive integer
9. `DOLT_READY_WAIT_SECONDS` non-negative integer
10. each non-running agent worktree is clean (`git status --porcelain` empty)
11. `AGENT_REASONING_LEVEL` (if set) matches `[A-Za-z0-9._-]+`
12. `PROMPT_TEMPLATE` exists

Behavior:

1. default model `gpt-5.3-codex`
2. optional reasoning level is appended to default command
3. idempotent start for existing sessions
4. invokes `setup-worktrees.sh` before launching sessions
5. injects runtime knobs into each session
6. ensures Dolt SQL server container is running (`bookbinder-dolt` by default)
7. waits for Dolt SQL readiness before running setup queries and surfaces timeout diagnostics from container logs
8. ensures SQL auth includes `root@'%'` for local TCP client compatibility
9. refuses to launch sessions when a non-running agent worktree is dirty, with per-path status output

### `agent-loop.sh`

Input/env validation:

1. `WORKTREE` required and must be a valid git worktree
2. `MAX_RUNS` non-negative integer
3. `RUN_SLEEP_SECONDS` non-negative integer
4. `ORCA_TIMING_METRICS` and `ORCA_COMPACT_SUMMARY` are `0|1`
5. `AGENT_REASONING_LEVEL` format validation when set
6. `PROMPT_TEMPLATE` exists
7. `ORCA_PRIMARY_REPO` points to a valid git worktree
8. `ORCA_WITH_LOCK_PATH` points to an executable helper

Signal handling:

1. traps `INT`, `TERM`, `EXIT`
2. logs shutdown signals
3. avoids re-entrant cleanup

### `status.sh`

1. prints an `orca health` summary (sessions, agent worktrees, primary repo dirty count, metrics rollup)
2. prints Dolt database status (mode, server config, docker container state, bd connectivity)
3. emits explicit alerts for high-signal conditions (no sessions, stale metrics, non-completed latest run, Dolt server down/failed, dirty agent worktrees)
4. prints per-agent latest activity from `metrics.jsonl` (result, issue, age, duration, tokens, loop action)
5. prints recent attention events (non-`completed` and non-`no_work` runs)
6. prints tmux sessions and git worktrees
7. prints queue snapshots (`in_progress`, `closed`) plus `bd status`
8. prints latest metrics rows with agent and relative age

Tuning knobs:

- `ORCA_STATUS_STALE_SECONDS` (default `900`)
- `ORCA_STATUS_CLAIMED_LIMIT` (default `20`)
- `ORCA_STATUS_CLOSED_LIMIT` (default `10`)
- `ORCA_STATUS_RECENT_METRIC_LIMIT` (default `10`)

## Error Handling Model

Orca handles transport/observability errors. Agents handle workflow policy.

1. startup hard-stop failures: invalid config/env/worktree/prompt path, Dolt readiness timeout, or dirty non-running agent worktree
2. run-level failures: non-zero agent exit, missing/invalid summary JSON, summary schema validation failure, metrics append failure
3. controlled stop: run limit reached or agent summary requests stop

## Logs and Traceability

Session logs:

`agent-logs/sessions/YYYY/MM/DD/<session-id>/session.log`

Per-run logs:

`agent-logs/sessions/YYYY/MM/DD/<session-id>/runs/<run-id>/run.log`

Per-run summary JSON:

`agent-logs/sessions/YYYY/MM/DD/<session-id>/runs/<run-id>/summary.json`

Per-run compact summary markdown:

`agent-logs/sessions/YYYY/MM/DD/<session-id>/runs/<run-id>/summary.md`

Per-run final message capture:

`agent-logs/sessions/YYYY/MM/DD/<session-id>/runs/<run-id>/last-message.md`

Metrics stream:

`agent-logs/metrics.jsonl`

Each metrics row includes:

1. `harness_version` (`git describe --always --dirty` from the harness repo)
2. `summary_schema_status` (`valid|invalid|not_checked`)
3. `summary_schema_reason_codes` (array of deterministic validation codes when invalid)

Per-agent discovery notes:

`agent-logs/discoveries/<agent-name>.md`

Archived legacy logs:

`agent-logs/archive/<timestamp>/...`

Discovery path is injected to agents as:

- prompt placeholders: `__DISCOVERY_LOG_PATH__`, `__AGENT_DISCOVERY_LOG_PATH__`
- env vars: `ORCA_DISCOVERY_LOG_PATH`, `ORCA_AGENT_DISCOVERY_LOG_PATH`

Primary repo and lock helper are injected to agents as:

- prompt placeholders: `__PRIMARY_REPO__`, `__ORCA_PRIMARY_REPO__`, `__WITH_LOCK_PATH__`, `__ORCA_WITH_LOCK_PATH__`
- env vars: `ORCA_PRIMARY_REPO`, `ORCA_WITH_LOCK_PATH`

## Runtime Knobs

- `MAX_RUNS`: issue runs per loop (`0` means unbounded unless agent requests stop)
- `AGENT_MODEL`: default model for default command
- `AGENT_REASONING_LEVEL`: optional reasoning effort for default command
- `RUN_SLEEP_SECONDS`: sleep between iterations (default `2`)
- `ORCA_TIMING_METRICS`: emit metrics rows (`1` default)
- `ORCA_COMPACT_SUMMARY`: emit markdown summaries (`1` default)
- `SESSION_PREFIX`: tmux session prefix (`bb-agent` default)
- `PROMPT_TEMPLATE`: prompt template path (`scripts/orca/AGENT_PROMPT.md` default)
- `AGENT_COMMAND`: full command for each run
- `ORCA_LOCK_SCOPE`: default lock scope for `with-lock.sh` (`merge`)
- `ORCA_LOCK_TIMEOUT_SECONDS`: lock timeout seconds (default `120`)
- `ORCA_PRIMARY_REPO`: primary repository path used for lock-guarded merge/push operations (default repo root)
- `ORCA_WITH_LOCK_PATH`: absolute path to lock helper passed to agents (default `<repo-root>/scripts/orca/with-lock.sh`)
- `DOLT_CONTAINER_NAME`: Dolt SQL server container name (default `bookbinder-dolt`)
- `DOLT_IMAGE`: Dolt container image (default `dolthub/dolt:latest`)
- `DOLT_BIND_HOST`: host interface for container port bind (default `127.0.0.1`)
- `DOLT_BIND_PORT`: host port for Dolt SQL server (default `3307`)
- `DOLT_SERVER_PORT`: Dolt SQL server port inside container (default `3306`)
- `DOLT_DATA_DIR`: host path mounted to Dolt data dir (default `<repo-root>/.beads/dolt`)
- `DOLT_READY_MAX_ATTEMPTS`: Dolt SQL readiness retries before failing startup (default `30`)
- `DOLT_READY_WAIT_SECONDS`: sleep between readiness retries (default `1`)
