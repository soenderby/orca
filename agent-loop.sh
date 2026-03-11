#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
WORKTREE="${WORKTREE:-}"

if [[ -z "${WORKTREE}" ]]; then
  echo "WORKTREE is required" >&2
  exit 1
fi

if ! git -C "${WORKTREE}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "WORKTREE does not look like a git worktree: ${WORKTREE}" >&2
  exit 1
fi

AGENT_NAME="${AGENT_NAME:-$(basename "${WORKTREE}")}"
AGENT_SESSION_ID="${AGENT_SESSION_ID:-${AGENT_NAME}-$(date -u +%Y%m%dT%H%M%SZ)}"
AGENT_MODEL="${AGENT_MODEL:-gpt-5.3-codex}"
AGENT_REASONING_LEVEL="${AGENT_REASONING_LEVEL:-}"
if [[ -n "${AGENT_COMMAND:-}" ]]; then
  AGENT_COMMAND="${AGENT_COMMAND}"
else
  AGENT_COMMAND="codex exec --dangerously-bypass-approvals-and-sandbox --model ${AGENT_MODEL}"
  if [[ -n "${AGENT_REASONING_LEVEL}" ]]; then
    AGENT_COMMAND="${AGENT_COMMAND} -c model_reasoning_effort=${AGENT_REASONING_LEVEL}"
  fi
fi
PROMPT_TEMPLATE="${PROMPT_TEMPLATE:-${ROOT}/AGENT_PROMPT.md}"
PRIMARY_REPO="${ORCA_PRIMARY_REPO:-${ROOT}}"
LOCK_HELPER_PATH="${ORCA_WITH_LOCK_PATH:-${ROOT}/with-lock.sh}"
QUEUE_WRITE_HELPER_PATH="${ORCA_QUEUE_WRITE_MAIN_PATH:-${ROOT}/queue-write-main.sh}"
MERGE_HELPER_PATH="${ORCA_MERGE_MAIN_PATH:-${ROOT}/merge-main.sh}"
MAX_RUNS="${MAX_RUNS:-0}"
RUN_SLEEP_SECONDS="${RUN_SLEEP_SECONDS:-2}"
ORCA_TIMING_METRICS="${ORCA_TIMING_METRICS:-1}"
ORCA_COMPACT_SUMMARY="${ORCA_COMPACT_SUMMARY:-1}"
ORCA_LOCK_SCOPE="${ORCA_LOCK_SCOPE:-merge}"
ORCA_LOCK_TIMEOUT_SECONDS="${ORCA_LOCK_TIMEOUT_SECONDS:-120}"
ORCA_NO_WORK_DRAIN_MODE="${ORCA_NO_WORK_DRAIN_MODE:-drain}"
ORCA_NO_WORK_RETRY_LIMIT="${ORCA_NO_WORK_RETRY_LIMIT:-1}"
AGENT_LOG_ROOT="${ROOT}/agent-logs"
SESSION_LOG_ROOT="${AGENT_LOG_ROOT}/sessions"

if ! [[ "${MAX_RUNS}" =~ ^[0-9]+$ ]]; then
  echo "MAX_RUNS must be a non-negative integer (0 means unbounded mode): ${MAX_RUNS}" >&2
  exit 1
fi

if ! [[ "${RUN_SLEEP_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "RUN_SLEEP_SECONDS must be a non-negative integer: ${RUN_SLEEP_SECONDS}" >&2
  exit 1
fi

if ! [[ "${ORCA_TIMING_METRICS}" =~ ^[01]$ ]]; then
  echo "ORCA_TIMING_METRICS must be 0 or 1: ${ORCA_TIMING_METRICS}" >&2
  exit 1
fi

if ! [[ "${ORCA_COMPACT_SUMMARY}" =~ ^[01]$ ]]; then
  echo "ORCA_COMPACT_SUMMARY must be 0 or 1: ${ORCA_COMPACT_SUMMARY}" >&2
  exit 1
fi

if ! [[ "${ORCA_LOCK_SCOPE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ORCA_LOCK_SCOPE must contain only letters, digits, dot, underscore, or dash: ${ORCA_LOCK_SCOPE}" >&2
  exit 1
fi

if ! [[ "${ORCA_LOCK_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ORCA_LOCK_TIMEOUT_SECONDS must be a positive integer: ${ORCA_LOCK_TIMEOUT_SECONDS}" >&2
  exit 1
fi

if [[ "${ORCA_NO_WORK_DRAIN_MODE}" != "drain" && "${ORCA_NO_WORK_DRAIN_MODE}" != "watch" ]]; then
  echo "ORCA_NO_WORK_DRAIN_MODE must be 'drain' or 'watch': ${ORCA_NO_WORK_DRAIN_MODE}" >&2
  exit 1
fi

if ! [[ "${ORCA_NO_WORK_RETRY_LIMIT}" =~ ^[0-9]+$ ]]; then
  echo "ORCA_NO_WORK_RETRY_LIMIT must be a non-negative integer: ${ORCA_NO_WORK_RETRY_LIMIT}" >&2
  exit 1
fi

if [[ -n "${AGENT_REASONING_LEVEL}" && ! "${AGENT_REASONING_LEVEL}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "AGENT_REASONING_LEVEL must contain only letters, digits, dot, underscore, or dash: ${AGENT_REASONING_LEVEL}" >&2
  exit 1
fi

if [[ ! -f "${PROMPT_TEMPLATE}" ]]; then
  echo "PROMPT_TEMPLATE not found: ${PROMPT_TEMPLATE}" >&2
  exit 1
fi

if ! git -C "${PRIMARY_REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ORCA_PRIMARY_REPO does not look like a git worktree: ${PRIMARY_REPO}" >&2
  exit 1
fi

if [[ ! -x "${LOCK_HELPER_PATH}" ]]; then
  echo "ORCA_WITH_LOCK_PATH must be executable: ${LOCK_HELPER_PATH}" >&2
  exit 1
fi

if [[ ! -x "${QUEUE_WRITE_HELPER_PATH}" ]]; then
  echo "ORCA_QUEUE_WRITE_MAIN_PATH must be executable: ${QUEUE_WRITE_HELPER_PATH}" >&2
  exit 1
fi

if [[ ! -x "${MERGE_HELPER_PATH}" ]]; then
  echo "ORCA_MERGE_MAIN_PATH must be executable: ${MERGE_HELPER_PATH}" >&2
  exit 1
fi

HARNESS_VERSION="$(git -C "${ROOT}" describe --always --dirty 2>/dev/null || true)"
if [[ -z "${HARNESS_VERSION}" ]]; then
  HARNESS_VERSION="$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || true)"
fi
if [[ -z "${HARNESS_VERSION}" ]]; then
  HARNESS_VERSION="unknown"
fi

SESSION_DATE_PATH="$(date -u +%Y/%m/%d)"
if [[ "${AGENT_SESSION_ID}" =~ ([0-9]{8})T[0-9]{6}Z ]]; then
  session_stamp="${BASH_REMATCH[1]}"
  SESSION_DATE_PATH="${session_stamp:0:4}/${session_stamp:4:2}/${session_stamp:6:2}"
fi
SESSION_DIR="${SESSION_LOG_ROOT}/${SESSION_DATE_PATH}/${AGENT_SESSION_ID}"
SESSION_RUNS_DIR="${SESSION_DIR}/runs"
SESSION_LOGFILE="${SESSION_DIR}/session.log"
METRICS_FILE="${AGENT_LOG_ROOT}/metrics.jsonl"
DISCOVERY_LOG_DIR="${AGENT_LOG_ROOT}/discoveries"
DISCOVERY_LOG_FILE="${DISCOVERY_LOG_DIR}/${AGENT_NAME}.md"
mkdir -p "${SESSION_RUNS_DIR}" "${DISCOVERY_LOG_DIR}"
: > "${SESSION_LOGFILE}"
touch "${METRICS_FILE}"
touch "${DISCOVERY_LOG_FILE}"

runs_completed=0
cleanup_in_progress=0
consecutive_no_work_runs=0

LOGFILE=""
SUMMARY_FILE=""
SUMMARY_JSON_FILE=""
LAST_MESSAGE_FILE=""
RUN_AGENT_COMMAND=""
RUN_NUMBER=0
RUN_TIMESTAMP=""
RUN_BASE=""
RUN_DIR=""
RUN_EXIT_CODE=0
RUN_DURATION_SECONDS=0
RUN_RESULT=""
RUN_REASON=""
RUN_SUMMARY_PARSE_STATUS="missing"
RUN_SUMMARY_LOOP_ACTION="continue"
RUN_SUMMARY_LOOP_ACTION_REASON=""
RUN_SUMMARY_ISSUE_ID=""
RUN_SUMMARY_RESULT=""
RUN_SUMMARY_ISSUE_STATUS=""
RUN_SUMMARY_MERGED=""
RUN_SUMMARY_DISCOVERY_COUNT=""
RUN_SUMMARY_DISCOVERY_IDS=""
RUN_SUMMARY_SCHEMA_STATUS="not_checked"
RUN_SUMMARY_SCHEMA_REASON_CODES=""
RUN_TOKENS_USED=""
RUN_TOKENS_PARSE_STATUS="missing"
RUN_BRANCH_NAME=""

log() {
  local line
  line="$(printf '[%s] [%s] %s\n' "$(date -Iseconds)" "${AGENT_NAME}" "$*")"
  printf '%s\n' "${line}" >> "${SESSION_LOGFILE}"
  if [[ -n "${LOGFILE}" ]]; then
    printf '%s\n' "${line}" | tee -a "${LOGFILE}" >&2
  else
    printf '%s\n' "${line}" >&2
  fi
}

now_epoch() {
  date +%s
}

start_run_artifacts() {
  RUN_NUMBER=$((runs_completed + 1))
  RUN_TIMESTAMP="$(date -u +%Y%m%dT%H%M%S%NZ)"
  RUN_DIR="${SESSION_RUNS_DIR}/$(printf '%04d-%s' "${RUN_NUMBER}" "${RUN_TIMESTAMP}")"
  RUN_BASE="${RUN_DIR}"
  LOGFILE="${RUN_DIR}/run.log"
  SUMMARY_FILE="${RUN_DIR}/summary.md"
  SUMMARY_JSON_FILE="${RUN_DIR}/summary.json"
  LAST_MESSAGE_FILE="${RUN_DIR}/last-message.md"

  mkdir -p "${RUN_DIR}"
  : > "${LOGFILE}"

  RUN_AGENT_COMMAND=""
  RUN_EXIT_CODE=0
  RUN_DURATION_SECONDS=0
  RUN_RESULT=""
  RUN_REASON=""
  RUN_SUMMARY_PARSE_STATUS="missing"
  RUN_SUMMARY_LOOP_ACTION="continue"
  RUN_SUMMARY_LOOP_ACTION_REASON=""
  RUN_SUMMARY_ISSUE_ID=""
  RUN_SUMMARY_RESULT=""
  RUN_SUMMARY_ISSUE_STATUS=""
  RUN_SUMMARY_MERGED=""
  RUN_SUMMARY_DISCOVERY_COUNT=""
  RUN_SUMMARY_DISCOVERY_IDS=""
  RUN_SUMMARY_SCHEMA_STATUS="not_checked"
  RUN_SUMMARY_SCHEMA_REASON_CODES=""
  RUN_TOKENS_USED=""
  RUN_TOKENS_PARSE_STATUS="missing"
  RUN_BRANCH_NAME=""

  log "starting run ${RUN_NUMBER}"
  log "session id: ${AGENT_SESSION_ID}"
  log "worktree: ${WORKTREE}"
  log "run log: ${LOGFILE}"
  log "summary json path: ${SUMMARY_JSON_FILE}"
  log "discovery log path: ${DISCOVERY_LOG_FILE}"
  log "primary repo path: ${PRIMARY_REPO}"
  log "lock helper path: ${LOCK_HELPER_PATH}"
  log "queue write helper path: ${QUEUE_WRITE_HELPER_PATH}"
  log "merge helper path: ${MERGE_HELPER_PATH}"
  log "harness version: ${HARNESS_VERSION}"
}

select_run_base_ref() {
  local current_branch

  if [[ -n "${ORCA_BASE_REF:-}" ]]; then
    printf '%s\n' "${ORCA_BASE_REF}"
    return 0
  fi

  warn_if_main_refs_diverge

  if git show-ref --verify --quiet refs/heads/main; then
    printf '%s\n' "main"
    return 0
  fi

  if git show-ref --verify --quiet refs/remotes/origin/main; then
    printf '%s\n' "origin/main"
    return 0
  fi

  current_branch="$(git branch --show-current 2>/dev/null || true)"
  if [[ -n "${current_branch}" ]]; then
    printf '%s\n' "${current_branch}"
    return 0
  fi

  return 1
}

warn_if_main_refs_diverge() {
  local counts
  local ahead
  local behind

  if ! git show-ref --verify --quiet refs/heads/main; then
    return 0
  fi

  if ! git show-ref --verify --quiet refs/remotes/origin/main; then
    return 0
  fi

  counts="$(git rev-list --left-right --count main...origin/main 2>/dev/null || true)"
  if [[ -z "${counts}" ]]; then
    return 0
  fi

  read -r ahead behind <<< "${counts}"
  if [[ "${ahead}" != "0" || "${behind}" != "0" ]]; then
    log "warning: local main and origin/main differ (local ahead ${ahead}, behind ${behind}); defaulting to main"
  fi
}

validate_explicit_base_ref() {
  if [[ -z "${ORCA_BASE_REF:-}" ]]; then
    return 0
  fi

  if git rev-parse --verify --quiet "${ORCA_BASE_REF}^{commit}" >/dev/null 2>&1; then
    return 0
  fi

  log "fatal: ORCA_BASE_REF does not resolve to a commit: ${ORCA_BASE_REF}"
  log "fatal: set ORCA_BASE_REF to a valid ref (for example: main, origin/main, or a commit SHA)"
  return 1
}

prepare_run_branch() {
  local base_ref
  local worktree_status
  local checkout_error
  local line

  if git remote get-url origin >/dev/null 2>&1; then
    if ! git fetch --quiet origin main; then
      log "warning: failed to fetch origin/main; using local refs"
    fi
  fi

  if ! base_ref="$(select_run_base_ref)"; then
    log "fatal: unable to determine base ref (checked ORCA_BASE_REF, main, origin/main, current branch)"
    return 1
  fi

  worktree_status="$(git status --short 2>/dev/null || true)"
  if [[ -n "${worktree_status}" ]]; then
    log "fatal: worktree has uncommitted changes and cannot switch to ${base_ref} for run branch setup"
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      log "worktree status: ${line}"
    done <<< "${worktree_status}"
    return 1
  fi

  # Keep run branches as a flat ref under swarm/ to avoid colliding with
  # persistent agent refs like refs/heads/swarm/agent-1.
  RUN_BRANCH_NAME="swarm/${AGENT_NAME}-run-${AGENT_SESSION_ID}-${RUN_NUMBER}-${RUN_TIMESTAMP}"
  if ! [[ "${RUN_BRANCH_NAME}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    log "fatal: generated invalid run branch name: ${RUN_BRANCH_NAME}"
    return 1
  fi

  if git show-ref --verify --quiet "refs/heads/${RUN_BRANCH_NAME}"; then
    log "fatal: run branch already exists locally: ${RUN_BRANCH_NAME}"
    return 1
  fi

  if git show-ref --verify --quiet "refs/remotes/origin/${RUN_BRANCH_NAME}"; then
    log "fatal: run branch already exists on origin: ${RUN_BRANCH_NAME}"
    return 1
  fi

  if ! checkout_error="$(git checkout -b "${RUN_BRANCH_NAME}" "${base_ref}" 2>&1)"; then
    log "fatal: failed to create run branch ${RUN_BRANCH_NAME} from ${base_ref}"
    if [[ -n "${checkout_error}" ]]; then
      while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        log "git checkout: ${line}"
      done <<< "${checkout_error}"
    fi
    return 1
  fi

  log "prepared run branch: ${RUN_BRANCH_NAME} (base: ${base_ref})"
}

build_agent_command_for_run() {
  RUN_AGENT_COMMAND="${AGENT_COMMAND}"

  if [[ "${ORCA_COMPACT_SUMMARY}" -ne 1 ]]; then
    return
  fi

  if [[ "${RUN_AGENT_COMMAND}" != *"codex exec"* ]]; then
    return
  fi

  if [[ "${RUN_AGENT_COMMAND}" == *"--output-last-message"* ]]; then
    return
  fi

  RUN_AGENT_COMMAND="${RUN_AGENT_COMMAND} --output-last-message $(printf '%q' "${LAST_MESSAGE_FILE}")"
}

write_prompt_file() {
  local prompt_file="$1"
  local prompt_text

  prompt_text="$(cat "${PROMPT_TEMPLATE}")"
  prompt_text="${prompt_text//__AGENT_NAME__/${AGENT_NAME}}"
  prompt_text="${prompt_text//__ISSUE_ID__/agent-selected}"
  prompt_text="${prompt_text//__WORKTREE__/${WORKTREE}}"
  prompt_text="${prompt_text//__RUN_SUMMARY_PATH__/${SUMMARY_JSON_FILE}}"
  prompt_text="${prompt_text//__RUN_SUMMARY_JSON__/${SUMMARY_JSON_FILE}}"
  prompt_text="${prompt_text//__SUMMARY_JSON_PATH__/${SUMMARY_JSON_FILE}}"
  prompt_text="${prompt_text//__DISCOVERY_LOG_PATH__/${DISCOVERY_LOG_FILE}}"
  prompt_text="${prompt_text//__AGENT_DISCOVERY_LOG_PATH__/${DISCOVERY_LOG_FILE}}"
  prompt_text="${prompt_text//__PRIMARY_REPO__/${PRIMARY_REPO}}"
  prompt_text="${prompt_text//__ORCA_PRIMARY_REPO__/${PRIMARY_REPO}}"
  prompt_text="${prompt_text//__WITH_LOCK_PATH__/${LOCK_HELPER_PATH}}"
  prompt_text="${prompt_text//__ORCA_WITH_LOCK_PATH__/${LOCK_HELPER_PATH}}"
  prompt_text="${prompt_text//__QUEUE_WRITE_MAIN_PATH__/${QUEUE_WRITE_HELPER_PATH}}"
  prompt_text="${prompt_text//__ORCA_QUEUE_WRITE_MAIN_PATH__/${QUEUE_WRITE_HELPER_PATH}}"
  prompt_text="${prompt_text//__MERGE_MAIN_PATH__/${MERGE_HELPER_PATH}}"
  prompt_text="${prompt_text//__ORCA_MERGE_MAIN_PATH__/${MERGE_HELPER_PATH}}"

  printf '%s\n' "${prompt_text}" > "${prompt_file}"
}

extract_tokens_used_from_run_log() {
  local raw

  RUN_TOKENS_USED=""
  RUN_TOKENS_PARSE_STATUS="missing"

  if [[ ! -f "${LOGFILE}" ]]; then
    return
  fi

  raw="$(awk '/^tokens used$/ {getline; print; exit}' "${LOGFILE}" | tr -d '\r')"
  if [[ -z "${raw}" ]]; then
    return
  fi

  raw="$(printf '%s' "${raw}" | tr -d ' ,')"
  if [[ "${raw}" =~ ^[0-9]+$ ]]; then
    RUN_TOKENS_USED="${raw}"
    RUN_TOKENS_PARSE_STATUS="ok"
    return
  fi

  RUN_TOKENS_PARSE_STATUS="parse_error"
}

parse_summary_json_if_present() {
  RUN_SUMMARY_PARSE_STATUS="missing"
  RUN_SUMMARY_LOOP_ACTION="continue"
  RUN_SUMMARY_LOOP_ACTION_REASON=""
  RUN_SUMMARY_ISSUE_ID=""
  RUN_SUMMARY_RESULT=""
  RUN_SUMMARY_ISSUE_STATUS=""
  RUN_SUMMARY_MERGED=""
  RUN_SUMMARY_DISCOVERY_COUNT=""
  RUN_SUMMARY_DISCOVERY_IDS=""
  RUN_SUMMARY_SCHEMA_STATUS="not_checked"
  RUN_SUMMARY_SCHEMA_REASON_CODES=""

  if [[ ! -s "${SUMMARY_JSON_FILE}" ]]; then
    return
  fi

  if ! command -v jq >/dev/null 2>&1; then
    RUN_SUMMARY_PARSE_STATUS="jq_unavailable"
    log "summary present but jq unavailable: ${SUMMARY_JSON_FILE}"
    return
  fi

  if ! jq -e . "${SUMMARY_JSON_FILE}" >/dev/null 2>&1; then
    RUN_SUMMARY_PARSE_STATUS="invalid_json"
    log "summary present but invalid json: ${SUMMARY_JSON_FILE}"
    return
  fi

  RUN_SUMMARY_PARSE_STATUS="parsed"
  RUN_SUMMARY_LOOP_ACTION="$(jq -r '
    if (.loop_action | type == "string") and ((.loop_action == "continue") or (.loop_action == "stop"))
    then .loop_action
    else "continue"
    end
  ' "${SUMMARY_JSON_FILE}")"
  RUN_SUMMARY_LOOP_ACTION_REASON="$(jq -r '(.loop_action_reason // "") | tostring' "${SUMMARY_JSON_FILE}")"
  RUN_SUMMARY_ISSUE_ID="$(jq -r '(.issue_id // "") | tostring' "${SUMMARY_JSON_FILE}")"
  RUN_SUMMARY_RESULT="$(jq -r '(.result // "") | tostring' "${SUMMARY_JSON_FILE}")"
  RUN_SUMMARY_ISSUE_STATUS="$(jq -r '(.issue_status // "") | tostring' "${SUMMARY_JSON_FILE}")"
  RUN_SUMMARY_MERGED="$(jq -r 'if has("merged") then (.merged | tostring) else "" end' "${SUMMARY_JSON_FILE}")"
  RUN_SUMMARY_DISCOVERY_COUNT="$(jq -r 'if has("discovery_count") then (.discovery_count | tostring) else "" end' "${SUMMARY_JSON_FILE}")"
  RUN_SUMMARY_DISCOVERY_IDS="$(jq -r '
    if (.discovery_ids | type) == "array" then
      (.discovery_ids | map(tostring) | join(","))
    else
      ""
    end
  ' "${SUMMARY_JSON_FILE}")"

  validate_summary_json_schema
  if [[ "${RUN_SUMMARY_SCHEMA_STATUS}" == "invalid" ]]; then
    # Fail-closed: invalid summary schema cannot request loop stop.
    RUN_SUMMARY_LOOP_ACTION="continue"
    RUN_SUMMARY_LOOP_ACTION_REASON=""
  fi

  log "parsed summary json: ${SUMMARY_JSON_FILE}"
}

validate_summary_json_schema() {
  local schema_codes=""

  RUN_SUMMARY_SCHEMA_STATUS="not_checked"
  RUN_SUMMARY_SCHEMA_REASON_CODES=""

  if [[ "${RUN_SUMMARY_PARSE_STATUS}" != "parsed" ]]; then
    return
  fi

  schema_codes="$(jq -r '
    def errs:
      []
      + (if has("issue_id") then [] else ["missing:issue_id"] end)
      + (if (has("issue_id") and (.issue_id | type == "string")) then [] else (if has("issue_id") then ["type:issue_id"] else [] end) end)
      + (if has("result") then [] else ["missing:result"] end)
      + (if (has("result") and (.result | type == "string")) then [] else (if has("result") then ["type:result"] else [] end) end)
      + (if (has("result") and (.result | type == "string") and ((.result == "completed") or (.result == "blocked") or (.result == "no_work") or (.result == "failed"))) then [] else (if has("result") then ["enum:result"] else [] end) end)
      + (if has("issue_status") then [] else ["missing:issue_status"] end)
      + (if (has("issue_status") and (.issue_status | type == "string")) then [] else (if has("issue_status") then ["type:issue_status"] else [] end) end)
      + (if has("merged") then [] else ["missing:merged"] end)
      + (if (has("merged") and (.merged | type == "boolean")) then [] else (if has("merged") then ["type:merged"] else [] end) end)
      + (if has("discovery_ids") then [] else ["missing:discovery_ids"] end)
      + (if (has("discovery_ids") and (.discovery_ids | type == "array")) then [] else (if has("discovery_ids") then ["type:discovery_ids"] else [] end) end)
      + (if (has("discovery_ids") and (.discovery_ids | type == "array") and ([.discovery_ids[] | (type == "string")] | all)) then [] else (if has("discovery_ids") then ["type:discovery_ids_items"] else [] end) end)
      + (if has("discovery_count") then [] else ["missing:discovery_count"] end)
      + (if (has("discovery_count") and (.discovery_count | type == "number") and ((.discovery_count | floor) == .discovery_count)) then [] else (if has("discovery_count") then ["type:discovery_count"] else [] end) end)
      + (if ((has("discovery_count") and has("discovery_ids") and (.discovery_count | type == "number") and ((.discovery_count | floor) == .discovery_count) and (.discovery_ids | type == "array")) | not) then [] else (if (.discovery_count == (.discovery_ids | length)) then [] else ["mismatch:discovery_count"] end) end)
      + (if has("loop_action") then [] else ["missing:loop_action"] end)
      + (if (has("loop_action") and (.loop_action | type == "string")) then [] else (if has("loop_action") then ["type:loop_action"] else [] end) end)
      + (if (has("loop_action") and (.loop_action | type == "string") and ((.loop_action == "continue") or (.loop_action == "stop"))) then [] else (if has("loop_action") then ["enum:loop_action"] else [] end) end)
      + (if has("loop_action_reason") then [] else ["missing:loop_action_reason"] end)
      + (if (has("loop_action_reason") and (.loop_action_reason | type == "string")) then [] else (if has("loop_action_reason") then ["type:loop_action_reason"] else [] end) end)
      + (if has("notes") then [] else ["missing:notes"] end)
      + (if (has("notes") and (.notes | type == "string")) then [] else (if has("notes") then ["type:notes"] else [] end) end)
      ;
    (errs | unique) as $e
    | if ($e | length) == 0 then "" else ($e | join(",")) end
  ' "${SUMMARY_JSON_FILE}")"

  if [[ -n "${schema_codes}" ]]; then
    RUN_SUMMARY_SCHEMA_STATUS="invalid"
    RUN_SUMMARY_SCHEMA_REASON_CODES="${schema_codes}"
    log "summary schema invalid: ${schema_codes}"
    return
  fi

  RUN_SUMMARY_SCHEMA_STATUS="valid"
}

determine_run_result() {
  local first_schema_error=""

  RUN_RESULT="failed"
  RUN_REASON="agent-exit-${RUN_EXIT_CODE}"

  if [[ "${RUN_SUMMARY_PARSE_STATUS}" == "missing" ]]; then
    RUN_REASON="summary-missing"
    return
  fi

  if [[ "${RUN_SUMMARY_PARSE_STATUS}" == "jq_unavailable" ]]; then
    RUN_REASON="summary-jq-unavailable"
    return
  fi

  if [[ "${RUN_SUMMARY_PARSE_STATUS}" == "invalid_json" ]]; then
    RUN_REASON="summary-invalid-json"
    return
  fi

  if [[ "${RUN_SUMMARY_SCHEMA_STATUS}" == "invalid" ]]; then
    first_schema_error="${RUN_SUMMARY_SCHEMA_REASON_CODES%%,*}"
    if [[ -n "${first_schema_error}" ]]; then
      RUN_REASON="summary-schema-invalid:${first_schema_error}"
    else
      RUN_REASON="summary-schema-invalid"
    fi
    return
  fi

  if [[ -n "${RUN_SUMMARY_RESULT}" ]]; then
    RUN_RESULT="${RUN_SUMMARY_RESULT}"
  elif [[ "${RUN_EXIT_CODE}" -eq 0 ]]; then
    RUN_RESULT="failed"
    RUN_REASON="summary-result-missing"
    return
  fi

  if [[ "${RUN_SUMMARY_PARSE_STATUS}" == "parsed" && "${RUN_SUMMARY_LOOP_ACTION}" == "stop" ]]; then
    if [[ -n "${RUN_SUMMARY_LOOP_ACTION_REASON}" ]]; then
      RUN_REASON="${RUN_SUMMARY_LOOP_ACTION_REASON}"
    else
      RUN_REASON="agent-requested-stop"
    fi
  fi
}

write_run_summary_markdown() {
  local final_message_note="(not captured)"

  if [[ -f "${LAST_MESSAGE_FILE}" ]]; then
    final_message_note="${LAST_MESSAGE_FILE}"
  fi

  {
    echo "# Orca Run Summary"
    echo
    echo "- Timestamp: $(date -Iseconds)"
    echo "- Agent: ${AGENT_NAME}"
    echo "- Session: ${AGENT_SESSION_ID}"
    echo "- Run: ${RUN_NUMBER}"
    echo "- Exit Code: ${RUN_EXIT_CODE}"
    echo "- Duration Seconds: ${RUN_DURATION_SECONDS}"
    echo "- Result: ${RUN_RESULT}"
    echo "- Reason: ${RUN_REASON}"
    echo "- Summary JSON: ${SUMMARY_JSON_FILE}"
    echo "- Summary Parse Status: ${RUN_SUMMARY_PARSE_STATUS}"
    echo "- Summary Schema Status: ${RUN_SUMMARY_SCHEMA_STATUS}"
    if [[ -n "${RUN_SUMMARY_SCHEMA_REASON_CODES}" ]]; then
      echo "- Summary Schema Reason Codes: ${RUN_SUMMARY_SCHEMA_REASON_CODES}"
    fi
    echo "- Loop Action: ${RUN_SUMMARY_LOOP_ACTION}"
    if [[ -n "${RUN_SUMMARY_LOOP_ACTION_REASON}" ]]; then
      echo "- Loop Action Reason: ${RUN_SUMMARY_LOOP_ACTION_REASON}"
    fi
    if [[ -n "${RUN_SUMMARY_ISSUE_ID}" ]]; then
      echo "- Issue: ${RUN_SUMMARY_ISSUE_ID}"
    fi
    if [[ -n "${RUN_SUMMARY_RESULT}" ]]; then
      echo "- Summary Result: ${RUN_SUMMARY_RESULT}"
    fi
    if [[ -n "${RUN_SUMMARY_ISSUE_STATUS}" ]]; then
      echo "- Summary Issue Status: ${RUN_SUMMARY_ISSUE_STATUS}"
    fi
    if [[ -n "${RUN_SUMMARY_MERGED}" ]]; then
      echo "- Summary Merged: ${RUN_SUMMARY_MERGED}"
    fi
    if [[ -n "${RUN_SUMMARY_DISCOVERY_COUNT}" ]]; then
      echo "- Summary Discovery Count: ${RUN_SUMMARY_DISCOVERY_COUNT}"
    fi
    if [[ -n "${RUN_SUMMARY_DISCOVERY_IDS}" ]]; then
      echo "- Summary Discovery IDs: ${RUN_SUMMARY_DISCOVERY_IDS}"
    fi
    echo "- Tokens Used: ${RUN_TOKENS_USED:-n/a} (${RUN_TOKENS_PARSE_STATUS})"
    echo
    echo "## Artifacts"
    echo "- Run Log: ${LOGFILE}"
    echo "- Agent Final Message: ${final_message_note}"
  } > "${SUMMARY_FILE}"

  if [[ -f "${LAST_MESSAGE_FILE}" ]]; then
    {
      echo
      echo "## Agent Final Message (first 120 lines)"
      echo
      sed -n '1,120p' "${LAST_MESSAGE_FILE}"
    } >> "${SUMMARY_FILE}"
  fi

  log "wrote run summary: ${SUMMARY_FILE}"
}

append_metrics_jsonl() {
  local tokens_json

  if [[ -n "${RUN_TOKENS_USED}" ]]; then
    tokens_json="${RUN_TOKENS_USED}"
  else
    tokens_json="null"
  fi

  jq -nc \
    --arg ts "$(date -Iseconds)" \
    --arg agent "${AGENT_NAME}" \
    --arg session "${AGENT_SESSION_ID}" \
    --arg result "${RUN_RESULT}" \
    --arg reason "${RUN_REASON}" \
    --arg issue "${RUN_SUMMARY_ISSUE_ID}" \
    --arg loop_action "${RUN_SUMMARY_LOOP_ACTION}" \
    --arg loop_action_reason "${RUN_SUMMARY_LOOP_ACTION_REASON}" \
    --arg summary_result "${RUN_SUMMARY_RESULT}" \
    --arg summary_issue_status "${RUN_SUMMARY_ISSUE_STATUS}" \
    --arg summary_merged "${RUN_SUMMARY_MERGED}" \
    --arg summary_discovery_count "${RUN_SUMMARY_DISCOVERY_COUNT}" \
    --arg summary_discovery_ids_csv "${RUN_SUMMARY_DISCOVERY_IDS}" \
    --arg summary_parse_status "${RUN_SUMMARY_PARSE_STATUS}" \
    --arg summary_schema_status "${RUN_SUMMARY_SCHEMA_STATUS}" \
    --arg summary_schema_reason_codes_csv "${RUN_SUMMARY_SCHEMA_REASON_CODES}" \
    --arg tokens_parse_status "${RUN_TOKENS_PARSE_STATUS}" \
    --arg harness_version "${HARNESS_VERSION}" \
    --arg run_log "${LOGFILE}" \
    --arg summary_json "${SUMMARY_JSON_FILE}" \
    --arg summary_markdown "${SUMMARY_FILE}" \
    --arg last_message "${LAST_MESSAGE_FILE}" \
    --arg discovery_log "${DISCOVERY_LOG_FILE}" \
    --argjson run_number "${RUN_NUMBER}" \
    --argjson exit_code "${RUN_EXIT_CODE}" \
    --argjson duration_seconds "${RUN_DURATION_SECONDS}" \
    --argjson tokens_used "${tokens_json}" \
    '{
      timestamp: $ts,
      agent_name: $agent,
      session_id: $session,
      harness_version: $harness_version,
      run_number: $run_number,
      exit_code: $exit_code,
      result: $result,
      reason: $reason,
      issue_id: (if ($issue | length) > 0 then $issue else null end),
      durations_seconds: {
        iteration_total: $duration_seconds
      },
      tokens_used: $tokens_used,
      tokens_parse_status: $tokens_parse_status,
      summary_parse_status: $summary_parse_status,
      summary_schema_status: $summary_schema_status,
      summary_schema_reason_codes: (
        if ($summary_schema_reason_codes_csv | length) == 0 then []
        else ($summary_schema_reason_codes_csv | split(","))
        end
      ),
      summary: {
        result: (if ($summary_result | length) > 0 then $summary_result else null end),
        issue_status: (if ($summary_issue_status | length) > 0 then $summary_issue_status else null end),
        merged: (
          if ($summary_merged | length) == 0 then null
          elif $summary_merged == "true" then true
          elif $summary_merged == "false" then false
          else $summary_merged
          end
        ),
        discovery_count: (
          if ($summary_discovery_count | length) == 0 then null
          else (try ($summary_discovery_count | tonumber) catch $summary_discovery_count)
          end
        ),
        discovery_ids: (
          if ($summary_discovery_ids_csv | length) == 0 then []
          else ($summary_discovery_ids_csv | split(","))
          end
        ),
        loop_action: $loop_action,
        loop_action_reason: (if ($loop_action_reason | length) > 0 then $loop_action_reason else null end)
      },
      files: {
        run_log: $run_log,
        summary_json: $summary_json,
        summary_markdown: $summary_markdown,
        agent_last_message: $last_message,
        discovery_log: $discovery_log
      }
    }' >> "${METRICS_FILE}"
}

finalize_run_observability() {
  extract_tokens_used_from_run_log

  if [[ "${ORCA_TIMING_METRICS}" -eq 1 ]]; then
    if append_metrics_jsonl; then
      log "appended metrics row"
    else
      log "failed to append metrics row"
    fi
  fi

  if [[ "${ORCA_COMPACT_SUMMARY}" -eq 1 ]]; then
    write_run_summary_markdown
  fi
}

restore_worktree_queue_artifacts() {
  local queue_status
  local line

  queue_status="$(git status --short -- .beads/ 2>/dev/null || true)"
  if [[ -z "${queue_status}" ]]; then
    return 0
  fi

  log "warning: run left local .beads changes in worktree; restoring to keep run branch clean"
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    log "queue dirty: ${line}"
  done <<< "${queue_status}"

  if ! git restore --staged --worktree .beads/ >/dev/null 2>&1; then
    log "fatal: failed to restore local .beads changes"
    return 1
  fi

  queue_status="$(git status --short -- .beads/ 2>/dev/null || true)"
  if [[ -n "${queue_status}" ]]; then
    log "fatal: .beads remained dirty after restore"
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      log "queue dirty after restore: ${line}"
    done <<< "${queue_status}"
    return 1
  fi

  log "restored local .beads changes"
}

cleanup_on_signal() {
  local signal="$1"

  if [[ "${cleanup_in_progress}" -eq 1 ]]; then
    return
  fi

  cleanup_in_progress=1
  log "received ${signal}; shutting down"
}

cleanup_on_exit() {
  cleanup_on_signal "exit"
}

trap cleanup_on_exit EXIT
trap 'cleanup_on_signal INT; exit 130' INT
trap 'cleanup_on_signal TERM; exit 143' TERM

cd "${WORKTREE}"

log "starting loop in ${WORKTREE}"
log "session id: ${AGENT_SESSION_ID}"
log "agent discovery log: ${DISCOVERY_LOG_FILE}"
log "agent primary repo: ${PRIMARY_REPO}"
log "agent lock helper: ${LOCK_HELPER_PATH}"
log "agent queue write helper: ${QUEUE_WRITE_HELPER_PATH}"
log "agent merge helper: ${MERGE_HELPER_PATH}"
log "no_work drain mode: ${ORCA_NO_WORK_DRAIN_MODE} (retry limit: ${ORCA_NO_WORK_RETRY_LIMIT})"
log "harness version: ${HARNESS_VERSION}"
if ! validate_explicit_base_ref; then
  exit 1
fi
if [[ "${MAX_RUNS}" -eq 0 ]]; then
  log "run mode: unbounded"
else
  log "run mode: stop after ${MAX_RUNS} runs"
fi

while true; do
  local_stop_requested=0

  if [[ "${MAX_RUNS}" -gt 0 && "${runs_completed}" -ge "${MAX_RUNS}" ]]; then
    log "max runs reached (${runs_completed}/${MAX_RUNS}); exiting loop"
    break
  fi

  start_run_artifacts
  if ! prepare_run_branch; then
    RUN_EXIT_CODE=1
    RUN_DURATION_SECONDS=0
    RUN_SUMMARY_PARSE_STATUS="missing"
    RUN_SUMMARY_RESULT="failed"
    RUN_SUMMARY_LOOP_ACTION="stop"
    RUN_SUMMARY_LOOP_ACTION_REASON="run-branch-setup-failed"
    RUN_REASON="run-branch-setup-failed"
    RUN_RESULT="failed"
    finalize_run_observability
    runs_completed=$((runs_completed + 1))
    log "completed run ${runs_completed} with branch setup failure"
    break
  fi

  prompt_file="$(mktemp)"
  write_prompt_file "${prompt_file}"

  build_agent_command_for_run
  log "running agent command"

  run_started_epoch="$(now_epoch)"

  if ORCA_RUN_SUMMARY_PATH="${SUMMARY_JSON_FILE}" \
    ORCA_RUN_LOG_PATH="${LOGFILE}" \
    ORCA_RUN_NUMBER="${RUN_NUMBER}" \
    ORCA_SESSION_ID="${AGENT_SESSION_ID}" \
    ORCA_AGENT_NAME="${AGENT_NAME}" \
    ORCA_DISCOVERY_LOG_PATH="${DISCOVERY_LOG_FILE}" \
    ORCA_AGENT_DISCOVERY_LOG_PATH="${DISCOVERY_LOG_FILE}" \
    ORCA_PRIMARY_REPO="${PRIMARY_REPO}" \
    ORCA_WITH_LOCK_PATH="${LOCK_HELPER_PATH}" \
    ORCA_QUEUE_WRITE_MAIN_PATH="${QUEUE_WRITE_HELPER_PATH}" \
    ORCA_MERGE_MAIN_PATH="${MERGE_HELPER_PATH}" \
    ORCA_LOCK_SCOPE="${ORCA_LOCK_SCOPE}" \
    ORCA_LOCK_TIMEOUT_SECONDS="${ORCA_LOCK_TIMEOUT_SECONDS}" \
    bash -lc "${RUN_AGENT_COMMAND}" < "${prompt_file}" >> "${LOGFILE}" 2>&1; then
    RUN_EXIT_CODE=0
  else
    RUN_EXIT_CODE=$?
  fi
  RUN_DURATION_SECONDS=$(( $(now_epoch) - run_started_epoch ))

  rm -f "${prompt_file}"

  log "agent command exited with ${RUN_EXIT_CODE} after ${RUN_DURATION_SECONDS}s"

  parse_summary_json_if_present
  determine_run_result

  if ! restore_worktree_queue_artifacts; then
    local_stop_requested=1
    RUN_RESULT="failed"
    RUN_REASON="worktree-queue-restore-failed"
    log "stopping loop after failure to restore local .beads changes"
  fi

  if [[ "${RUN_RESULT}" == "no_work" ]]; then
    consecutive_no_work_runs=$((consecutive_no_work_runs + 1))
    if [[ "${ORCA_NO_WORK_DRAIN_MODE}" == "drain" ]]; then
      if (( consecutive_no_work_runs > ORCA_NO_WORK_RETRY_LIMIT )); then
        local_stop_requested=1
        RUN_SUMMARY_LOOP_ACTION="stop"
        RUN_SUMMARY_LOOP_ACTION_REASON="queue-drained-after-${consecutive_no_work_runs}-consecutive-no_work-runs"
        RUN_REASON="${RUN_SUMMARY_LOOP_ACTION_REASON}"
        log "queue drain stop: ${RUN_SUMMARY_LOOP_ACTION_REASON}"
      else
        log "no_work observed (${consecutive_no_work_runs} consecutive); retrying to avoid transient false stop"
      fi
    else
      log "no_work observed (${consecutive_no_work_runs} consecutive); watch mode keeps loop running"
    fi
  else
    if [[ "${consecutive_no_work_runs}" -gt 0 ]]; then
      log "resetting consecutive no_work counter after result=${RUN_RESULT}"
    fi
    consecutive_no_work_runs=0
  fi

  # Drain-stop decisions must be applied before observability is finalized so
  # summary/metrics capture the final loop action and reason for this run.
  finalize_run_observability

  runs_completed=$((runs_completed + 1))
  if [[ "${MAX_RUNS}" -eq 0 ]]; then
    log "completed run ${runs_completed}"
  else
    log "completed run ${runs_completed}/${MAX_RUNS}"
  fi

  if [[ "${RUN_SUMMARY_PARSE_STATUS}" == "parsed" && "${RUN_SUMMARY_LOOP_ACTION}" == "stop" ]]; then
    local_stop_requested=1
    if [[ -n "${RUN_SUMMARY_LOOP_ACTION_REASON}" ]]; then
      log "agent requested stop: ${RUN_SUMMARY_LOOP_ACTION_REASON}"
    else
      log "agent requested stop"
    fi
  fi

  LOGFILE=""

  if [[ "${local_stop_requested}" -eq 1 ]]; then
    break
  fi

  if [[ "${RUN_SLEEP_SECONDS}" -gt 0 ]]; then
    sleep "${RUN_SLEEP_SECONDS}"
  fi
done

log "loop stopped after ${runs_completed} run(s)"
