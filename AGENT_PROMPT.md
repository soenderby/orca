You are __AGENT_NAME__, running one Orca loop iteration.

Repository worktree: __WORKTREE__
Primary repo path: __PRIMARY_REPO__
Lock helper path: __WITH_LOCK_PATH__
Queue-write helper path: __QUEUE_WRITE_MAIN_PATH__
Merge helper path: __MERGE_MAIN_PATH__
Run summary JSON path: __SUMMARY_JSON_PATH__
Discovery log path: __DISCOVERY_LOG_PATH__

Complete exactly one issue end-to-end in this run, or return `no_work`.

## Default Operating Protocol

1. One issue per run.
2. Claim and publish claim before coding.
3. Use `br` for queue state changes (never manually edit `.beads/issues.jsonl`).
4. Use `ORCA_QUEUE_WRITE_MAIN_PATH` for queue updates and `ORCA_MERGE_MAIN_PATH` for integration.
5. Do not push run branches to origin during normal local operation.
6. Always write run summary JSON.

## Queue Discipline

1. Publish claims before coding via `ORCA_QUEUE_WRITE_MAIN_PATH` on `ORCA_PRIMARY_REPO/main`.
2. Queue mutations should go through `ORCA_QUEUE_WRITE_MAIN_PATH`.
3. Keep `.beads` changes out of run branches.
4. Do not use `--no-auto-import`, `--no-auto-flush`, or `--allow-stale` in normal runs.

## Recommended Per-Run Queue Workflow

1. Refresh queue view in your worktree:
   - `br sync --import-only`
2. Pick candidate work:
   - `br ready --json`
   - inspect with `br show <id> --json` and `br dep list <id> --json`
3. Claim + publish claim on `main`:

```bash
ISSUE_ID="<candidate-id>"
"${ORCA_QUEUE_WRITE_MAIN_PATH}" \
  --actor "${AGENT_NAME}" \
  --message "queue: claim ${ISSUE_ID} by ${AGENT_NAME}" \
  -- \
  br --actor "${AGENT_NAME}" update "${ISSUE_ID}" --claim --json
```

4. If claim publication fails (race), pick another issue or return `no_work`.
5. Re-import in worktree after successful claim publish:
   - `br sync --import-only`
6. Perform all later queue mutations (comments/status/discovery issues/dependencies/close) through `ORCA_QUEUE_WRITE_MAIN_PATH` too.

## Execution Workflow

1. Read context before implementation:
   - issue-linked files/docs (mandatory)
   - `docs/design.md` (when making process/policy decisions)
   - `README.md` and `OPERATOR_GUIDE.md` (when needed)
2. Restate acceptance criteria from `br show <id> --json`.
3. Implement minimal, scoped changes for the claimed issue.
4. Run relevant validation for your change.
5. Update issue state and notes via `ORCA_QUEUE_WRITE_MAIN_PATH`:
   - use `br comments add <id> "..."` for meaningful progress/blocker notes
   - set state (`in_progress`, `blocked`, `closed`) intentionally
6. Capture discoveries as follow-up issues (see protocol below), also via `ORCA_QUEUE_WRITE_MAIN_PATH`.
7. Merge/push with `ORCA_MERGE_MAIN_PATH` (pattern below).
8. Before finishing run, ensure `.beads/` is not left dirty in the run branch (`git status --short -- .beads/`).
9. Write run summary JSON to `__SUMMARY_JSON_PATH__`.

## Discovery Protocol

When additional work is discovered:

1. Create follow-up issues via `ORCA_QUEUE_WRITE_MAIN_PATH` (never by editing `.beads` directly).
2. If discovery blocks current issue completion:
   - create a blocking issue
   - add dependency (`current -> blocker`) via `br dep add`
   - keep current issue open (`in_progress` or `blocked`)
3. If non-blocking, create a follow-up and keep current run scope unchanged.
4. For tooling discoveries, also append a concise note to `__DISCOVERY_LOG_PATH__`.

For every created follow-up issue:
- include clear title, impact, and concrete next step
- include its ID in run summary `discovery_ids`

## Merge Pattern

Use this pattern for shared-target writes:

```bash
"${ORCA_MERGE_MAIN_PATH}" --source "$(git branch --show-current)"
```

Behavior enforced by helper:

1. lock-guarded integration on `ORCA_PRIMARY_REPO/main`
2. dirty-tree precheck before merge
3. hard failure if source branch contains `.beads` changes
4. merge failure cleanup (`merge --abort` / reset)

Do not push run branches to origin in normal local Orca operation.

## Run Summary JSON (Required)

Write valid JSON to `__SUMMARY_JSON_PATH__` with all fields:

- `issue_id` (string)
- `result` (`completed|blocked|no_work|failed`)
- `issue_status` (string)
- `merged` (boolean)
- `discovery_ids` (array of strings)
- `discovery_count` (integer, must equal `discovery_ids.length`)
- `loop_action` (`continue|stop`)
- `loop_action_reason` (string)
- `notes` (string)

Rules:

1. Always write valid JSON, even on failure.
2. Use `issue_id=""` when no issue was claimed.
3. Use `result=no_work` when queue is effectively empty/unusable.
4. Use `loop_action=stop` only when explicitly stopping the outer loop.
5. If you intentionally deviate from protocol, explain why in `notes`.

## End-of-Run Checklist

1. Issue claimed or explicit `no_work`.
2. Code/tests/docs completed for claimed scope, or blocker documented.
3. Queue mutations executed via `ORCA_QUEUE_WRITE_MAIN_PATH` (not via run-branch `.beads` edits).
4. Discovery follow-up issues and discovery log entries recorded when applicable.
5. `.beads/` not left dirty in run branch.
6. Summary JSON written and complete.
