#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
WORKTREE_DIR="${TMP_DIR}/worktree"
FAKE_AGENT="${TMP_DIR}/fake-agent.sh"
SESSION_ID="drain-stop-regression-$(date -u +%Y%m%dT%H%M%SZ)-$$"
EXPECTED_REASON="queue-drained-after-1-consecutive-no_work-runs"

cleanup() {
  git -C "${ROOT}" worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

cat > "${FAKE_AGENT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat > "${ORCA_RUN_SUMMARY_PATH}" <<'JSON'
{
  "issue_id": "",
  "result": "no_work",
  "issue_status": "",
  "merged": false,
  "discovery_ids": [],
  "discovery_count": 0,
  "loop_action": "continue",
  "loop_action_reason": "",
  "notes": "regression test no_work run"
}
JSON
EOF
chmod +x "${FAKE_AGENT}"

git -C "${ROOT}" worktree add --detach "${WORKTREE_DIR}" HEAD >/dev/null

WORKTREE="${WORKTREE_DIR}" \
AGENT_NAME="regression-agent" \
AGENT_SESSION_ID="${SESSION_ID}" \
AGENT_COMMAND="${FAKE_AGENT}" \
MAX_RUNS=5 \
RUN_SLEEP_SECONDS=0 \
ORCA_NO_WORK_DRAIN_MODE="drain" \
ORCA_NO_WORK_RETRY_LIMIT=0 \
ORCA_PRIMARY_REPO="${ROOT}" \
ORCA_WITH_LOCK_PATH="${ROOT}/with-lock.sh" \
ORCA_QUEUE_WRITE_MAIN_PATH="${ROOT}/queue-write-main.sh" \
ORCA_MERGE_MAIN_PATH="${ROOT}/merge-main.sh" \
bash "${ROOT}/agent-loop.sh" >/dev/null 2>&1

RUN_DIR="$(find "${ROOT}/agent-logs/sessions" -type d -path "*/${SESSION_ID}/runs/*" | sort | tail -n 1)"
SUMMARY_MD="${RUN_DIR}/summary.md"
RUN_COUNT="$(find "${ROOT}/agent-logs/sessions" -type d -path "*/${SESSION_ID}/runs/*" | wc -l | tr -d '[:space:]')"

if [[ ! -f "${SUMMARY_MD}" ]]; then
  echo "missing summary markdown at ${SUMMARY_MD}" >&2
  exit 1
fi

if [[ "${RUN_COUNT}" -ne 1 ]]; then
  echo "expected early drain stop before MAX_RUNS=5; observed ${RUN_COUNT} runs" >&2
  exit 1
fi

grep -F -- "- Loop Action: stop" "${SUMMARY_MD}" >/dev/null
grep -F -- "- Loop Action Reason: ${EXPECTED_REASON}" "${SUMMARY_MD}" >/dev/null

jq -e \
  --arg session "${SESSION_ID}" \
  --arg reason "${EXPECTED_REASON}" \
  'select(.session_id == $session and .run_number == 1)
   | .summary.loop_action == "stop"
   and .summary.loop_action_reason == $reason' \
  "${ROOT}/agent-logs/metrics.jsonl" >/dev/null

echo "drain-stop observability regression passed"
