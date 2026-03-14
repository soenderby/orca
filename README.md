# Orca Scripts

This directory contains the Orca multi-agent orchestration scripts.

Orca uses transport-focused loop orchestration while agents own task policy and decisions.

## Documentation

Current documentation:

1. `README.md` (this file): technical reference and command/runtime details
2. `docs/setup.md`: operator onboarding flow for Ubuntu/WSL (`doctor -> bootstrap -> doctor`)
3. `docs/design.md`: purpose and design principles
4. `docs/decision-log.md`: architecture/operating decisions and revisit triggers
5. `docs/operating-modes.md`: proposed mode profiles (`execute|explore`) and experiment plan
6. `AGENT_PROMPT.md`: active worker prompt contract
7. `OPERATOR_GUIDE.md`: operator playbook
8. `SESSION_PRIMER.md`: single-session interaction contract and quick-prime text
9. `docs/async-monitor-v0-spec.md`: authoritative v0 CLI and data schema spec for monitor/observe workflows
10. `docs/async-agent-supervision-plan.md`: goals/boundary/future notes (non-spec context)
11. `docs/user-stories.md`: workflow narratives and friction input used to guide design

## Entrypoints

- `./orca.sh <command> [args]`

## Queue Initialization (one-time)

```bash
br init
br config set id.prefix orca
```

## Setup Quickstart (Ubuntu/WSL)

Use the onboarding flow in `docs/setup.md` for complete troubleshooting/remediation guidance.

```bash
./orca.sh doctor
./orca.sh bootstrap --yes
./orca.sh doctor
```

Dry-run mode:

```bash
./orca.sh bootstrap --yes --dry-run
```

## Queue Sync + Concurrency Model

Orca with `br` uses git-based async queue collaboration (`.beads/issues.jsonl`), not a central queue server.

1. `br` claim atomicity (`--claim`) is scoped to a SQLite DB snapshot.
2. Agents run in separate worktrees, so stale snapshots can produce duplicate local claims unless claims are published centrally.
3. Orca policy: claim publication is lock-guarded against `ORCA_PRIMARY_REPO/main` before coding, using the same writer lock scope as merge/push (see `AGENT_PROMPT.md`).
4. Queue mutation policy:
   - use `queue-write-main.sh` on `ORCA_PRIMARY_REPO/main`
   - do not carry `.beads/` changes in run branches
5. Queue sync lifecycle:
   - import before selecting/claiming (`br sync --import-only`)
   - helper performs import/flush around queue mutations (`br sync --import-only`, `br sync --flush-only`)
   - track `.beads/` in git for cross-machine collaboration
6. Claim publication and merge/push both use the shared writer lock (`ORCA_LOCK_SCOPE`, default `merge`).
7. Run branches are local transport state; do not push them to origin in normal local Orca operation.
8. Cross-machine note: lock files are local. Concurrency across machines is resolved by git publication order on `main` (losing claim attempts must re-import and pick another issue).
9. Local source-of-truth policy: local `main` is the default base for local setup/run operations; `origin/main` is used for synchronization and fallback only. When local `main` and `origin/main` diverge, Orca warns with ahead/behind counts and still defaults to local `main`.

## Issue Parallel-Safety Metadata

Orca issue scheduling may run tasks in parallel, so issues should declare known contention using labels.

Label taxonomy:

1. `px:exclusive`: issue must run alone and should not be scheduled with any other issue.
2. `ck:<key>`: contention key. Issues sharing the same `ck:<key>` should not run together.

Precedence rules:

1. `px:exclusive` overrides any `ck:*` labels.
2. If multiple issues share `ck:<key>`, treat that key as mutually exclusive for concurrent scheduling.
3. Unlabeled issues are parallel-allowed by default.

Authoring guidance:

1. Add `px:exclusive` for high-risk work with broad or hard-to-predict impact (for example: repo-wide refactors, schema migrations, or lockfile/toolchain rewrites).
2. Add `ck:<key>` when overlap is localized to a subsystem (for example: `ck:queue`, `ck:docs`, `ck:agent-loop`, `ck:build`).
3. Prefer stable, subsystem-oriented keys over issue-specific keys so contention is predictable across runs.
4. If unsure, start with a `ck:<key>` label and escalate to `px:exclusive` only when isolation is required.

Operating stance: autonomy with explicit protocol guidance (Option C; see `docs/decision-log.md`, DL-001). Orca provides safety guardrails and observability, while agents retain broad execution autonomy.

## Commands

- `bootstrap [--yes] [--dry-run]`
- `start [count] [--runs N|--continuous] [--drain|--watch] [--no-work-retries N] [--reasoning-level LEVEL]`
- `doctor [--json]`
- `stop`
- `status [--quick|--full] [--json] [--session-id ID] [--session-prefix PREFIX]`
- `status --follow [--poll-interval SECONDS] [--max-events N] [--session-id ID] [--session-prefix PREFIX]`
- `wait [--timeout SECONDS] [--poll-interval SECONDS] [--session-id ID] [--session-prefix PREFIX] [--all-history] [--json]`
- `plan [--slots N] [--output PATH]`
- `gc-run-branches [--apply] [--base REF]`
- `setup-worktrees [count]`
- `with-lock [--scope NAME] [--timeout SECONDS] -- <command> [args...]`
- `queue-write-main [options] -- <queue-command> [args...]`
- `queue-mutate [options] <mutation> [args...]`
- `merge-main [--source BRANCH] [options]`

Helper scripts (direct invocation):

- `./with-lock.sh [--scope NAME] [--timeout SECONDS] -- <command> [args...]`
- `./queue-write-main.sh [options] -- <queue-command> [args...]`
- `./queue-mutate.sh [options] <mutation> [args...]`
- `./merge-main.sh [--source BRANCH] [options]`
- `./gc-run-branches.sh [--apply] [--base REF] [--repo PATH]`

## Improvement Policy

Prioritize changes based on observed problems from real runs. Capture proposed improvements as issues with evidence (logs, summaries, metrics), then implement the smallest change that addresses the observed failure mode.

## Architecture Overview

Orca is a `tmux`-backed multi-agent loop with one persistent git worktree per agent:

1. `bootstrap.sh` provides guided Ubuntu/WSL onboarding with deterministic step logging (`--yes`, `--dry-run`) and fail-hard Codex auth gating.
2. `setup-worktrees.sh` creates missing `worktrees/agent-N` on branch `swarm/agent-N` from the detected base ref (`ORCA_BASE_REF`, otherwise `main`, then `origin/main`, then current branch), warns with ahead/behind counts when `main` and `origin/main` diverge, treats `swarm/agent-N` as local transport state, and ignores any `origin/swarm/agent-N` refs.
3. `start.sh` launches one tmux session per agent, injects runtime env (including `ORCA_BASE_REF` when set), validates the local `br` queue workspace, and fails fast when an explicit `ORCA_BASE_REF` is invalid.
4. `doctor.sh` runs onboarding preflight checks (`--json` available) without mutating repository or queue state.
5. `plan.sh` computes deterministic assignment plans from queue-ready issues and label metadata (`px:exclusive`, `ck:*`), and emits machine-readable plan artifacts.
6. `agent-loop.sh` runs one agent pass per iteration, validates explicit `ORCA_BASE_REF` overrides on startup, creates a unique per-run branch using the same base-ref precedence as setup, writes per-run logs/metrics, parses the agent summary JSON, and applies deterministic no-work drain policy.
7. `AGENT_PROMPT.md` defines the agent contract for issue lifecycle, merge, discovery, and summary output.
8. `with-lock.sh` provides the shared lock primitive used by queue/merge helpers.
9. `queue-write-main.sh` performs lock-guarded queue mutations on `ORCA_PRIMARY_REPO/main` with explicit actor validation.
10. `queue-mutate.sh` provides safe queue mutation wrappers (`claim`, `comment`, `close`, `dep-add`) routed through `queue-write-main.sh`.
11. `merge-main.sh` performs lock-guarded merge/push and rejects `.beads`-carrying source branches.
11. `gc-run-branches.sh` safely prunes stale local `swarm/*-run-*` branches with dry-run by default.
12. `status.sh` provides health and observability snapshots, including `br` workspace checks.
13. `wait.sh` blocks until scoped sessions complete and returns deterministic automation exit codes.
14. `stop.sh` terminates active sessions.

## File Roles

- `orca.sh`: command dispatcher
- `bootstrap.sh`: guided Ubuntu/WSL onboarding with dependency install, `br` setup, queue initialization, and Codex auth gating
- `setup-worktrees.sh`: creates and verifies persistent agent worktrees
- `start.sh`: launches tmux-backed agent loops
- `doctor.sh`: preflight readiness checks for setup/operations (`--json` machine-readable mode)
- `plan.sh`: deterministic assignment planner with machine-readable output
- `agent-loop.sh`: per-agent run loop that executes the prompt, captures run artifacts, and records summary/metrics
- `with-lock.sh`: scoped lock wrapper primitive for serialized shared writes
- `queue-read-main.sh`: lock-guarded queue read helper pinned to `ORCA_PRIMARY_REPO/main` with deterministic fallback modes
- `queue-write-main.sh`: lock-guarded queue mutation helper that imports/flushes and commits `.beads/` on `main`
- `queue-mutate.sh`: constrained queue mutation wrapper with safe comment payload paths
- `merge-main.sh`: lock-guarded merge helper with `.beads` source-branch guard and merge-failure cleanup
- `gc-run-branches.sh`: safe stale run-branch pruning helper (dry-run default, protects active worktrees/sessions)
- `status.sh`: displays sessions, worktrees, queue snapshots, logs, and metrics
- `wait.sh`: blocking completion monitor for scoped sessions with deterministic exit codes
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

### Queue Mutation Pattern (`queue-mutate.sh` + `queue-write-main.sh`)

Preferred wrapper form:

```bash
ISSUE_ID="<candidate-id>"
"${ROOT}/queue-mutate.sh" \
  --actor "${AGENT_NAME}" \
  claim "${ISSUE_ID}"
```

Direct helper form (advanced):

Queue mutation pattern for claim, comments, state transitions, discovery issue creation, and dependency edges:

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
5. explicit `--actor` is required and must match inner `br --actor`
6. `br comments add` must use file payload mode (`--file`)
7. helper executes queue `br` commands via resolved real `br` binary (`ORCA_BR_REAL_BIN` when provided), so run-time guard shims do not block approved helper workflows

Regression-protected tooling invariants (see `tests/regression_queue_mutation_guardrails.sh`):

1. unsafe queue comment payload handling is blocked (`--message` disallowed for comment mutations)
2. missing or mismatched mutation actor is rejected by queue mutation tooling
3. direct run-worktree `br` mutations are blocked unless the explicit unsafe escape hatch is enabled
4. primary queue-read failures can fall back to worktree reads when `--fallback worktree` is requested

### Queue Read Pattern (`queue-read-main.sh`)

Use primary-repo queue reads for critical run/planner operations:

```bash
"${ORCA_QUEUE_READ_MAIN_PATH}" \
  --fallback error \
  -- \
  br ready --json
```

Helper guarantees:

1. lock-guarded read against `ORCA_PRIMARY_REPO/main`
2. imports queue state before running read commands
3. enforces read-only `br` subcommands
4. supports deterministic fallback policy (`error` or `worktree`)
5. logs queue read source (`primary`, `worktree`, or unavailable error)

### Merge Pattern (`merge-main.sh`)

Merge pattern for run-branch integration:

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
| `discovery_ids` | array[string] | no | Optional compatibility field for follow-up issue IDs created in this run. |
| `discovery_count` | integer | no | Optional compatibility field; when present with `discovery_ids`, should match its length. |
| `loop_action` | string | yes | `continue` or `stop` |
| `loop_action_reason` | string | yes | Reason for selected `loop_action`; empty string allowed. |
| `notes` | string | yes | Short run note/handoff summary. |

When `ORCA_ASSIGNED_ISSUE_ID` is set, `issue_id` must exactly match that assigned ID.

## Core Loop Logic (`agent-loop.sh`)

Each iteration:

1. creates run artifacts (`run.log`, `summary.json`, optional `summary.md`) under session/run directories
2. renders `AGENT_PROMPT.md` placeholders (agent/worktree/summary/primary-repo/lock/queue-write/merge-helper paths, assignment mode, assigned issue)
3. executes agent command once
4. injects a run-time `br` guard shim that allows read-only commands and blocks direct mutation subcommands by default
5. parses summary JSON and validates required schema fields when present
6. restores any leftover local `.beads/` working-tree changes to keep run branches clean
7. appends metrics row to `agent-logs/metrics.jsonl`
8. in default `drain` mode, stops on sustained `no_work` (after `ORCA_NO_WORK_RETRY_LIMIT + 1` consecutive `no_work` results); transient no-work windows can retry up to the configured limit
8. `watch` mode disables no-work auto-stop and keeps polling until an earlier stop condition (`MAX_RUNS`, `loop_action=stop`, or failure)

## Validation and Safety Checks

### `bootstrap.sh`

Guided Ubuntu/WSL onboarding flow:

1. validates Ubuntu platform (WSL preferred)
2. installs missing apt dependencies (`git`, `tmux`, `jq`, `util-linux`, `curl`, `python3`) with optional non-interactive `--yes`
3. ensures `python` command availability via `python-is-python3`
4. installs `br` via upstream installer to `~/.local/bin` and verifies active `br` path/version
5. initializes queue workspace (`br init`) when `.beads/` is missing
6. ensures queue `id.prefix` is configured (`orca` default)
7. configures repo-local git identity (interactive by default; `--yes` adopts global identity when available)
8. checks `codex` availability/auth via `codex login status` and fails hard with remediation commands when auth is unresolved

Modes:

1. `--yes` skips interactive confirmation prompts for package/install steps
2. `--dry-run` logs planned actions without mutating system or repository

### `doctor.sh`

Preflight checks (read-only):

1. target platform detection for Ubuntu on WSL (warn-only if unsupported)
2. required binaries present: `git`, `tmux`, `jq`, `flock`, `br`, `codex`
3. `br --version` executes
4. repository context validates (`git rev-parse`, `origin` configured)
5. remote reachability/auth is reported separately as a warning (`git ls-remote origin`)
6. local git identity exists (`user.name`, `user.email`)
7. queue workspace health (`.beads/` exists, `br doctor`, `br config get id.prefix`)
8. helper scripts are present and executable (`with-lock.sh`, `queue-read-main.sh`, `queue-write-main.sh`, `merge-main.sh`)
9. `--json` emits stable check IDs, statuses, severities, and structured remediation commands
10. command exits non-zero when any hard requirement fails

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
9. `ORCA_NO_WORK_DRAIN_MODE` is `drain|watch`
10. `ORCA_NO_WORK_RETRY_LIMIT` non-negative integer
11. `ORCA_FORCE_COUNT` is `0|1`
12. `.beads/` workspace exists and `br doctor` succeeds
13. `ORCA_ASSIGNMENT_MODE` is `assigned|self-select`
14. each non-running agent worktree is clean (`git status --porcelain` empty)
15. `AGENT_REASONING_LEVEL` (if set) matches `[A-Za-z0-9._-]+`
16. `PROMPT_TEMPLATE` exists
17. `ORCA_PRIMARY_REPO` points to a valid git worktree
18. `ORCA_WITH_LOCK_PATH`, `ORCA_QUEUE_READ_MAIN_PATH`, `ORCA_QUEUE_WRITE_MAIN_PATH`, and `ORCA_MERGE_MAIN_PATH` are executable

Behavior:

1. default model `gpt-5.3-codex`
2. optional reasoning level is appended to default command
3. idempotent start for existing sessions
4. validates local `br` queue workspace health before launch
5. invokes `setup-worktrees.sh` before launching sessions
6. injects runtime knobs into each session
7. default assignment mode is `assigned`: each launched session receives one ready issue ID via `ORCA_ASSIGNED_ISSUE_ID`
8. assigned mode uses `plan.sh` (deterministic, metadata-driven) to select assignments up to launch capacity; plan artifacts are written under `agent-logs/plans/YYYY/MM/DD/`
9. explicit override `ORCA_ASSIGNMENT_MODE=self-select` restores unassigned self-selection behavior for recovery/debugging
10. in `self-select`, `ORCA_FORCE_COUNT=1` bypasses launch capping and launches all requested non-running sessions
11. logs launch planning and summary counts (`requested`, `running`, `ready`, `launchable/launched`, `force_count`, `assignment_mode`) plus assignment-plan details (per-slot issue IDs, held/skipped reason codes, and per-issue planner decisions)
12. refuses to launch sessions when a non-running agent worktree is dirty, with per-path status output

### `agent-loop.sh`

Input/env validation:

1. `WORKTREE` required and must be a valid git worktree
2. `MAX_RUNS` non-negative integer
3. `RUN_SLEEP_SECONDS` non-negative integer
4. `ORCA_TIMING_METRICS` and `ORCA_COMPACT_SUMMARY` are `0|1`
5. `ORCA_LOCK_SCOPE` matches `[A-Za-z0-9._-]+`
6. `ORCA_LOCK_TIMEOUT_SECONDS` positive integer
7. `ORCA_NO_WORK_DRAIN_MODE` is `drain|watch`
8. `ORCA_NO_WORK_RETRY_LIMIT` non-negative integer
9. `ORCA_ASSIGNMENT_MODE` is `assigned|self-select`
10. `ORCA_ASSIGNED_ISSUE_ID` format validation when set; required when `ORCA_ASSIGNMENT_MODE=assigned`
11. `AGENT_REASONING_LEVEL` format validation when set
12. `PROMPT_TEMPLATE` exists
13. `ORCA_PRIMARY_REPO` points to a valid git worktree
14. `ORCA_WITH_LOCK_PATH` points to an executable helper
15. `ORCA_QUEUE_READ_MAIN_PATH` points to an executable helper
16. `ORCA_QUEUE_WRITE_MAIN_PATH` points to an executable helper
17. `ORCA_MERGE_MAIN_PATH` points to an executable helper

Signal handling:

1. traps `INT`, `TERM`, `EXIT`
2. logs shutdown signals
3. avoids re-entrant cleanup

### `status.sh`

1. defaults to `--quick` for a fast active-operations view (health summary, active sessions, current claims, latest run activity, high-signal alerts)
2. supports `--full` for complete diagnostics (legacy output depth)
3. supports `--json` machine-readable output with explicit top-level schema version (`schema_version: "orca.status.v1"`)
4. supports `--follow` to emit structured JSON lines lifecycle events (`schema_version: "orca.monitor.v1"`, event types: `session_started`, `run_started`, `run_completed`, `run_failed`, `loop_stopped`)
5. supports session scoping with `--session-id` (exact match) and `--session-prefix` (prefix match) across quick/full/json/follow surfaces
6. reports active run state per scoped session (`state=running|idle`) from live run artifacts so operators can distinguish in-progress execution from idle/stalled state
7. in full mode, prints queue backend diagnostics for `br` (version, workspace presence, doctor result, sync status)
8. in full mode, prints per-agent latest activity from `metrics.jsonl` (session, result, issue, age, duration, tokens, loop action)
9. in full mode, prints tmux sessions and git worktrees
10. in full mode, prints queue snapshots (`in_progress`, `closed`)
11. in full mode, prints latest metrics rows with session, agent, and relative age
12. full-mode metrics summary is cached by `metrics.jsonl` fingerprint (`size:mtime:v2`) under `agent-logs/cache`; unchanged files reuse cached counters/agent latest rows
13. cache limitation: the first `--full` call after any `metrics.jsonl` change still performs a full parse to refresh cache

Managed follow v2 contract (frozen target for monitor layering; implemented in `orca-18w.2`):

- schema version: `orca.monitor.v2`
- event types: `session_up`, `session_down`, `run_started`, `run_completed`, `run_failed`
- exact `event_id` formats:
  - `session_up:<session_id>`
  - `session_down:<session_id>`
  - `run_started:<session_id>:<run_id>`
  - `run_completed:<session_id>:<run_id>`
  - `run_failed:<session_id>:<run_id>`
- managed `session_down` semantics: emit only on tmux liveness transition `active -> inactive`; never infer from graceful loop stop or run completion
- transition-only behavior: unchanged snapshots must not re-emit the same lifecycle transition
- v2 excludes legacy names `session_started` and `loop_stopped`

Tuning knobs:

- `ORCA_STATUS_STALE_SECONDS` (default `900`)
- `ORCA_STATUS_CLAIMED_LIMIT` (default `20`)
- `ORCA_STATUS_CLOSED_LIMIT` (default `10`)
- `ORCA_STATUS_RECENT_METRIC_LIMIT` (default `10`)
- `ORCA_STATUS_CACHE_DIR` (default `agent-logs/cache`)
- `ORCA_STATUS_METRICS_CACHE_MAX_FILES` (default `5`)

Performance regression check:

- `bash tests/status_metrics_perf_check.sh`
- `bash tests/status_session_scope_and_progress.sh`
- `bash tests/regression_status_follow_monitor.sh`

Automation examples:

```bash
# Parse health + alerts in machine-readable status output
./orca.sh status --quick --json | jq '{health: .health.status, alerts: .health.alerts}'

# Follow lifecycle transitions for one session and react to failures
./orca.sh status --follow --session-id "<session-id>" \
  | jq -r 'select(.event_type == "run_failed") | "FAILED " + .session_id + " run=" + (.run.run_id // "none")'
```

### `wait.sh`

1. blocks until scoped sessions reach terminal summary state
2. supports session scoping with `--session-id` (exact) and `--session-prefix` (prefix)
3. in unscoped mode, defaults to sessions active at invocation (prevents historical-session false failures)
4. `--all-history` restores historical log scope for broad retrospective waits
5. supports bounded waiting via `--timeout SECONDS` and deterministic polling via `--poll-interval SECONDS`
6. does not full-scan `metrics.jsonl` on each poll; it inspects scoped session run artifacts
7. emits concise final rollup by default; `--json` emits machine-readable final state
8. no scoped sessions at invocation is treated as immediate success with reason `no_scoped_sessions`

Exit codes:

- `0`: success (`all_scoped_sessions_finished` or `no_scoped_sessions`)
- `2`: timeout
- `3`: scoped failure detected (`failed`/`blocked` summary result or non-zero run exit marker)
- `4`: invalid usage/config

Regression check:

- `bash tests/regression_wait_command.sh`

## Error Handling Model

Orca handles transport/observability errors. Agents handle workflow policy.

1. startup hard-stop failures: invalid config/env/worktree/prompt path, unhealthy `br` workspace, or dirty non-running agent worktree
2. run-level failures: non-zero agent exit, missing/invalid summary JSON, summary schema validation failure, metrics append failure
3. controlled stop: an early stop condition is reached (`MAX_RUNS` ceiling, `no_work` drain stop, or agent summary requests stop)

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
4. `mode_id` (nullable mode identifier for experiment attribution)
5. `approach_source` (nullable approach file path/identifier when configured)
6. `approach_sha256` (nullable SHA256 digest of approach content when readable)
7. `assigned_issue_id` (nullable assigned issue ID for the run)
8. `summary.assignment_match` (nullable boolean showing whether `summary.issue_id` matched assignment)
9. `planned_assigned_issue` (nullable planned issue ID for assignment telemetry; mirrors assigned contract when present)
10. `assignment_source` (`planner` in assigned mode, `self-select` in self-select mode)
11. `assignment_outcome` (`matched|mismatch|unassigned`)

Archived legacy logs:

`agent-logs/archive/<timestamp>/...`

Primary repo and helper paths are injected to agents as:

- prompt placeholders: `__PRIMARY_REPO__`, `__ORCA_PRIMARY_REPO__`, `__WITH_LOCK_PATH__`, `__ORCA_WITH_LOCK_PATH__`, `__QUEUE_READ_MAIN_PATH__`, `__ORCA_QUEUE_READ_MAIN_PATH__`, `__QUEUE_WRITE_MAIN_PATH__`, `__ORCA_QUEUE_WRITE_MAIN_PATH__`, `__MERGE_MAIN_PATH__`, `__ORCA_MERGE_MAIN_PATH__`
- env vars: `ORCA_PRIMARY_REPO`, `ORCA_WITH_LOCK_PATH`, `ORCA_QUEUE_READ_MAIN_PATH`, `ORCA_QUEUE_WRITE_MAIN_PATH`, `ORCA_MERGE_MAIN_PATH`
- assignment env vars: `ORCA_ASSIGNMENT_MODE`, `ORCA_ASSIGNED_ISSUE_ID`

`start.sh` sets these values at launch time; if `agent-loop.sh` is run directly, it applies the same defaults (`<repo-root>`, `<repo-root>/with-lock.sh`, `<repo-root>/queue-read-main.sh`, `<repo-root>/queue-write-main.sh`, `<repo-root>/merge-main.sh`) and the same validation rules.

## Runtime Knobs

- `MAX_RUNS`: maximum issue runs per loop (upper bound; `0` means unbounded unless stopped by drain policy or `loop_action=stop`)
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
- `ORCA_NO_WORK_DRAIN_MODE`: `drain` (default) or `watch`; `drain` stops loops on sustained `no_work`, `watch` keeps polling
- `ORCA_NO_WORK_RETRY_LIMIT`: non-negative retry budget for transient consecutive `no_work` in `drain` mode (default `1`)
- `ORCA_MODE_ID`: optional mode identifier for observability attribution (for example `execute` or `explore`; empty by default)
- `ORCA_WORK_APPROACH_FILE`: optional path/identifier for approach guidance attribution; when readable, `agent-loop.sh` records content SHA256 in metrics/session logs
- `ORCA_FORCE_COUNT`: when `0` (default), cap new launches to current ready queue depth; set to `1` to bypass this cap and force full requested launch count for non-running sessions
- `ORCA_ASSIGNMENT_MODE`: assignment strategy, `assigned` (default) or explicit override `self-select` for recovery/debugging
- `ORCA_ASSIGNED_ISSUE_ID`: assigned issue ID for the current run; required in `assigned` mode and empty in `self-select`
- `ORCA_PRIMARY_REPO`: primary repository path used for lock-guarded claim publication and merge/push operations; defaults to repo root in both `start.sh` and `agent-loop.sh`, and must be a valid git worktree
- `ORCA_WITH_LOCK_PATH`: absolute path to lock helper passed to agents; defaults to `<repo-root>/with-lock.sh` in both `start.sh` and `agent-loop.sh`, and must be executable
- `ORCA_QUEUE_READ_MAIN_PATH`: absolute path to queue read helper passed to agents (default `<repo-root>/queue-read-main.sh`)
- `ORCA_QUEUE_WRITE_MAIN_PATH`: absolute path to queue mutation helper passed to agents (default `<repo-root>/queue-write-main.sh`)
- `ORCA_MERGE_MAIN_PATH`: absolute path to merge helper passed to agents (default `<repo-root>/merge-main.sh`)
- `ORCA_BR_GUARD_PATH`: absolute path to run-time `br` guard shim (default `<repo-root>/br-guard.sh`)
- `ORCA_BR_GUARD_MODE`: `enforce` (default) to block direct mutation subcommands in run worktrees, or `off` to disable guard
- `ORCA_ALLOW_UNSAFE_BR_MUTATIONS`: explicit audited escape hatch (`0` default, `1` to allow direct mutation commands for recovery/debugging)
- `ORCA_BASE_REF`: optional explicit base ref override for worktree setup and run-branch creation; when set, it must resolve to a commit or startup fails fast (default when unset: `main`, then `origin/main`, then current branch; warns when `main` and `origin/main` diverge)
