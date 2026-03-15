# Async Monitor v0 Specification

**Status:** Draft (implementation target)  
**Date:** 2026-03-12  
**Scope:** Local, foreground monitoring for managed Orca sessions and observed tmux targets.

---

## 1) Intent

Provide a small, composable monitoring toolset with explicit state and deterministic behavior.

v0 must support:
1. foreground monitoring of managed Orca runs,
2. monitoring of manually managed persistent tmux targets,
3. one-step creation + registration of observed tmux targets.

### 1.1 Decision rationale (prototype phase)

This spec applies Orca's prototype-phase CLI principles:

1. Prototype-first break policy: compatibility is not required yet; breaking changes are acceptable when they simplify behavior or solve demonstrated operator pain.
2. Follow is human-first live awareness: follow surfaces prioritize clear real-time transitions for operators while remaining script-readable.
3. Status is snapshot-oriented: snapshot diagnostics stay on `status`; follow remains opt-in for continuous awareness.
4. Complexity must be earned: new modes/flags/coupling require concrete user/operator evidence.

This rationale is mirrored in `README.md` and `OPERATOR_GUIDE.md` to reduce future drift.

---

## 2) v0 boundaries

### In scope
- local terminal output only,
- user-global observed-target registry,
- notify-only behavior,
- composition over existing Orca status/events.

### Out of scope
- daemon/service mode,
- auto-restart/retry,
- remote notification sinks,
- heartbeat protocol for observed targets.

---

## 3) Core contracts required for layering

This spec is intentionally layered on top of core Orca behavior. To keep monitor/observe as composition (not deep coupling), core contracts must be explicit and stable.

### 3.1 Canonical follow event contract

`./orca.sh status --follow` is the canonical managed-event source.

Required canonical event schema for follow streams:
- `schema_version = "orca.monitor.v2"`
- event types: `session_up`, `session_down`, `run_started`, `run_completed`, `run_failed`
- `session_started` and `loop_stopped` are not emitted in v2
- output transport is append-only JSONL; each emitted event is appended as a new line at stream bottom
- ordering guarantee is emission order (line order on stdout); previously emitted lines are never rewritten

Intent note: `status --follow` exists to provide managed live-awareness transitions; it is not a replacement for snapshot status surfaces (`status --quick|--full|--json`).

Each emitted event MUST include:
- `schema_version`
- `event_id`
- `event_type`
- `observed_at`
- `session_id`
- `mode` (`managed` or `observed`)
- `tmux_target` (string; nullable only when truly unavailable)

Optional fields:
- `run` (required for `run_*`, omitted/null for session liveness events)
- `lifecycle` (`ephemeral|persistent`, optional metadata)

### 3.2 Managed session liveness semantics (`status --follow`)

For `mode="managed"`, session liveness is derived from tmux target availability, not run summaries.

- Default follow mode (`status --follow` without replay flag) starts from current snapshot and emits no startup replay for already-active historical sessions.
- Replay mode (`status --follow --replay-baseline`) emits startup transitions for historical state as legacy catch-up behavior.
- `session_up` is emitted on an `inactive -> active` transition (including first observation in replay mode).
- `session_down` is emitted on an `active -> inactive` transition.
- `session_down` is **not** inferred from graceful loop stop, run completion, or summary result.
- Legacy lifecycle names (`session_started`, `loop_stopped`) are invalid for v2 streams.

### 3.3 Event identity formats and de-dup

`event_id` is part of the wire contract and MUST use these exact formats:

- `session_up:<session_id>`
- `session_down:<session_id>`
- `run_started:<session_id>:<run_id>`
- `run_completed:<session_id>:<run_id>`
- `run_failed:<session_id>:<run_id>`

Additional requirements:

- `run_id` is required for `run_*` events.
- Follow emitters MUST only emit transitions (edge-triggered), not level-triggered repeats.
- The same transition MUST NOT be emitted repeatedly across unchanged poll snapshots.

---

## 4) Command surface

Top-level additions to `orca.sh`:
- `monitor`
- `observe`

### 4.1 `monitor --follow`

```bash
./orca.sh monitor --follow \
  [--poll-interval SECONDS] \
  [--max-events N] \
  [--replay-baseline] \
  [--session-id ID] \
  [--session-prefix PREFIX]
```

Behavior:
- foreground stream only,
- merged JSONL output in canonical event schema (`orca.monitor.v2`),
- merges:
  - managed lifecycle events from `./orca.sh status --follow`
  - observed target liveness events from registry + tmux polling,
- merged stream is append-only JSONL with newest events appended at bottom in monitor emission order,
- default mode is live-from-now (no startup replay for managed or observed paths),
- `--replay-baseline` restores startup replay semantics,
- hard-fails if `tmux` is unavailable (no degraded mode in v0).

Intent note: `monitor --follow` is the unified live-awareness surface when both managed and observed targets matter.

Defaults:
- `--poll-interval 5`
- `--max-events 0` (unbounded)

Filtering:
- `--session-id` / `--session-prefix` match emitted `session_id`.
- For observed targets, `session_id` is the registry `id`.

### 4.2 `monitor add`

```bash
./orca.sh monitor add --id AGENT_ID --lifecycle LIFECYCLE --tmux-target TARGET [--cwd PATH]
```

Registers an existing tmux target for observation.

### 4.3 `monitor remove`

```bash
./orca.sh monitor remove --id AGENT_ID
```

Removes registry entry only. Never kills tmux processes.

### 4.4 `monitor list`

```bash
./orca.sh monitor list [--json]
```

Lists observed registry entries.

### 4.5 `observe start`

```bash
./orca.sh observe start \
  --id AGENT_ID \
  --lifecycle LIFECYCLE \
  --tmux-target TARGET \
  --cwd PATH \
  -- <command...>
```

Creates a detached tmux target and registers it.

Intent note: `observe start` is a lifecycle operation (create + register), not a monitoring stream.

**Collision policy (v0):** fail if target session already exists. No replace/attach/force modes.

---

## 5) Target model and identity

`TARGET` supports:
- `session`
- `session:window`

Validation:
- `session` and `window` each match `^[a-zA-Z0-9._-]+$`
- pane-level addressing is not supported in v0

Existence checks:
- `session`: `tmux has-session -t <session>`
- `session:window`: `tmux list-windows -t <session>` contains `<window>`

### Strict identity rule (v0)

Observed target identity is the exact `tmux_target` string in the registry.

Implications:
- no heuristic matching,
- no auto-rebinding on rename,
- a rename is treated as target loss (`session_down`) until explicitly re-registered.

---

## 6) Validation rules

Common:
1. `AGENT_ID` matches `^[a-zA-Z0-9._:-]+$`
2. `LIFECYCLE` is one of: `ephemeral`, `persistent`
3. `id` is unique in registry
4. `tmux_target` is unique in registry

`monitor add`:
- target must already exist.

`observe start`:
1. target must parse and be valid,
2. `--cwd` must exist and be a directory,
3. command after `--` must be non-empty,
4. parsed target session must not already exist.

`observe start` creation:
- `session`: `tmux new-session -d -s <session> -c <cwd> <cmd>`
- `session:window`: `tmux new-session -d -s <session> -n <window> -c <cwd> <cmd>`

Failure rollback:
- if tmux creation succeeds but registry write fails, attempt `tmux kill-session -t <session>`.

---

## 7) Observed registry

Location (default):
- `${XDG_STATE_HOME:-$HOME/.local/state}/orca/observed-sessions.json`

Lock file:
- `${XDG_STATE_HOME:-$HOME/.local/state}/orca/observed-sessions.lock`

Override:
- `ORCA_OBSERVED_REGISTRY_PATH`

Write semantics:
- lock-guarded,
- atomic write (`tmp` + rename in same directory).

Load semantics (strict, v0):
- `monitor list`, `monitor add`, `monitor remove`, and `observe start` reject malformed/invalid registry documents instead of repairing them.
- registry entry constraints are enforced at load-time:
  - `id` must match `^[A-Za-z0-9._:-]+$`
  - `lifecycle` must be `ephemeral|persistent` when present
  - `tmux_target` must be a non-empty string
- invalid registry documents/entries are operational failures (exit code `3` from monitor/observe commands).
- normalization/auto-repair is intentionally out of scope; operators must fix or remove invalid entries explicitly.

Schema:

```json
{
  "schema_version": "orca.observed.v1",
  "updated_at": "2026-03-12T10:30:00+01:00",
  "entries": [
    {
      "id": "librarian",
      "mode": "observed",
      "lifecycle": "persistent",
      "tmux_target": "work:librarian",
      "cwd": "/home/jsk/code/ai-resources",
      "command": "python3 tools/librarian_loop.py",
      "repo_root": "/mnt/c/code/ai-resources",
      "created_at": "2026-03-12T10:00:00+01:00",
      "source": "observe_start"
    }
  ]
}
```

Notes:
- `command` may be omitted for `monitor add` entries.
- `repo_root` is optional metadata for operator context (global registry remains intentional).
- `source` is `monitor_add` or `observe_start`.

---

## 8) Monitor event schema

`schema_version = orca.monitor.v2`

```json
{
  "schema_version": "orca.monitor.v2",
  "event_id": "run_completed:orca-agent-1-20260312T103000Z:run-0003",
  "event_type": "run_started|run_completed|run_failed|session_up|session_down",
  "observed_at": "2026-03-12T10:32:10+01:00",
  "session_id": "orca-agent-1-20260312T103000Z",
  "mode": "managed|observed",
  "lifecycle": "ephemeral|persistent|null",
  "tmux_target": "orca-agent-1",
  "run": {
    "run_id": "run-0003",
    "state": "completed",
    "result": "completed",
    "issue_status": "closed",
    "summary_path": "agent-logs/sessions/.../summary.json"
  }
}
```

Field semantics:
- `session_id`
  - managed: Orca session id
  - observed: registry `id`
- `event_id`
  - exact format is defined in section 3.3
  - stable key for downstream de-duplication and idempotent consumers
- `tmux_target`
  - managed: tmux session name
  - observed: registered `session` or `session:window`
- `run`
  - required for `run_started|run_completed|run_failed`
  - omitted/null for `session_up|session_down`
- `lifecycle`
  - optional metadata (`ephemeral|persistent`)
  - may be null/omitted when unknown

---

## 9) Exit codes

- `0` success
- `3` operational failure
- `4` invalid usage

`monitor --follow` runs until interrupted and exits `0` on clean interrupt.
`monitor --follow` exits `3` when `tmux` is unavailable.

---

## 10) Acceptance tests

1. `monitor add` rejects invalid/non-existing targets.
2. `monitor add` rejects duplicate `id` and duplicate `tmux_target`.
3. `observe start` creates target + registry entry.
4. `observe start` fails if parsed target session already exists.
5. `observe start` fails on invalid cwd with no side effects.
6. `monitor remove` only removes registry entry.
7. `status --follow` emits canonical managed events in `orca.monitor.v2` with event types limited to `session_up|session_down|run_started|run_completed|run_failed`.
8. Managed `session_down` is emitted only on tmux liveness transition `active -> inactive` (not from graceful-stop inference).
9. `status --follow` uses exact v2 `event_id` formats from section 3.3 for every event type.
10. `monitor --follow` emits managed events without schema drift from `status --follow`.
11. `monitor --follow` emits `session_up/session_down` for observed targets.
12. `monitor --follow` hard-fails with exit code `3` when `tmux` is unavailable.
13. Follow events do not emit duplicate transition events for unchanged state.
14. Default follow mode emits only post-subscription transitions; startup baseline replay requires explicit `--replay-baseline`.
15. Registry writes stay atomic under concurrent add/remove operations.

---

## 11) Breaking-change note

This v0 spec intentionally defines a clean-break follow contract:
- `session_started` is replaced by `session_up`
- `loop_stopped` is replaced by `session_down`
- follow schema version is `orca.monitor.v2`
- v2 `event_id` formats are fixed as listed in section 3.3
