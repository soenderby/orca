# Async Dispatch Loop (External Utility)

`dispatch-loop.sh` is a reusable background launcher for Orca-style batch execution.

It is intentionally **not** part of the `orca` command surface.

## Purpose

When you want to keep work flowing without manually re-running `orca start`, this loop:

1. polls queue/session signals,
2. launches a bounded wave when no agent sessions are active and ready work exists,
3. repeats until stopped (or until open count reaches zero, by default).

This allows you to keep chatting with an orchestrating agent while execution continues asynchronously in the background.

## Script Location

- `./dispatch-loop.sh`

## Default Behavior

On each cycle, the loop runs these command hooks inside the repo:

- open count:
  - `br list --status open --json 2>/dev/null | jq "length"`
- ready count:
  - `br ready --json 2>/dev/null | jq "length"`
- active session count:
  - `./orca.sh status --quick --json 2>/dev/null | jq -r ".signals.sessions_total // 0"`
- launch command (when active=0 and ready>0):
  - `./orca.sh start "${DISPATCH_SLOTS}" --continuous`

Where:
- `DISPATCH_SLOTS = min(ready_count, --max-slots)`

The loop exits when open count reaches zero unless `--no-stop-when-open-zero` is set.

## Usage

### Foreground

```bash
./dispatch-loop.sh --max-slots 2 --poll-interval 20
```

### One-cycle check (no loop)

```bash
./dispatch-loop.sh --once
```

### Dry-run (show launch intent, no starts)

```bash
./dispatch-loop.sh --dry-run --once
```

### Background (nohup pattern)

```bash
ts="$(date -u +%Y%m%dT%H%M%SZ)"
log="agent-logs/dispatch-loop-${ts}.log"
pidfile="agent-logs/dispatch-loop-${ts}.pid"
nohup ./dispatch-loop.sh --max-slots 2 --poll-interval 20 >"${log}" 2>&1 < /dev/null &
echo $! > "${pidfile}"
```

Stop later:

```bash
kill "$(cat <pidfile>)"
```

## Locking / Single-instance Safety

The loop acquires an exclusive file lock (default: `<git-common-dir>/orca-dispatch-loop.lock`).

- Without `--wait-lock` (default), a second loop exits with code `11`.
- With `--wait-lock`, a second loop blocks until lock is available.

## Customization Hooks

You can override command hooks to reuse this loop pattern in related tools:

```bash
./dispatch-loop.sh \
  --open-count-cmd '<command returning integer>' \
  --ready-count-cmd '<command returning integer>' \
  --active-count-cmd '<command returning integer>' \
  --launch-cmd '<command that uses ${DISPATCH_SLOTS}>'
```

Requirements for hooks:

- count hooks must print a non-negative integer,
- launch hook should return non-zero on failure,
- all hooks run via `bash -lc` in `--repo`.

## Operational Notes

- This utility does not replace `orca monitor/follow`; use those for live awareness.
- Keep `--max-slots` aligned with available worktrees and desired concurrency.
- If your queue contains intentionally open tracker issues, consider whether exit-on-open-zero behavior matches your workflow.
- Launch failures are logged and retried on the next cycle.
