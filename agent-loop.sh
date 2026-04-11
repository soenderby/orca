#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCA_BIN_CANDIDATE="${ORCA_BIN:-${ORCA_GO_BIN:-}}"
if [[ -z "${ORCA_BIN_CANDIDATE}" ]]; then
  if [[ -x "${SCRIPT_DIR}/orca" ]]; then
    ORCA_BIN_CANDIDATE="${SCRIPT_DIR}/orca"
  else
    ORCA_BIN_CANDIDATE="${SCRIPT_DIR}/orca-go"
  fi
fi

if [[ ! -x "${ORCA_BIN_CANDIDATE}" ]]; then
  echo "[agent-loop] error: orca binary not found: ${ORCA_BIN_CANDIDATE}" >&2
  echo "[agent-loop] build it first: go build -o ${SCRIPT_DIR}/orca ./cmd/orca" >&2
  exit 1
fi

WORKTREE="${WORKTREE:-${PWD}}"
AGENT_NAME="${AGENT_NAME:-agent-1}"
AGENT_SESSION_ID="${AGENT_SESSION_ID:-${AGENT_NAME}-$(date -u +%Y%m%dT%H%M%SZ)}"
ORCA_PRIMARY_REPO="${ORCA_PRIMARY_REPO:-$(git -C "${WORKTREE}" rev-parse --show-toplevel 2>/dev/null || pwd)}"
PROMPT_TEMPLATE="${PROMPT_TEMPLATE:-}"
if [[ -z "${PROMPT_TEMPLATE}" ]]; then
  if [[ -f "${ORCA_PRIMARY_REPO}/ORCA_PROMPT.md" ]]; then
    PROMPT_TEMPLATE="${ORCA_PRIMARY_REPO}/ORCA_PROMPT.md"
  else
    PROMPT_TEMPLATE="${SCRIPT_DIR}/ORCA_PROMPT.md"
  fi
fi

AGENT_MODEL="${AGENT_MODEL:-gpt-5.3-codex}"
AGENT_COMMAND="${AGENT_COMMAND:-codex exec --dangerously-bypass-approvals-and-sandbox --model ${AGENT_MODEL}}"
ORCA_ASSIGNMENT_MODE="${ORCA_ASSIGNMENT_MODE:-assigned}"
ORCA_ASSIGNED_ISSUE_ID="${ORCA_ASSIGNED_ISSUE_ID:-}"
MAX_RUNS="${MAX_RUNS:-0}"
RUN_SLEEP_SECONDS="${RUN_SLEEP_SECONDS:-2}"
ORCA_NO_WORK_DRAIN_MODE="${ORCA_NO_WORK_DRAIN_MODE:-drain}"
ORCA_NO_WORK_RETRY_LIMIT="${ORCA_NO_WORK_RETRY_LIMIT:-1}"
ORCA_MODE_ID="${ORCA_MODE_ID:-}"
ORCA_WORK_APPROACH_FILE="${ORCA_WORK_APPROACH_FILE:-}"
ORCA_HOME="${ORCA_HOME:-${SCRIPT_DIR}}"
ORCA_WITH_LOCK_PATH="${ORCA_WITH_LOCK_PATH:-${ORCA_HOME}/with-lock.sh}"
ORCA_QUEUE_READ_MAIN_PATH="${ORCA_QUEUE_READ_MAIN_PATH:-${ORCA_HOME}/queue-read-main.sh}"
ORCA_QUEUE_WRITE_MAIN_PATH="${ORCA_QUEUE_WRITE_MAIN_PATH:-${ORCA_HOME}/queue-write-main.sh}"
ORCA_MERGE_MAIN_PATH="${ORCA_MERGE_MAIN_PATH:-${ORCA_HOME}/merge-main.sh}"
ORCA_BR_GUARD_PATH="${ORCA_BR_GUARD_PATH:-${ORCA_HOME}/br-guard.sh}"
ORCA_LOCK_SCOPE="${ORCA_LOCK_SCOPE:-merge}"
ORCA_LOCK_TIMEOUT_SECONDS="${ORCA_LOCK_TIMEOUT_SECONDS:-120}"

exec "${ORCA_BIN_CANDIDATE}" loop-run \
  --agent-name "${AGENT_NAME}" \
  --session-id "${AGENT_SESSION_ID}" \
  --worktree "${WORKTREE}" \
  --primary-repo "${ORCA_PRIMARY_REPO}" \
  --prompt-template "${PROMPT_TEMPLATE}" \
  --agent-command "${AGENT_COMMAND}" \
  --assignment-mode "${ORCA_ASSIGNMENT_MODE}" \
  --assigned-issue-id "${ORCA_ASSIGNED_ISSUE_ID}" \
  --max-runs "${MAX_RUNS}" \
  --run-sleep-seconds "${RUN_SLEEP_SECONDS}" \
  --no-work-drain-mode "${ORCA_NO_WORK_DRAIN_MODE}" \
  --no-work-retry-limit "${ORCA_NO_WORK_RETRY_LIMIT}" \
  --mode-id "${ORCA_MODE_ID}" \
  --approach-file "${ORCA_WORK_APPROACH_FILE}" \
  --orca-home "${ORCA_HOME}" \
  --with-lock-path "${ORCA_WITH_LOCK_PATH}" \
  --queue-read-main-path "${ORCA_QUEUE_READ_MAIN_PATH}" \
  --queue-write-main-path "${ORCA_QUEUE_WRITE_MAIN_PATH}" \
  --merge-main-path "${ORCA_MERGE_MAIN_PATH}" \
  --br-guard-path "${ORCA_BR_GUARD_PATH}" \
  --lock-scope "${ORCA_LOCK_SCOPE}" \
  --lock-timeout-seconds "${ORCA_LOCK_TIMEOUT_SECONDS}"
