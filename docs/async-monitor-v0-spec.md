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

---

## 2) v0 boundaries

### In scope
- local terminal output only,
- user-global observed-target registry,
- notify-only behavior.

### Out of scope
- daemon/service mode,
- auto-restart/retry,
- remote notification sinks,
- heartbeat protocol for observed targets.

---

## 3) Command surface

Top-level additions to `orca.sh`:
- `monitor`
- `observe`

### 3.1 `monitor --follow`

```bash
./orca.sh monitor --follow \
  [--poll-interval SECONDS] \
  [--session-id ID] \
  [--session-prefix PREFIX] \
  [--json]
```

Behavior:
- Foreground stream only.
- Merges:
  - managed lifecycle events from `./orca.sh status --follow`
  - observed target liveness events from registry + tmux polling

Defaults:
- `--poll-interval 5`

Filtering:
- `--session-id` / `--session-prefix` match `session_id` in emitted events.
- For observed targets, `session_id` is the registry `id`.

### 3.2 `monitor add`

```bash
./orca.sh monitor add --id AGENT_ID --profile PROFILE --tmux-target TARGET [--cwd PATH]
```

Registers an existing tmux target for observation.

### 3.3 `monitor remove`

```bash
./orca.sh monitor remove --id AGENT_ID
```

Removes registry entry only. Never kills tmux processes.

### 3.4 `monitor list`

```bash
./orca.sh monitor list [--json]
```

Lists observed registry entries.

### 3.5 `observe start`

```bash
./orca.sh observe start \
  --id AGENT_ID \
  --profile PROFILE \
  --tmux-target TARGET \
  --cwd PATH \
  -- <command...>
```

Creates a detached tmux target and registers it.

**Collision policy (v0):** fail if target session already exists. No replace/attach/force modes.

---

## 4) Target model and identity

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

## 5) Validation rules

Common:
1. `AGENT_ID` matches `^[a-zA-Z0-9._:-]+$`
2. `PROFILE` is one of: `fire_forget`, `persistent`
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

## 6) Observed registry

Location (default):
- `${XDG_STATE_HOME:-$HOME/.local/state}/orca/observed-sessions.json`

Lock file:
- `${XDG_STATE_HOME:-$HOME/.local/state}/orca/observed-sessions.lock`

Override:
- `ORCA_OBSERVED_REGISTRY_PATH`

Write semantics:
- lock-guarded,
- atomic write (`tmp` + rename).

Schema:

```json
{
  "schema_version": "orca.observed.v1",
  "updated_at": "2026-03-12T10:30:00+01:00",
  "entries": [
    {
      "id": "librarian",
      "mode": "observed",
      "profile": "persistent",
      "tmux_target": "work:librarian",
      "cwd": "/home/jsk/code/ai-resources",
      "command": "python3 tools/librarian_loop.py",
      "created_at": "2026-03-12T10:00:00+01:00",
      "source": "observe_start"
    }
  ]
}
```

Notes:
- `command` may be omitted for `monitor add` entries.
- `source` is `monitor_add` or `observe_start`.

---

## 7) Monitor event schema

`schema_version = orca.monitor.v1`

```json
{
  "schema_version": "orca.monitor.v1",
  "event_type": "run_started|run_completed|run_failed|loop_stopped|session_up|session_down",
  "observed_at": "2026-03-12T10:32:10+01:00",
  "session_id": "orca-agent-1-20260312T103000",
  "mode": "managed|observed",
  "profile": "fire_forget|persistent",
  "tmux_target": "orca-agent-1",
  "run": {
    "run_id": "run-0003",
    "summary_path": "agent-logs/sessions/.../summary.json"
  }
}
```

Field semantics:
- `session_id`
  - managed: Orca session id
  - observed: registry `id`
- `tmux_target`
  - managed: tmux session name
  - observed: registered `session` or `session:window`
- `run` is omitted/null for observed liveness events.

---

## 8) Exit codes

- `0` success
- `3` operational failure
- `4` invalid usage

`monitor --follow` runs until interrupted and exits `0` on clean interrupt.

---

## 9) Acceptance tests

1. `monitor add` rejects invalid/non-existing targets.
2. `monitor add` rejects duplicate `id` and duplicate `tmux_target`.
3. `observe start` creates target + registry entry.
4. `observe start` fails if parsed target session already exists.
5. `observe start` fails on invalid cwd with no side effects.
6. `monitor remove` only removes registry entry.
7. `monitor --follow` emits managed lifecycle events (`run_started`, `run_completed`, `run_failed`, `loop_stopped`).
8. `monitor --follow` emits `session_up/session_down` for observed targets.
9. Registry writes stay atomic under concurrent add/remove operations.
