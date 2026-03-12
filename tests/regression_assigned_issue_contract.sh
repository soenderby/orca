#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
WORKTREE_DIR="${TMP_DIR}/worktree"
FAKE_AGENT="${TMP_DIR}/fake-agent.sh"
SESSION_ID="assigned-issue-regression-$(date -u +%Y%m%dT%H%M%SZ)-$$"
ASSIGNED_ISSUE_ID="orca-assigned"
ACTUAL_ISSUE_ID="orca-other"

cleanup() {
  git -C "${ROOT}" worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

cat > "${FAKE_AGENT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cat > "\${ORCA_RUN_SUMMARY_PATH}" <<'JSON'
{
  "issue_id": "${ACTUAL_ISSUE_ID}",
  "result": "completed",
  "issue_status": "closed",
  "merged": true,
  "loop_action": "continue",
  "loop_action_reason": "",
  "notes": "assigned issue mismatch regression"
}
JSON
EOF
chmod +x "${FAKE_AGENT}"

git -C "${ROOT}" worktree add --detach "${WORKTREE_DIR}" HEAD >/dev/null

WORKTREE="${WORKTREE_DIR}" \
AGENT_NAME="regression-agent" \
AGENT_SESSION_ID="${SESSION_ID}" \
AGENT_COMMAND="${FAKE_AGENT}" \
MAX_RUNS=1 \
RUN_SLEEP_SECONDS=0 \
ORCA_ASSIGNMENT_MODE="assigned" \
ORCA_ASSIGNED_ISSUE_ID="${ASSIGNED_ISSUE_ID}" \
ORCA_NO_WORK_DRAIN_MODE="drain" \
ORCA_NO_WORK_RETRY_LIMIT=0 \
ORCA_PRIMARY_REPO="${ROOT}" \
ORCA_WITH_LOCK_PATH="${ROOT}/with-lock.sh" \
ORCA_QUEUE_WRITE_MAIN_PATH="${ROOT}/queue-write-main.sh" \
ORCA_MERGE_MAIN_PATH="${ROOT}/merge-main.sh" \
bash "${ROOT}/agent-loop.sh" >/dev/null 2>&1

RUN_DIR="$(find "${ROOT}/agent-logs/sessions" -type d -path "*/${SESSION_ID}/runs/*" | sort | tail -n 1)"
SUMMARY_MD="${RUN_DIR}/summary.md"

if [[ ! -f "${SUMMARY_MD}" ]]; then
  echo "missing summary markdown at ${SUMMARY_MD}" >&2
  exit 1
fi

grep -F -- "- Result: failed" "${SUMMARY_MD}" >/dev/null
grep -F -- "- Summary Schema Status: invalid" "${SUMMARY_MD}" >/dev/null
grep -F -- "mismatch:assigned_issue_id" "${SUMMARY_MD}" >/dev/null
grep -F -- "- Assigned Issue: ${ASSIGNED_ISSUE_ID}" "${SUMMARY_MD}" >/dev/null
grep -F -- "- Issue: ${ACTUAL_ISSUE_ID}" "${SUMMARY_MD}" >/dev/null
grep -F -- "- Assigned Issue Match: false" "${SUMMARY_MD}" >/dev/null
grep -F -- "- Planned Assigned Issue: ${ASSIGNED_ISSUE_ID}" "${SUMMARY_MD}" >/dev/null
grep -F -- "- Assignment Source: planner" "${SUMMARY_MD}" >/dev/null
grep -F -- "- Assignment Outcome: mismatch" "${SUMMARY_MD}" >/dev/null

jq -e \
  --arg session "${SESSION_ID}" \
  --arg assigned "${ASSIGNED_ISSUE_ID}" \
  --arg actual "${ACTUAL_ISSUE_ID}" \
  'select(.session_id == $session and .run_number == 1)
   | .result == "failed"
   and .assigned_issue_id == $assigned
   and .planned_assigned_issue == $assigned
   and .assignment_source == "planner"
   and .assignment_outcome == "mismatch"
   and .issue_id == $actual
   and .summary_schema_status == "invalid"
   and (.summary_schema_reason_codes | index("mismatch:assigned_issue_id") != null)
   and .summary.assignment_match == false
   and .summary.planned_assigned_issue == $assigned
   and .summary.assignment_source == "planner"
   and .summary.assignment_outcome == "mismatch"' \
  "${ROOT}/agent-logs/metrics.jsonl" >/dev/null

echo "assigned issue contract regression passed"
