# Async Monitor v0 Acceptance Matrix

**Status:** Active  
**Spec source:** `docs/async-monitor-v0-spec.md` section 10  
**Goal:** auditable mapping from each v0 acceptance criterion (1..14) to regression coverage and sign-off commands.

## Coverage Matrix

| # | Acceptance criterion | Regression coverage (file + assertion location) | Status |
| --- | --- | --- | --- |
| 1 | `monitor add` rejects invalid/non-existing targets. | `tests/regression_monitor_observe_commands.sh` checks invalid `--tmux-target` syntax (`bad/target`, exit `4`) and non-existing tmux target (`existing:missing`, exit `3`) in the monitor-add block. | Covered |
| 2 | `monitor add` rejects duplicate `id` and duplicate `tmux_target`. | `tests/regression_monitor_primitives.sh` asserts `orca_observed_registry_add` fails for duplicate `id` and duplicate `tmux_target`. | Covered |
| 3 | `observe start` creates target + registry entry. | `tests/regression_monitor_observe_commands.sh` checks successful `observe start` returns `source=observe_start` and logs expected `tmux new-session` command. | Covered |
| 4 | `observe start` fails if parsed target session already exists. | `tests/regression_monitor_observe_commands.sh` runs `observe start --tmux-target existing:new`, expects exit `3`, and asserts no `new-session` call for `existing`. | Covered |
| 5 | `observe start` fails on invalid cwd with no side effects. | `tests/regression_monitor_observe_commands.sh` runs invalid `--cwd`, expects exit `4`, and verifies tmux log line count is unchanged. | Covered |
| 6 | `monitor remove` only removes registry entry. | `tests/regression_monitor_observe_commands.sh` verifies removed id is absent from `monitor list --json` and no `kill-session` is invoked. | Covered |
| 7 | `status --follow` emits canonical managed events in `orca.monitor.v2` with allowed event types. | `tests/regression_status_follow_monitor.sh` checks event set/order (`session_up`, `run_started`, `run_completed`, `session_down`), schema `orca.monitor.v2`, and denies legacy types. | Covered |
| 8 | Managed `session_down` is emitted only on tmux `active -> inactive` transition. | `tests/regression_status_follow_monitor.sh` flips stub tmux mode from `active` to `inactive` before asserting `session_down` emission in ordered sequence. | Covered |
| 9 | `status --follow` uses exact v2 `event_id` formats for all event types. | `tests/regression_status_follow_monitor.sh` checks exact ordered `event_id` string: `session_up:<session>`, `run_started:<session>:<run>`, `run_completed:<session>:<run>`, `session_down:<session>`. | Covered |
| 10 | `monitor --follow` emits managed events without schema drift from `status --follow`. | `tests/regression_monitor_follow_stream.sh` injects managed event with `passthrough_marker` and asserts byte-for-byte passthrough and ordering in merged stream. | Covered |
| 11 | `monitor --follow` emits `session_up/session_down` for observed targets. | `tests/regression_monitor_follow_stream.sh` asserts observed up/down transitions and exact observed `event_id` values (`session_up:observed-1`, `session_down:observed-1`). | Covered |
| 12 | `monitor --follow` hard-fails with exit code `3` when `tmux` is unavailable. | `tests/regression_monitor_follow_stream.sh` validates both missing tmux binary and failed tmux health probe return exit `3`. | Covered |
| 13 | Follow events do not emit duplicate transition events for unchanged state. | `tests/regression_status_follow_monitor.sh` checks no duplicate `run_started` ids; `tests/regression_monitor_follow_stream.sh` asserts deduped managed replay and exactly one observed up/down transition per unchanged state. | Covered |
| 14 | Registry writes stay atomic under concurrent add/remove operations. | `tests/regression_monitor_primitives.sh` concurrent add/remove parseability loop; `tests/stress_monitor_registry_contention.sh` multi-writer/multi-reader contention with schema/invariant checks and temp-file cleanup validation. | Covered |

## v0 Sign-off Validation Bundle

Run from repo root:

```bash
bash tests/regression_monitor_observe_commands.sh
bash tests/regression_monitor_primitives.sh
bash tests/regression_status_follow_monitor.sh
bash tests/regression_monitor_follow_stream.sh
bash tests/stress_monitor_registry_contention.sh
```

Sign-off rule: all commands must exit `0`.
