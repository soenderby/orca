#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
if [[ -z "${ORCA_BIN:-}" ]]; then
  if [[ -x "${ROOT}/orca" ]]; then
    ORCA_BIN="${ROOT}/orca"
  else
    ORCA_BIN="${ROOT}/orca-go"
  fi
fi
if [[ "${ORCA_BIN}" != /* ]]; then
  ORCA_BIN="$(cd "$(dirname "${ORCA_BIN}")" && pwd)/$(basename "${ORCA_BIN}")"
fi

if [[ ! -x "${ORCA_BIN}" ]]; then
  echo "orca binary not found or not executable: ${ORCA_BIN}" >&2
  echo "build it first: go build -o orca ./cmd/orca/" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

make_repo() {
  local repo="$1"
  mkdir -p "${repo}"
  git -C "${repo}" init -q
  git -C "${repo}" config user.email "test@example.com"
  git -C "${repo}" config user.name "test"
  cat > "${repo}/README.md" <<'EOF'
# temp repo
EOF
  git -C "${repo}" add README.md
  git -C "${repo}" commit -q -m init
  git -C "${repo}" branch -M main
}

run_drain_stop_case() {
  local repo="${TMP_DIR}/drain-repo"
  local worktree="${TMP_DIR}/drain-worktree"
  local prompt_template="${TMP_DIR}/drain-prompt.md"
  local fake_agent="${TMP_DIR}/drain-agent.sh"
  local session_id="drain-go-regression-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  local expected_reason="queue-drained-after-1-consecutive-no_work-runs"

  make_repo "${repo}"
  git -C "${repo}" worktree add --detach "${worktree}" main >/dev/null

  cat > "${prompt_template}" <<'EOF'
noop
EOF

  cat > "${fake_agent}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat > "${ORCA_RUN_SUMMARY_PATH}" <<'JSON'
{
  "issue_id": "",
  "result": "no_work",
  "issue_status": "",
  "merged": false,
  "loop_action": "continue",
  "loop_action_reason": "",
  "notes": "regression test no_work run"
}
JSON
EOF
  chmod +x "${fake_agent}"

  "${ORCA_BIN}" loop-run \
    --agent-name "regression-agent" \
    --session-id "${session_id}" \
    --worktree "${worktree}" \
    --primary-repo "${repo}" \
    --prompt-template "${prompt_template}" \
    --agent-command "${fake_agent}" \
    --assignment-mode "self-select" \
    --max-runs 5 \
    --run-sleep-seconds 0 \
    --no-work-drain-mode "drain" \
    --no-work-retry-limit 0 >/dev/null

  local run_count
  run_count="$(find "${repo}/agent-logs/sessions" -type d -path "*/${session_id}/runs/*" | wc -l | tr -d '[:space:]')"
  if [[ "${run_count}" -ne 1 ]]; then
    echo "expected early drain stop before max-runs=5; observed ${run_count} runs" >&2
    exit 1
  fi

  local run_dir
  run_dir="$(find "${repo}/agent-logs/sessions" -type d -path "*/${session_id}/runs/*" | sort | tail -n 1)"
  local summary_md="${run_dir}/summary.md"
  if [[ ! -f "${summary_md}" ]]; then
    echo "missing summary markdown at ${summary_md}" >&2
    exit 1
  fi

  grep -F -- "- Loop Action: stop" "${summary_md}" >/dev/null
  grep -F -- "- Loop Action Reason: ${expected_reason}" "${summary_md}" >/dev/null

  jq -e \
    --arg session "${session_id}" \
    --arg reason "${expected_reason}" \
    'select(.session_id == $session and .run_number == 1)
     | .summary.loop_action == "stop"
     and .summary.loop_action_reason == $reason
     and (.planned_assigned_issue == null)
     and .assignment_source == "self-select"
     and .assignment_outcome == "unassigned"
     and has("mode_id")
     and has("approach_source")
     and has("approach_sha256")
     and (.mode_id == null)
     and (.approach_source == null)
     and (.approach_sha256 == null)
     and (.summary.planned_assigned_issue == null)
     and (.summary.assignment_source == "self-select")
     and (.summary.assignment_outcome == "unassigned")' \
    "${repo}/agent-logs/metrics.jsonl" >/dev/null

  local session_log
  session_log="$(find "${repo}/agent-logs/sessions" -type f -path "*/${session_id}/session.log" | sort | tail -n 1)"
  grep -F -- "configured mode attribution: mode_id=none approach_source=none approach_sha256=none" "${session_log}" >/dev/null
}

run_assigned_issue_contract_case() {
  local repo="${TMP_DIR}/assigned-repo"
  local worktree="${TMP_DIR}/assigned-worktree"
  local prompt_template="${TMP_DIR}/assigned-prompt.md"
  local fake_agent="${TMP_DIR}/assigned-agent.sh"
  local session_id="assigned-go-regression-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  local assigned_issue_id="orca-assigned"
  local actual_issue_id="orca-other"

  make_repo "${repo}"
  git -C "${repo}" worktree add --detach "${worktree}" main >/dev/null

  cat > "${prompt_template}" <<'EOF'
noop
EOF

  cat > "${fake_agent}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cat > "\${ORCA_RUN_SUMMARY_PATH}" <<'JSON'
{
  "issue_id": "${actual_issue_id}",
  "result": "completed",
  "issue_status": "closed",
  "merged": true,
  "loop_action": "continue",
  "loop_action_reason": "",
  "notes": "assigned issue mismatch regression"
}
JSON
EOF
  chmod +x "${fake_agent}"

  "${ORCA_BIN}" loop-run \
    --agent-name "regression-agent" \
    --session-id "${session_id}" \
    --worktree "${worktree}" \
    --primary-repo "${repo}" \
    --prompt-template "${prompt_template}" \
    --agent-command "${fake_agent}" \
    --assignment-mode "assigned" \
    --assigned-issue-id "${assigned_issue_id}" \
    --max-runs 1 \
    --run-sleep-seconds 0 \
    --no-work-drain-mode "drain" \
    --no-work-retry-limit 0 >/dev/null

  local run_dir
  run_dir="$(find "${repo}/agent-logs/sessions" -type d -path "*/${session_id}/runs/*" | sort | tail -n 1)"
  local summary_md="${run_dir}/summary.md"

  if [[ ! -f "${summary_md}" ]]; then
    echo "missing summary markdown at ${summary_md}" >&2
    exit 1
  fi

  grep -F -- "- Result: failed" "${summary_md}" >/dev/null
  grep -F -- "- Summary Schema Status: invalid" "${summary_md}" >/dev/null
  grep -F -- "mismatch:assigned_issue_id" "${summary_md}" >/dev/null
  grep -F -- "- Assigned Issue: ${assigned_issue_id}" "${summary_md}" >/dev/null
  grep -F -- "- Issue: ${actual_issue_id}" "${summary_md}" >/dev/null
  grep -F -- "- Assigned Issue Match: false" "${summary_md}" >/dev/null
  grep -F -- "- Planned Assigned Issue: ${assigned_issue_id}" "${summary_md}" >/dev/null
  grep -F -- "- Assignment Source: planner" "${summary_md}" >/dev/null
  grep -F -- "- Assignment Outcome: mismatch" "${summary_md}" >/dev/null

  jq -e \
    --arg session "${session_id}" \
    --arg assigned "${assigned_issue_id}" \
    --arg actual "${actual_issue_id}" \
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
    "${repo}/agent-logs/metrics.jsonl" >/dev/null
}

run_drain_stop_case
run_assigned_issue_contract_case

echo "go loop CLI parity regression passed"
