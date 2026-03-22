# Orca Go Rewrite Plan

Incremental rewrite of orca from bash to Go. Test-first approach: write Go tests that capture expected behavior before implementing each component.

## Context

- Current implementation: 5,488 lines of bash across 19 scripts, 9 regression test suites.
- The bash works and all tests pass. The rewrite must not break orca at any point.
- Watch is already in Go and shares the ecosystem. Shared abstractions require a common language.
- Reference documents: `docs/artifact-contract.md` (output formats), `docs/design.md` (principles), `README.md` (commands and knobs), `ORCA_PROMPT.md` (agent contract).

## Strategy

Build the Go binary (`cmd/orca/`) alongside the bash scripts. During the rewrite, both exist. Each command is migrated individually. When the Go binary handles all commands and all tests pass, delete the bash scripts.

The Go binary is built as `orca-go` during development to avoid collisions with `orca.sh`. After full validation, it becomes `orca`.

## Project Structure

```
orca/
├── cmd/orca/              CLI entrypoint and command wiring
├── internal/
│   ├── model/             Data types: Summary, Metrics, Plan, Config
│   ├── lock/              File locking (flock wrapper)
│   ├── git/               Git operations (worktree, branch, merge, status)
│   ├── tmux/              tmux session management
│   ├── queue/             br queue operations (read, write, mutate, guard)
│   ├── merge/             Lock-guarded merge-to-main
│   ├── worktree/          Worktree setup and management
│   ├── loop/              Agent loop (core run loop)
│   ├── plan/              Assignment planner
│   ├── depsanity/         Dependency graph sanity checker
│   ├── start/             Session launcher (coordinates loop, plan, worktree)
│   ├── status/            Status reporting
│   ├── doctor/            Preflight checks
│   ├── bootstrap/         Setup automation
│   └── prompt/            Prompt template rendering
├── ORCA_PROMPT.md
├── docs/
├── go.mod
└── check.sh               Build + vet + test gate
```

## Quality Standards

Follow the same standards as the watch project (see `/mnt/c/code/watch/AGENTS.md`):

- Test behavior, not implementation. Table-driven tests for pure functions.
- Tests must run without tmux, git, or br where possible. Use interfaces for external dependencies.
- `go vet ./...` and `go test ./...` must pass before every commit.
- No global state. Pass dependencies explicitly.
- Errors are values, not panics.
- Keep the dependency graph acyclic. `model` depends on nothing.

## Rewrite Phases

### Phase 1: Model and Pure Logic

These packages have no external dependencies. They are pure data and computation. Every function is testable with table-driven tests. Build and test these first — they are the foundation.

#### 1.1: `internal/model` — Data Types

Define all orca data types as Go structs with JSON tags.

Types to define:
- `Summary` — run summary JSON (fields: `issue_id`, `result`, `issue_status`, `merged`, `loop_action`, `loop_action_reason`, `notes`, `discovery_ids`, `discovery_count`)
- `MetricsRow` — one row of `metrics.jsonl` (all fields from `docs/artifact-contract.md`)
- `PlanOutput` — planner output (assignments, held, decisions)
- `DepSanityReport` — dependency sanity output (hazards, summary)
- `DoctorResult` — doctor check results
- `StatusOutput` — status JSON output
- Validation functions: `ValidateSummary(s *Summary) []string` — returns list of validation error codes

Tests:
- Summary validation: all field combinations from the schema (required fields missing, invalid result values, issue_id mismatch with assignment, etc.)
- JSON round-trip: marshal/unmarshal for all types
- Reference: current validation logic in `agent-loop.sh` lines ~700-850 (search for `summary_schema_reason_codes`)

#### 1.2: `internal/plan` — Assignment Planner

Port `plan.sh` (304 lines). Pure function: takes a list of ready issues with labels, slot count, returns assignment plan.

Logic to port:
- Parse issue labels (`px:exclusive`, `ck:<key>`, `meta:tracker`)
- Hold tracker issues (reason: `tracker-issue`)
- Enforce exclusivity (`px:exclusive` runs alone)
- Enforce contention keys (`ck:<key>` mutual exclusion)
- Assign issues to slots by priority
- Emit held/skipped reason codes per issue

Input: list of issues (id, priority, labels), slot count.
Output: `PlanOutput` (assignments, held, decisions).

Tests (port from `tests/regression_planner_v1.sh`):
- Basic assignment: N issues to M slots
- `px:exclusive` gets sole slot
- `ck:` contention prevents co-scheduling
- `meta:tracker` held with reason code
- More issues than slots: highest priority wins
- No issues: empty plan
- Single slot: one assignment

#### 1.3: `internal/depsanity` — Dependency Sanity Checker

Port `dep-sanity.sh` (261 lines). Pure function: takes issues with dependencies, returns hazard report.

Hazards detected:
- Mixed `parent-child` + `blocks` pairs between the same issues
- Active-work dependency cycles
- Active self-blocking or mutual-blocking patterns

Input: list of issues with dependencies.
Output: `DepSanityReport` (hazards, summary).

Tests (port from `tests/regression_dep_sanity_check.sh`):
- No hazards: clean graph
- Mixed dep types: detected
- Cycles: detected
- Self-blocking: detected
- Closed issues in dependency chains: not flagged

#### 1.4: `internal/prompt` — Template Rendering

Port the prompt rendering from `agent-loop.sh` (~20 lines). Pure function: takes a template string and a map of placeholder values, returns rendered string.

Placeholders: `__AGENT_NAME__`, `__WORKTREE__`, `__PRIMARY_REPO__`, `__WITH_LOCK_PATH__`, `__QUEUE_READ_MAIN_PATH__`, `__QUEUE_WRITE_MAIN_PATH__`, `__MERGE_MAIN_PATH__`, `__ASSIGNMENT_MODE__`, `__ASSIGNED_ISSUE_ID__`, `__SUMMARY_JSON_PATH__`.

Tests:
- All placeholders replaced
- Unknown placeholders left unchanged
- Empty template returns empty string
- Missing values replaced with empty string

### Phase 2: External Interaction Primitives

These packages wrap external tools (flock, git, tmux, br). They use interfaces so the higher-level packages can be tested with fakes.

#### 2.1: `internal/lock` — File Locking

Port `with-lock.sh` (86 lines). Wraps flock with scope-based lock file paths.

Behavior:
- Default scope `merge`, lock file at `<git-common-dir>/orca-global.lock`
- Non-default scopes use `<git-common-dir>/orca-global-<scope>.lock`
- Configurable timeout (default 120s)
- Executes a function while holding the lock
- Returns the function's error on failure

Interface:
```go
type Locker interface {
    WithLock(scope string, timeout time.Duration, fn func() error) error
}
```

Tests:
- Lock acquired and released
- Concurrent lock attempts block
- Timeout produces error
- Scope determines lock file path

#### 2.2: `internal/git` — Git Operations

Extract git operations used across orca scripts. Not a general-purpose git library — just the operations orca needs.

Operations:
- `RepoRoot(path string) (string, error)` — `git rev-parse --show-toplevel`
- `CommonDir(path string) (string, error)` — `git rev-parse --git-common-dir`
- `CurrentBranch(path string) (string, error)`
- `IsClean(path string) (bool, error)` — porcelain status check
- `HasBeadsChanges(path, base string) (bool, error)` — `.beads` diff check between branches
- `FetchAndPull(path string) error`
- `CreateBranch(path, name, base string) error`
- `Merge(path, source string) error`
- `MergeAbort(path string) error`
- `Push(path string) error`
- `Worktrees(path string) ([]WorktreeInfo, error)`
- `AddWorktree(path, worktreePath, branch, base string) error`
- `AheadBehind(path, local, remote string) (int, int, error)`
- `Describe(path string) (string, error)` — `git describe --always --dirty`

Tests: These wrap `exec.Command`. Test with a real temp git repo in tests — create a temp dir, `git init`, make commits, test operations against it. No mocking git.

#### 2.3: `internal/tmux` — tmux Session Management

Operations:
- `ListSessions() ([]SessionInfo, error)`
- `HasSession(name string) (bool, error)`
- `NewSession(name, command string) error`
- `KillSession(name string) error`
- `SendKeys(session, keys string) error`

Minimal tests: construction and argument formatting. Live tmux tests are integration-level.

#### 2.4: `internal/queue` — Queue Operations

Wraps `br` commands. This replaces `queue-read-main.sh`, `queue-write-main.sh`, `queue-mutate.sh`, and `br-guard.sh`.

Operations:
- `ReadReady(repoPath string) ([]Issue, error)` — lock-guarded read on main
- `Show(repoPath, issueID string) (*Issue, error)`
- `Claim(repoPath, issueID, actor string) error` — lock-guarded claim + publish
- `Comment(repoPath, issueID, actor, comment string) error`
- `Close(repoPath, issueID, actor string) error`
- `Create(repoPath string, opts CreateOpts) (string, error)` — returns new issue ID
- `DepAdd(repoPath, fromID, toID, depType string) error`
- `DepList(repoPath, issueID string) ([]Dep, error)`
- `Sync(repoPath string) error`

All mutating operations follow the pattern: lock → fetch/pull → import → execute br command → flush → commit → push.

The br guard behavior (blocking direct mutation commands in worktrees) is enforced by this package — agent code calls these functions instead of br directly.

Tests:
- Unit tests for argument construction and validation (actor required, safe payload handling)
- Port key assertions from `tests/regression_queue_mutation_guardrails.sh`
- Integration tests with real br are deferred

### Phase 3: Core Operations

These compose the primitives into orca's main operations.

#### 3.1: `internal/merge` — Merge to Main

Port `merge-main.sh` (172 lines). Lock-guarded merge with safety checks.

Behavior:
1. Acquire merge lock
2. Fetch and pull on primary repo main
3. Check source branch for `.beads` changes — reject if present
4. Check primary repo is clean
5. Merge source branch into main
6. Push main
7. On merge failure: abort merge, clean up

Interface:
```go
func MergeToMain(cfg MergeConfig) error

type MergeConfig struct {
    PrimaryRepo string
    Source      string
    Locker      lock.Locker
    LockScope   string
}
```

Tests:
- Successful merge: source merged into main, pushed
- `.beads` in source: rejected
- Dirty primary repo: rejected
- Merge conflict: cleaned up (merge aborted)
- Use real temp git repos with branches

#### 3.2: `internal/worktree` — Worktree Setup

Port `setup-worktrees.sh` (153 lines).

Behavior:
- Create `worktrees/agent-N` on branch `swarm/agent-N` from base ref
- Base ref precedence: `ORCA_BASE_REF` → local `main` → `origin/main` → current branch
- Warn when local main and origin/main diverge (ahead/behind counts)
- Fail fast when explicit `ORCA_BASE_REF` doesn't resolve
- Idempotent: existing worktrees are left alone

Tests:
- Create worktrees in temp repo
- Base ref resolution order
- Divergence warning
- Invalid ORCA_BASE_REF fails

#### 3.3: `internal/loop` — Agent Loop

Port `agent-loop.sh` (1,175 lines). This is the largest and most complex component.

Per-iteration behavior:
1. Create per-run branch from base ref
2. Create run artifact directories (`agent-logs/sessions/YYYY/MM/DD/<session>/runs/<run>/`)
3. Render prompt template with placeholders
4. Execute agent command (codex) once
5. Inject br guard (PATH shim) — in Go this becomes controlling what the subprocess can access
6. Parse summary JSON from run artifact
7. Validate summary schema
8. Restore leftover `.beads` working tree changes
9. Append metrics row to `metrics.jsonl`
10. Capture last-message and compact summary
11. Apply drain policy (sustained no_work → stop)

Loop-level behavior:
- Run up to MAX_RUNS iterations (0 = unbounded)
- Sleep RUN_SLEEP_SECONDS between iterations
- Stop on: max runs reached, drain stop, agent requests stop (loop_action=stop), agent failure
- Watch mode disables no-work auto-stop

The agent command is the only external process the loop doesn't own — it's the codex (or other agent) subprocess. The loop prepares the environment, runs it, and interprets the results.

Decomposition within the loop package:
- `RunOnce(cfg RunConfig) (*model.Summary, RunResult, error)` — single iteration
- `Loop(cfg LoopConfig) error` — the full loop with drain/stop policy
- `renderPrompt(template string, vars map[string]string) string` — delegates to prompt package
- `parseAndValidateSummary(path string) (*model.Summary, []string)` — parse + validate
- `appendMetrics(path string, row model.MetricsRow) error`
- `buildBrGuardEnv(orcaHome string) []string` — PATH with guard shim

Tests:
- Summary parsing and validation: all schema cases (table-driven, port from bash validation logic)
- Metrics row construction and append
- Drain policy: consecutive no_work counting, retry budget, watch mode override
- Port assertions from `tests/regression_drain_stop_observability.sh`
- Port assertions from `tests/regression_assigned_issue_contract.sh`
- Prompt rendering via prompt package tests

Note: Full integration test of the loop requires running an agent command. For unit tests, use a mock agent that writes a predetermined summary JSON.

#### 3.4: `internal/start` — Session Launcher

Port `start.sh` (656 lines). Coordinates everything for launch.

Behavior:
1. Validate all configuration and prerequisites
2. Set up worktrees (via worktree package)
3. Validate worktree cleanliness
4. Run dep-sanity check (via depsanity package)
5. Run planner to assign issues (via plan package)
6. Launch tmux sessions with agent-loop (via tmux package)
7. Inject all runtime environment variables into each session
8. Log launch planning summary

Tests:
- Port from `tests/regression_start_assignment_launch_cap.sh`
- Launch cap: ready count limits launches
- Assignment mode: assigned vs self-select behavior
- Continuous mode rejected in assigned mode
- Dirty worktree blocks launch
- Dep sanity modes: enforce/warn/off

### Phase 4: Operational Commands

#### 4.1: `internal/status` — Status Reporting

Port `status.sh` (234 lines). Read-only snapshot of current state.

Output: active sessions, queue state, latest metrics entry. `--json` mode.

Tests:
- JSON output schema matches current contract
- Port from current status behavior (basic — the status was recently rewritten to be minimal)

#### 4.2: `internal/doctor` — Preflight Checks

Port `doctor.sh` (474 lines). Read-only diagnostic checks.

Checks to port (20 checks):
- Platform detection (WSL/Ubuntu)
- Required binaries (git, tmux, jq, flock, br, codex)
- br version and execution
- Repository context (git worktree, origin remote, reachability)
- Git identity (user.name, user.email)
- Queue workspace (.beads, br doctor, id.prefix)
- Helper scripts present and executable

`--json` mode with stable check IDs, statuses, severities, remediation commands.

Tests:
- Port from `tests/regression_doctor_json_contract.sh`
- JSON output schema: check IDs, statuses, summary counts
- Missing binary detection
- Missing queue workspace detection

#### 4.3: `internal/bootstrap` — Setup Automation

Port `bootstrap.sh` (365 lines). Guided setup with `--yes` and `--dry-run` modes.

Steps:
- Platform validation
- apt dependency installation
- python-is-python3 setup
- br installation
- Queue workspace initialization
- Git identity configuration
- Codex auth verification

Tests:
- Port from `tests/regression_bootstrap_dry_run.sh` and `tests/regression_bootstrap_codex_auth_gate.sh`
- Dry-run mode: no mutations
- Codex auth gate: fails when auth is unresolved

### Phase 5: CLI and Dispatch

#### 5.1: `cmd/orca` — CLI Entrypoint

Single binary with subcommand dispatch. Maps 1:1 to current `orca.sh` dispatch.

Commands:
- `start [count] [--runs N] [--drain|--watch] [--reasoning-level LEVEL]`
- `stop`
- `status [--json]`
- `doctor [--json]`
- `bootstrap [--yes] [--dry-run]`
- `plan [--slots N] [--output PATH]`
- `dep-sanity [--strict]`
- `gc-run-branches [--apply]`
- `setup-worktrees [count]`
- `help`
- `version`

The queue and merge helpers are no longer standalone commands — they are internal functions called by the loop. The agent prompt still references helper paths, but these resolve to the Go binary itself (e.g., `orca queue-write ...`) or to thin wrapper scripts that call the Go binary.

Note on agent integration: agents currently call helper scripts by path (`$ORCA_QUEUE_WRITE_MAIN_PATH`). During the transition, the Go binary can provide these as subcommands (`orca queue-write-main ...`) that the prompt template references. This preserves the agent contract without requiring bash scripts.

#### 5.2: Transition helpers

Add subcommands to the Go binary that replicate the helper script interfaces:
- `orca with-lock [--scope NAME] [--timeout SECONDS] -- <command>`
- `orca queue-read-main [--fallback MODE] -- <command>`
- `orca queue-write-main [--actor NAME] -- <command>`
- `orca queue-mutate [--actor NAME] <mutation> [args...]`
- `orca merge-main [--source BRANCH]`

These allow the prompt template to reference the Go binary for all helper operations, eliminating the need for separate bash scripts.

### Phase 6: Validation and Cutover

#### 6.1: Run existing regression tests against Go binary

Set `ORCA_BIN=./orca-go` or equivalent and run each bash regression test against the Go binary. The tests should pass without modification (they test behavior via CLI interface, not bash internals).

Tests to validate:
- `regression_doctor_json_contract.sh`
- `regression_dep_sanity_check.sh`
- `regression_planner_v1.sh`
- `regression_bootstrap_dry_run.sh`
- `regression_bootstrap_codex_auth_gate.sh`
- `regression_queue_mutation_guardrails.sh`
- `regression_drain_stop_observability.sh`
- `regression_assigned_issue_contract.sh`
- `regression_start_assignment_launch_cap.sh`

#### 6.2: End-to-end smoke test

Create a test issue, run `orca-go start 1 --runs 1`, verify:
- Agent session launches
- Summary JSON produced
- Metrics appended
- Issue claimed and closed
- Code merged to main

#### 6.3: Cutover

1. Rename Go binary from `orca-go` to `orca`.
2. Delete all bash scripts (`.sh` files at repo root and `lib/`).
3. Delete bash regression tests (they're now covered by Go tests).
4. Update `ORCA_PROMPT.md` helper paths to reference the Go binary.
5. Update documentation.
6. Push.

## Implementation Sequence

Build in this order. Each phase produces a `go test ./...`-passing commit.

```
Phase 1 (no external deps, pure logic):
  1.1 model       → types + validation tests
  1.2 plan        → planner + regression parity tests
  1.3 depsanity   → checker + regression parity tests
  1.4 prompt      → renderer + tests

Phase 2 (external tool wrappers):
  2.1 lock        → flock wrapper + tests
  2.2 git         → git operations + tests with temp repos
  2.3 tmux        → tmux wrapper
  2.4 queue       → br wrapper + guard logic + tests

Phase 3 (core operations):
  3.1 merge       → merge-to-main + tests with temp repos
  3.2 worktree    → setup + tests with temp repos
  3.3 loop        → agent loop + drain/summary tests
  3.4 start       → launcher + tests

Phase 4 (operational commands):
  4.1 status      → reporter + json tests
  4.2 doctor      → checker + json contract tests
  4.3 bootstrap   → setup + dry-run tests

Phase 5 (CLI):
  5.1 cmd/orca    → dispatch + flag parsing
  5.2 helpers     → queue-write-main, merge-main subcommands

Phase 6 (validation):
  6.1 bash regression tests against Go binary
  6.2 end-to-end smoke test
  6.3 cutover: delete bash, update docs
```

## Reference Files

The implementing agent should read these files to understand the behavior being ported:

| Go Package | Bash Source | Regression Test |
|---|---|---|
| `model` | `agent-loop.sh` (lines ~700-850, schema validation) | — |
| `plan` | `plan.sh` | `tests/regression_planner_v1.sh` |
| `depsanity` | `dep-sanity.sh` | `tests/regression_dep_sanity_check.sh` |
| `prompt` | `agent-loop.sh` (lines ~500-520, placeholder rendering) | — |
| `lock` | `with-lock.sh` | — |
| `git` | operations scattered across `merge-main.sh`, `setup-worktrees.sh`, `agent-loop.sh`, `gc-run-branches.sh` | — |
| `tmux` | `start.sh` (session creation), `stop.sh`, `status.sh` | — |
| `queue` | `queue-read-main.sh`, `queue-write-main.sh`, `queue-mutate.sh`, `br-guard.sh`, `lib/br-command-policy.sh` | `tests/regression_queue_mutation_guardrails.sh` |
| `merge` | `merge-main.sh` | — |
| `worktree` | `setup-worktrees.sh` | — |
| `loop` | `agent-loop.sh` | `tests/regression_drain_stop_observability.sh`, `tests/regression_assigned_issue_contract.sh` |
| `start` | `start.sh` | `tests/regression_start_assignment_launch_cap.sh` |
| `status` | `status.sh` | — |
| `doctor` | `doctor.sh` | `tests/regression_doctor_json_contract.sh` |
| `bootstrap` | `bootstrap.sh` | `tests/regression_bootstrap_dry_run.sh`, `tests/regression_bootstrap_codex_auth_gate.sh` |

## Invariants to Preserve

These must hold throughout the rewrite and after cutover:

1. **Artifact contract unchanged.** Session naming, directory structure, summary JSON schema, metrics JSONL schema — all per `docs/artifact-contract.md`. Watch depends on these.
2. **Agent prompt contract unchanged.** `ORCA_PROMPT.md` and its placeholder substitution must produce the same rendered output.
3. **Queue safety preserved.** Lock-guarded claim publication, `.beads` source-branch guard, queue mutation routing through helpers.
4. **CLI interface unchanged.** Same commands, same flags, same exit codes. Scripts and automation that call `orca` must not break.
5. **Cross-project operation works.** `ORCA_HOME` resolution, prompt fallback (target repo then orca home), helper paths relative to orca home.
