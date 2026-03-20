# Orca Artifact Contract

This document defines the structured outputs that orca produces. External tools (watch, lore) depend on these formats. Changes to schemas, paths, or naming conventions in this document are breaking changes across the ecosystem.

See `docs/ecosystem.md` for the broader tool relationship.

## Session Naming Convention

Orca tmux sessions are named: `<prefix>-<agent-index>-<timestamp>`

- Default prefix: `orca-agent` (configurable via `SESSION_PREFIX`)
- Agent index: integer (1, 2, ...)
- Timestamp: UTC, format `YYYYMMDDTHHMMSSz`

Example: `orca-agent-1-20260315T145918Z`

External tools can identify orca sessions by matching the prefix pattern.

## Directory Structure

All artifacts live under `agent-logs/` relative to the project repo root.

```
agent-logs/
├── metrics.jsonl                          # append-only metrics stream
├── plans/
│   └── YYYY/MM/DD/
│       ├── plan-<timestamp>.json          # assignment plan artifacts
│       └── dep-sanity-<timestamp>.json    # dependency sanity check artifacts
└── sessions/
    └── YYYY/MM/DD/
        └── <session-id>/
            ├── session.log                # session-level log
            └── runs/
                └── <run-id>/
                    ├── run.log            # full run output log
                    ├── summary.json       # structured run summary (required)
                    ├── summary.md         # compact human-readable summary (optional)
                    └── last-message.md    # agent's final message capture (optional)
```

### Session ID

Format: `<agent-name>-<UTC-timestamp>` (e.g., `agent-1-20260315T145918Z`).

Matches the tmux session name minus the `SESSION_PREFIX` root.

### Run ID

Format: `<sequence>-<UTC-timestamp-with-nanoseconds>` (e.g., `0001-20260315T145919063897517Z`).

Sequence is zero-padded, monotonically increasing within a session.

### Date Partitioning

Sessions are partitioned by the date extracted from the session ID timestamp: `YYYY/MM/DD/`.

## Summary JSON Schema

Each run produces a `summary.json` with the following fields:

| Field | Type | Required | Values / Notes |
|---|---|---|---|
| `issue_id` | string | yes | Issue handled in this run. Empty string when no issue was claimed. |
| `result` | string | yes | `completed`, `blocked`, `no_work`, `failed` |
| `issue_status` | string | yes | Issue status after this run. Empty string for `no_work`. |
| `merged` | boolean | yes | `true` only when merge/integration completed. |
| `loop_action` | string | yes | `continue` or `stop` |
| `loop_action_reason` | string | yes | Reason for selected loop action. Empty string allowed. |
| `notes` | string | yes | Short run note or handoff summary. |
| `discovery_ids` | array[string] | no | Follow-up issue IDs created in this run. |
| `discovery_count` | integer | no | When present, should equal `discovery_ids.length`. |

When `ORCA_ASSIGNED_ISSUE_ID` is set, `issue_id` must exactly match that ID.

## Metrics JSONL Schema

Each run appends one JSON object to `agent-logs/metrics.jsonl`. Fields:

| Field | Type | Notes |
|---|---|---|
| `timestamp` | string | ISO 8601 with timezone |
| `agent_name` | string | e.g., `agent-1` |
| `session_id` | string | Full session ID |
| `harness_version` | string | `git describe --always --dirty` from harness repo |
| `run_number` | integer | 1-indexed run count within session |
| `exit_code` | integer | Agent process exit code |
| `result` | string | Parsed from summary: `completed`, `blocked`, `no_work`, `failed` |
| `reason` | string | Loop-level reason code (e.g., `agent-exit-0`) |
| `assigned_issue_id` | string \| null | Assigned issue ID when in assigned mode |
| `planned_assigned_issue` | string \| null | Planned issue ID for assignment telemetry |
| `assignment_source` | string | `planner` or `self-select` |
| `assignment_outcome` | string | `matched`, `mismatch`, `unassigned` |
| `issue_id` | string | From summary JSON |
| `mode_id` | string \| null | Optional mode identifier |
| `approach_source` | string \| null | Optional approach file path |
| `approach_sha256` | string \| null | SHA256 of approach content |
| `durations_seconds` | object | `{ "iteration_total": <seconds> }` |
| `tokens_used` | integer | Token count for the run |
| `tokens_parse_status` | string | `ok` or error indicator |
| `summary_parse_status` | string | `parsed`, `missing`, `invalid_json` |
| `summary_schema_status` | string | `valid`, `invalid`, `not_checked` |
| `summary_schema_reason_codes` | array[string] | Validation failure codes when invalid |
| `summary` | object | Subset of parsed summary fields (see below) |
| `files` | object | Absolute paths to run artifacts (see below) |

### `summary` sub-object

| Field | Type | Notes |
|---|---|---|
| `result` | string | From summary JSON |
| `issue_status` | string | From summary JSON |
| `merged` | boolean | From summary JSON |
| `discovery_count` | integer \| null | From summary JSON |
| `discovery_ids` | array[string] | From summary JSON |
| `assignment_match` | boolean \| null | Whether `issue_id` matched assignment |
| `planned_assigned_issue` | string \| null | Mirror of top-level field |
| `assignment_source` | string | Mirror of top-level field |
| `assignment_outcome` | string | Mirror of top-level field |
| `loop_action` | string | From summary JSON |
| `loop_action_reason` | string | From summary JSON |

### `files` sub-object

| Field | Type | Notes |
|---|---|---|
| `run_log` | string | Absolute path to `run.log` |
| `summary_json` | string | Absolute path to `summary.json` |
| `summary_markdown` | string | Absolute path to `summary.md` (may not exist) |
| `agent_last_message` | string | Absolute path to `last-message.md` (may not exist) |

## Run Branch Naming

Run branches follow the pattern: `swarm/<agent-name>-run-<session-id>-<run-number>-<run-timestamp>`

Example: `swarm/agent-1-run-agent-1-20260315T145918Z-0001-20260315T145919063897517Z`

Run branches are local transport state and are not pushed to origin.

## Stability Guarantees

- Field additions to summary JSON or metrics JSONL are non-breaking.
- Field removals or type changes are breaking.
- Path structure changes (directory hierarchy, file names) are breaking.
- Session naming convention changes are breaking.
