# Orca Scripts

This directory contains the Orca multi-agent orchestration scripts.

Orca uses transport-focused loop orchestration while agents own task policy and decisions.

## Documentation

Current documentation:

1. `README.md` (this file): technical reference and command/runtime details
2. `docs/design.md`: purpose and design principles
3. `docs/decision-log.md`: architecture/operating decisions and revisit triggers
4. `AGENT_PROMPT.md`: active worker prompt contract
5. `OPERATOR_GUIDE.md`: operator playbook

## Entrypoints

- `./orca.sh <command> [args]`

## Queue Initialization (one-time)

```bash
br init
br config set id.prefix orca
```

## Queue Sync + Concurrency Model

Orca with `br` uses git-based async queue collaboration (`.beads/issues.jsonl`), not a central queue server.

1. `br` claim atomicity (`--claim`) is scoped to a SQLite DB snapshot.
2. Agents run in separate worktrees, so stale snapshots can produce duplicate local claims unless claims are published centrally.
3. Orca policy: claim publication is lock-guarded against `ORCA_PRIMARY_REPO/main` before coding, using the same writer lock scope as merge/push (see `AGENT_PROMPT.md`).
4. Queue mutation policy (helper-first):
   - default path uses `queue-write-main.sh` on `ORCA_PRIMARY_REPO/main`
   - do not carry `.beads/` changes in run branches
5. Queue sync lifecycle:
   - import before selecting/claiming (`br sync --import-only`)
   - helper performs import/flush around queue mutations (`br sync --import-only`, `br sync --flush-only`)
   - track `.beads/` in git for cross-machine collaboration
6. Claim publication and merge/push both use the shared writer lock (`ORCA_LOCK_SCOPE`, default `merge`).
7. Run branches are local transport state; do not push them to origin in normal local Orca operation.
8. Cross-machine note: lock files are local. Concurrency across machines is resolved by git publication order on `main` (losing claim attempts must re-import and pick another issue).

Operating stance: helper-first with autonomy (Option C; see `docs/decision-log.md`, DL-001). Orca provides safety guardrails and observability, while agents retain broad execution autonomy.

## Commands

- `start [count] [--runs N|--continuous] [--reasoning-level LEVEL]`
- `stop`
- `status`
- `setup-worktrees [count]`
- `with-lock [--scope NAME] [--timeout SECONDS] -- <command> [args...]`
- `queue-write-main [options] -- <queue-command> [args...]`
- `merge-main [--source BRANCH] [options]`

Helper scripts (direct invocation):

- `./with-lock.sh [--scope NAME] [--timeout SECONDS] -- <command> [args...]`
- `./queue-write-main.sh [options] -- <queue-command> [args...]`
- `./merge-main.sh [--source BRANCH] [options]`

## Improvement Policy

Prioritize changes based on observed problems from real runs. Capture proposed improvements as issues with evidence (logs, summaries, metrics), then implement the smallest change that addresses the observed failure mode.

## Architecture Overview

Orca is a `tmux`-backed multi-agent loop with one persistent git worktree per agent:

1. `setup-worktrees.sh` creates missing `worktrees/agent-N` on branch `swarm/agent-N` from the detected base ref, treats `swarm/agent-N` as local transport state, and ignores any `origin/swarm/agent-N` refs.
2. `start.sh` launches one tmux session per agent, injects runtime env, and validates the local `br` queue workspace.
3. `agent-loop.sh` runs one agent pass per iteration, creates a unique per-run branch, writes per-run logs/metrics, and parses the agent summary JSON.
4. `AGENT_PROMPT.md` defines the agent contract for issue lifecycle, merge, discovery, and summary output.
5. `with-lock.sh` provides the shared lock primitive used by queue/merge helpers.
6. `queue-write-main.sh` performs lock-guarded queue mutations on `ORCA_PRIMARY_REPO/main`.
7. `merge-main.sh` performs lock-guarded merge/push and rejects `.beads`-carrying source branches.
8. `status.sh` provides health and observability snapshots, including `br` workspace checks.
9. `stop.sh` terminates active sessions.

## File Roles

- `orca.sh`: command dispatcher
- `setup-worktrees.sh`: creates and verifies persistent agent worktrees
- `start.sh`: launches tmux-backed agent loops
- `agent-loop.sh`: per-agent run loop that executes the prompt, captures run artifacts, and records summary/metrics
- `with-lock.sh`: scoped lock wrapper primitive for serialized shared writes
- `queue-write-main.sh`: lock-guarded queue mutation helper that imports/flushes and commits `.beads/` on `main`
- `merge-main.sh`: lock-guarded merge helper with `.beads` source-branch guard and merge-failure cleanup
- `status.sh`: displays sessions, worktrees, queue snapshots, logs, and metrics
- `stop.sh`: stops active agent sessions
- `AGENT_PROMPT.md`: agent instruction contract used by `agent-loop.sh`
- `OPERATOR_GUIDE.md`: human operator playbook and design rationale

## Lock Pattern (`with-lock.sh`)

`with-lock.sh` remains the primitive lock wrapper. Agents should use higher-level helpers instead of hand-writing lock blocks.

Notes:

1. default scope is `merge`
2. default lock file for `merge` scope is `<git-common-dir>/orca-global.lock`
3. non-default scopes use `<git-common-dir>/orca-global-<scope>.lock`
4. keep each shared-target write transaction in one lock invocation

### Queue Mutation Pattern (`queue-write-main.sh`)

Default helper-first path for queue mutations (claim, comments, state transitions, discovery issue creation, dependency edges):

```bash
ISSUE_ID="<candidate-id>"
"${ORCA_QUEUE_WRITE_MAIN_PATH}" \
  --actor "${AGENT_NAME}" \
  --message "queue: claim ${ISSUE_ID} by ${AGENT_NAME}" \
  -- \
  br --actor "${AGENT_NAME}" update "${ISSUE_ID}" --claim --json
```

Helper guarantees:

1. lock + precheck + `fetch/pull` on `ORCA_PRIMARY_REPO/main`
2. `br sync --import-only` before queue command
3. `br sync --flush-only` after queue command
4. commit/push `.beads/` only when there are staged queue changes

### Merge Pattern (`merge-main.sh`)

Default helper-first path for run-branch integration:

```bash
"${ORCA_MERGE_MAIN_PATH}" --source "$(git branch --show-current)"
```

Helper guarantees:

1. lock + precheck + `fetch/pull` on `ORCA_PRIMARY_REPO/main`
2. hard failure if source branch carries `.beads/` changes (`main...source`)
3. merge failure cleanup (`merge --abort`, reset cleanup path)
4. push of merged `main`

Using one shared writer lock for both helper paths serializes local `main` writes and prevents queue/code interleaving races between concurrent local Orca agents.

## Run Summary JSON Contract

Agents must write a JSON object to `ORCA_RUN_SUMMARY_PATH` (also provided in prompt placeholder `__SUMMARY_JSON_PATH__`) with these fields:

| Field | Type | Required | Allowed values / notes |
| --- | --- | --- | --- |
| `issue_id` | string | yes | Issue handled in this run. Use empty string when no issue was claimed. |
| `result` | string | yes | `completed`, `blocked`, `no_work`, `failed` |
| `issue_status` | string | yes | Issue status after this run, or empty for `no_work`. |
| `merged` | boolean | yes | `true` only when merge/integration completed in this run. |
| `discovery_ids` | array[string] | yes | Follow-up issue IDs created in this run. Use `[]` when none. |
| `discovery_count` | integer | yes | Must equal `discovery_ids` length. |
| `loop_action` | string | yes | `continue` or `stop` |
| `loop_action_reason` | string | yes | Reason for selected `loop_action`; empty string allowed. |
| `notes` | string | yes | Short run note/handoff summary. |

## Core Loop Logic (`agent-loop.sh`)

Each iteration:

1. creates run artifacts (`run.log`, `summary.json`, optional `summary.md`) under session/run directories
2. renders `AGENT_PROMPT.md` placeholders (agent/worktree/summary/discovery/primary-repo/lock/queue-write/merge-helper paths)
3. executes agent command once
4. parses summary JSON and validates required schema fields when present
5. restores any leftover local `.beads/` working-tree changes to keep run branches clean
6. appends metrics row to `agent-logs/metrics.jsonl`
7. continues until `MAX_RUNS` or agent requests stop via `loop_action=stop`

## Validation and Safety Checks

### `start.sh`

Startup checks:

1. required commands: `git`, `tmux`, `br`, `jq`, `flock`, and `AGENT_COMMAND` binary
2. `br --version` must execute successfully
3. `count` positive integer
4. `MAX_RUNS` non-negative integer
5. `RUN_SLEEP_SECONDS` non-negative integer
6. `ORCA_TIMING_METRICS` and `ORCA_COMPACT_SUMMARY` are `0|1`
7. `ORCA_LOCK_SCOPE` matches `[A-Za-z0-9._-]+`
8. `ORCA_LOCK_TIMEOUT_SECONDS` positive integer
9. `.beads/` workspace exists and `br doctor` succeeds
10. each non-running agent worktree is clean (`git status --porcelain` empty)
11. `AGENT_REASONING_LEVEL` (if set) matches `[A-Za-z0-9._-]+`
12. `PROMPT_TEMPLATE` exists
13. `ORCA_QUEUE_WRITE_MAIN_PATH` and `ORCA_MERGE_MAIN_PATH` are executable

Behavior:

1. default model `gpt-5.3-codex`
2. optional reasoning level is appended to default command
3. idempotent start for existing sessions
4. validates local `br` queue workspace health before launch
5. invokes `setup-worktrees.sh` before launching sessions
6. injects runtime knobs into each session
7. refuses to launch sessions when a non-running agent worktree is dirty, with per-path status output

### `agent-loop.sh`

Input/env validation:

1. `WORKTREE` required and must be a valid git worktree
2. `MAX_RUNS` non-negative integer
3. `RUN_SLEEP_SECONDS` non-negative integer
4. `ORCA_TIMING_METRICS` and `ORCA_COMPACT_SUMMARY` are `0|1`
5. `ORCA_LOCK_SCOPE` matches `[A-Za-z0-9._-]+`
6. `ORCA_LOCK_TIMEOUT_SECONDS` positive integer
7. `AGENT_REASONING_LEVEL` format validation when set
8. `PROMPT_TEMPLATE` exists
9. `ORCA_PRIMARY_REPO` points to a valid git worktree
10. `ORCA_WITH_LOCK_PATH` points to an executable helper
11. `ORCA_QUEUE_WRITE_MAIN_PATH` points to an executable helper
12. `ORCA_MERGE_MAIN_PATH` points to an executable helper

Signal handling:

1. traps `INT`, `TERM`, `EXIT`
2. logs shutdown signals
3. avoids re-entrant cleanup

### `status.sh`

1. prints an `orca health` summary (sessions, agent worktrees, primary repo dirty count, metrics rollup)
2. prints queue backend status for `br` (version, workspace presence, doctor result, sync status)
3. emits explicit alerts for high-signal conditions (no sessions, stale metrics, non-completed latest run, unhealthy queue workspace, dirty agent worktrees)
4. prints per-agent latest activity from `metrics.jsonl` (result, issue, age, duration, tokens, loop action)
5. prints tmux sessions and git worktrees
6. prints queue snapshots (`in_progress`, `closed`)
7. prints latest metrics rows with agent and relative age

Tuning knobs:

- `ORCA_STATUS_STALE_SECONDS` (default `900`)
- `ORCA_STATUS_CLAIMED_LIMIT` (default `20`)
- `ORCA_STATUS_CLOSED_LIMIT` (default `10`)
- `ORCA_STATUS_RECENT_METRIC_LIMIT` (default `10`)

## Error Handling Model

Orca handles transport/observability errors. Agents handle workflow policy.

1. startup hard-stop failures: invalid config/env/worktree/prompt path, unhealthy `br` workspace, or dirty non-running agent worktree
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

Primary repo and helper paths are injected to agents as:

- prompt placeholders: `__PRIMARY_REPO__`, `__ORCA_PRIMARY_REPO__`, `__WITH_LOCK_PATH__`, `__ORCA_WITH_LOCK_PATH__`, `__QUEUE_WRITE_MAIN_PATH__`, `__ORCA_QUEUE_WRITE_MAIN_PATH__`, `__MERGE_MAIN_PATH__`, `__ORCA_MERGE_MAIN_PATH__`
- env vars: `ORCA_PRIMARY_REPO`, `ORCA_WITH_LOCK_PATH`, `ORCA_QUEUE_WRITE_MAIN_PATH`, `ORCA_MERGE_MAIN_PATH`

## Runtime Knobs

- `MAX_RUNS`: issue runs per loop (`0` means unbounded unless agent requests stop)
- `AGENT_MODEL`: default model for default command
- `AGENT_REASONING_LEVEL`: optional reasoning effort for default command
- `RUN_SLEEP_SECONDS`: sleep between iterations (default `2`)
- `ORCA_TIMING_METRICS`: emit metrics rows (`1` default)
- `ORCA_COMPACT_SUMMARY`: emit markdown summaries (`1` default)
- `SESSION_PREFIX`: tmux session prefix (`orca-agent` default)
- `PROMPT_TEMPLATE`: prompt template path (`<repo-root>/AGENT_PROMPT.md` default)
- `AGENT_COMMAND`: full command for each run
- `ORCA_LOCK_SCOPE`: shared writer lock scope for all `main` write operations (claim publication and merge/push) (default `merge`)
- `ORCA_LOCK_TIMEOUT_SECONDS`: lock timeout seconds for shared writer lock operations (default `120`)
- `ORCA_PRIMARY_REPO`: primary repository path used for lock-guarded claim publication and merge/push operations (default repo root)
- `ORCA_WITH_LOCK_PATH`: absolute path to lock helper passed to agents (default `<repo-root>/with-lock.sh`)
- `ORCA_QUEUE_WRITE_MAIN_PATH`: absolute path to queue mutation helper passed to agents (default `<repo-root>/queue-write-main.sh`)
- `ORCA_MERGE_MAIN_PATH`: absolute path to merge helper passed to agents (default `<repo-root>/merge-main.sh`)
- `ORCA_BASE_REF`: optional explicit base ref for new worktrees (default: detect from `origin/HEAD`, then `origin/main`, then `main`, then current branch)
