#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SESSION_PREFIX="${SESSION_PREFIX:-orca-agent}"
SESSION_LOG_ROOT="${ROOT}/agent-logs/sessions"
POLL_INTERVAL_SECONDS=2
TIMEOUT_SECONDS=""
OUTPUT_JSON=0
SESSION_FILTER_ID=""
SESSION_FILTER_PREFIX=""
ALL_HISTORY=0

EXIT_SUCCESS=0
EXIT_TIMEOUT=2
EXIT_FAILURE=3
EXIT_INVALID=4

usage() {
  cat <<'USAGE'
Usage:
  ./orca.sh wait [--timeout SECONDS] [--poll-interval SECONDS] [--session-id ID] [--session-prefix PREFIX] [--all-history] [--json]
  ./wait.sh [--timeout SECONDS] [--poll-interval SECONDS] [--session-id ID] [--session-prefix PREFIX] [--all-history] [--json]

Options:
  --timeout SECONDS        Stop waiting after SECONDS (default: no timeout)
  --poll-interval SECONDS  Poll period in seconds (default: 2)
  --session-id ID          Exact session id scope filter
  --session-prefix PREFIX  Prefix session id scope filter
  --all-history            Include historical sessions from logs in unscoped mode
  --json                   Print machine-readable final result JSON

Exit codes:
  0  success (all scoped sessions completed successfully, or no scoped sessions existed)
  2  timeout
  3  scoped session failure detected
  4  invalid usage/config
USAGE
}

invalid() {
  echo "wait: $*" >&2
  exit "${EXIT_INVALID}"
}

is_non_negative_int() {
  local value="${1:-}"
  [[ "${value}" =~ ^[0-9]+$ ]]
}

is_positive_int() {
  local value="${1:-}"
  [[ "${value}" =~ ^[1-9][0-9]*$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)
      [[ $# -ge 2 ]] || invalid "missing value for --timeout"
      TIMEOUT_SECONDS="$2"
      shift
      ;;
    --poll-interval)
      [[ $# -ge 2 ]] || invalid "missing value for --poll-interval"
      POLL_INTERVAL_SECONDS="$2"
      shift
      ;;
    --session-id)
      [[ $# -ge 2 ]] || invalid "missing value for --session-id"
      SESSION_FILTER_ID="$2"
      shift
      ;;
    --session-prefix)
      [[ $# -ge 2 ]] || invalid "missing value for --session-prefix"
      SESSION_FILTER_PREFIX="$2"
      shift
      ;;
    --all-history)
      ALL_HISTORY=1
      ;;
    --json)
      OUTPUT_JSON=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      invalid "unknown option: $1"
      ;;
  esac
  shift
done

if ! command -v jq >/dev/null 2>&1; then
  invalid "jq is required"
fi

if [[ -n "${TIMEOUT_SECONDS}" ]] && ! is_non_negative_int "${TIMEOUT_SECONDS}"; then
  invalid "--timeout must be a non-negative integer"
fi

if ! is_positive_int "${POLL_INTERVAL_SECONDS}"; then
  invalid "--poll-interval must be a positive integer"
fi

session_filter_active() {
  [[ -n "${SESSION_FILTER_ID}" || -n "${SESSION_FILTER_PREFIX}" ]]
}

session_matches_filter() {
  local session_id="${1:-}"

  if [[ -n "${SESSION_FILTER_ID}" ]]; then
    [[ "${session_id}" == "${SESSION_FILTER_ID}" ]] || return 1
  fi

  if [[ -n "${SESSION_FILTER_PREFIX}" ]]; then
    [[ -n "${session_id}" ]] || return 1
    [[ "${session_id}" == "${SESSION_FILTER_PREFIX}"* ]] || return 1
  fi

  return 0
}

session_filter_description() {
  local parts=""
  if [[ -n "${SESSION_FILTER_ID}" ]]; then
    parts="id=${SESSION_FILTER_ID}"
  fi
  if [[ -n "${SESSION_FILTER_PREFIX}" ]]; then
    if [[ -n "${parts}" ]]; then
      parts+=", "
    fi
    parts+="prefix=${SESSION_FILTER_PREFIX}"
  fi

  if [[ -z "${parts}" ]]; then
    if [[ "${ALL_HISTORY}" -eq 1 ]]; then
      echo "all sessions (history)"
    else
      echo "active sessions at invocation"
    fi
  else
    echo "${parts}"
  fi
}

resolve_session_dir_for_tmux_session() {
  local tmux_session="$1"

  if [[ ! -d "${SESSION_LOG_ROOT}" ]]; then
    return 1
  fi

  find "${SESSION_LOG_ROOT}" -mindepth 1 -maxdepth 4 -type d \
    \( -name "${tmux_session}" -o -name "${tmux_session}-*" \) \
    2>/dev/null | sort | tail -n 1
}

collect_tmux_session_names() {
  if ! command -v tmux >/dev/null 2>&1; then
    return 0
  fi

  tmux ls -F '#S' 2>/dev/null | grep "^${SESSION_PREFIX}-" || true
}

collect_active_session_ids() {
  local tmux_session=""
  local session_dir=""
  local session_id=""

  while IFS= read -r tmux_session; do
    [[ -n "${tmux_session}" ]] || continue
    session_id=""
    session_dir="$(resolve_session_dir_for_tmux_session "${tmux_session}" || true)"
    if [[ -n "${session_dir}" ]]; then
      session_id="$(basename "${session_dir}")"
    else
      session_id="${tmux_session}"
    fi

    if session_matches_filter "${session_id}"; then
      printf '%s\n' "${session_id}"
    fi
  done < <(collect_tmux_session_names)
}

collect_session_ids_from_logs() {
  local session_id=""

  if [[ ! -d "${SESSION_LOG_ROOT}" ]]; then
    return 0
  fi

  while IFS= read -r session_id; do
    [[ -n "${session_id}" ]] || continue
    if session_matches_filter "${session_id}"; then
      printf '%s\n' "${session_id}"
    fi
  done < <(
    find "${SESSION_LOG_ROOT}" -type f -name 'session.log' -print 2>/dev/null \
      | xargs -r -n1 dirname \
      | xargs -r -n1 basename \
      | sort -u
  )
}

collect_scoped_session_ids() {
  {
    collect_active_session_ids
    collect_session_ids_from_logs
  } | sed '/^[[:space:]]*$/d' | sort -u
}

latest_session_dir() {
  local session_id="$1"

  if [[ ! -d "${SESSION_LOG_ROOT}" ]]; then
    return 1
  fi

  find "${SESSION_LOG_ROOT}" -mindepth 1 -maxdepth 4 -type d -name "${session_id}" \
    2>/dev/null | sort | tail -n 1
}

latest_run_dir_for_session() {
  local session_id="$1"
  local session_dir=""

  session_dir="$(latest_session_dir "${session_id}" || true)"
  if [[ -z "${session_dir}" || ! -d "${session_dir}/runs" ]]; then
    return 1
  fi

  find "${session_dir}/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1
}

last_run_exit_code() {
  local run_log="$1"
  local line=""
  local code=""

  if [[ ! -f "${run_log}" ]]; then
    return 1
  fi

  line="$(grep -E 'agent command exited with [0-9]+' "${run_log}" 2>/dev/null | tail -n 1 || true)"
  [[ -n "${line}" ]] || return 1

  code="$(printf '%s\n' "${line}" | sed -E 's/.*agent command exited with ([0-9]+).*/\1/')"
  [[ "${code}" =~ ^[0-9]+$ ]] || return 1

  printf '%s\n' "${code}"
}

build_session_state_json() {
  local session_id="$1"
  local is_active="$2"
  local run_dir=""
  local run_id=""
  local summary_path=""
  local run_log=""
  local result=""
  local issue_status=""
  local exit_code=""

  if [[ "${is_active}" == "1" ]]; then
    jq -nc \
      --arg session_id "${session_id}" \
      '{
        session_id: $session_id,
        state: "running",
        result: null,
        issue_status: null,
        latest_run_id: null,
        summary_path: null,
        reason: "tmux_session_active"
      }'
    return 0
  fi

  run_dir="$(latest_run_dir_for_session "${session_id}" || true)"
  if [[ -z "${run_dir}" ]]; then
    jq -nc \
      --arg session_id "${session_id}" \
      '{
        session_id: $session_id,
        state: "unknown",
        result: null,
        issue_status: null,
        latest_run_id: null,
        summary_path: null,
        reason: "no_run_artifacts"
      }'
    return 0
  fi

  run_id="$(basename "${run_dir}")"
  summary_path="${run_dir}/summary.json"
  run_log="${run_dir}/run.log"

  if [[ -s "${summary_path}" ]] && jq -e . "${summary_path}" >/dev/null 2>&1; then
    result="$(jq -r 'if (.result | type) == "string" then .result else "" end' "${summary_path}")"
    issue_status="$(jq -r 'if (.issue_status | type) == "string" then .issue_status else "" end' "${summary_path}")"

    if [[ "${result}" == "completed" || "${result}" == "no_work" ]]; then
      jq -nc \
        --arg session_id "${session_id}" \
        --arg result "${result}" \
        --arg issue_status "${issue_status}" \
        --arg run_id "${run_id}" \
        --arg summary_path "${summary_path}" \
        '{
          session_id: $session_id,
          state: "succeeded",
          result: $result,
          issue_status: (if ($issue_status | length) > 0 then $issue_status else null end),
          latest_run_id: $run_id,
          summary_path: $summary_path,
          reason: "terminal_summary_success"
        }'
      return 0
    fi

    if [[ "${result}" == "blocked" || "${result}" == "failed" ]]; then
      jq -nc \
        --arg session_id "${session_id}" \
        --arg result "${result}" \
        --arg issue_status "${issue_status}" \
        --arg run_id "${run_id}" \
        --arg summary_path "${summary_path}" \
        '{
          session_id: $session_id,
          state: "failed",
          result: $result,
          issue_status: (if ($issue_status | length) > 0 then $issue_status else null end),
          latest_run_id: $run_id,
          summary_path: $summary_path,
          reason: "terminal_summary_failure"
        }'
      return 0
    fi

    jq -nc \
      --arg session_id "${session_id}" \
      --arg result "${result}" \
      --arg run_id "${run_id}" \
      --arg summary_path "${summary_path}" \
      '{
        session_id: $session_id,
        state: "unknown",
        result: (if ($result | length) > 0 then $result else null end),
        issue_status: null,
        latest_run_id: $run_id,
        summary_path: $summary_path,
        reason: "summary_result_unrecognized"
      }'
    return 0
  fi

  if exit_code="$(last_run_exit_code "${run_log}" 2>/dev/null || true)"; then
    if [[ "${exit_code}" != "0" ]]; then
      jq -nc \
        --arg session_id "${session_id}" \
        --arg run_id "${run_id}" \
        --arg reason "run_exit_nonzero:${exit_code}" \
        '{
          session_id: $session_id,
          state: "failed",
          result: "failed",
          issue_status: null,
          latest_run_id: $run_id,
          summary_path: null,
          reason: $reason
        }'
      return 0
    fi

    jq -nc \
      --arg session_id "${session_id}" \
      --arg run_id "${run_id}" \
      --arg summary_path "${summary_path}" \
      '{
        session_id: $session_id,
        state: "pending",
        result: null,
        issue_status: null,
        latest_run_id: $run_id,
        summary_path: $summary_path,
        reason: "awaiting_summary_finalize"
      }'
    return 0
  fi

  jq -nc \
    --arg session_id "${session_id}" \
    --arg run_id "${run_id}" \
    --arg summary_path "${summary_path}" \
    '{
      session_id: $session_id,
      state: "unknown",
      result: null,
      issue_status: null,
      latest_run_id: $run_id,
      summary_path: $summary_path,
      reason: "no_terminal_marker"
    }'
}

emit_final_result() {
  local status="$1"
  local reason="$2"
  local exit_code="$3"
  local elapsed_seconds="$4"
  local sessions_json="$5"
  local scope_desc
  local scope_id_json
  local scope_prefix_json
  local timeout_json
  local scoped_sessions=0
  local running_count=0
  local pending_count=0
  local succeeded_count=0
  local failed_count=0
  local unknown_count=0

  scoped_sessions="$(printf '%s\n' "${sessions_json}" | jq -r 'length')"
  running_count="$(printf '%s\n' "${sessions_json}" | jq -r '[.[] | select(.state == "running")] | length')"
  pending_count="$(printf '%s\n' "${sessions_json}" | jq -r '[.[] | select(.state == "pending")] | length')"
  succeeded_count="$(printf '%s\n' "${sessions_json}" | jq -r '[.[] | select(.state == "succeeded")] | length')"
  failed_count="$(printf '%s\n' "${sessions_json}" | jq -r '[.[] | select(.state == "failed")] | length')"
  unknown_count="$(printf '%s\n' "${sessions_json}" | jq -r '[.[] | select(.state == "unknown")] | length')"

  if [[ "${OUTPUT_JSON}" -eq 1 ]]; then
    if [[ -n "${TIMEOUT_SECONDS}" ]]; then
      timeout_json="${TIMEOUT_SECONDS}"
    else
      timeout_json="null"
    fi

    if [[ -n "${SESSION_FILTER_ID}" ]]; then
      scope_id_json="$(jq -Rn --arg value "${SESSION_FILTER_ID}" '$value')"
    else
      scope_id_json="null"
    fi

    if [[ -n "${SESSION_FILTER_PREFIX}" ]]; then
      scope_prefix_json="$(jq -Rn --arg value "${SESSION_FILTER_PREFIX}" '$value')"
    else
      scope_prefix_json="null"
    fi

    scope_desc="$(session_filter_description)"
    jq -n \
      --arg status "${status}" \
      --arg reason "${reason}" \
      --arg scope_desc "${scope_desc}" \
      --argjson scope_id "${scope_id_json}" \
      --argjson scope_prefix "${scope_prefix_json}" \
      --argjson timeout_seconds "${timeout_json}" \
      --argjson poll_interval_seconds "${POLL_INTERVAL_SECONDS}" \
      --argjson elapsed_seconds "${elapsed_seconds}" \
      --argjson scoped_sessions "${scoped_sessions}" \
      --argjson running_count "${running_count}" \
      --argjson pending_count "${pending_count}" \
      --argjson succeeded_count "${succeeded_count}" \
      --argjson failed_count "${failed_count}" \
      --argjson unknown_count "${unknown_count}" \
      --argjson sessions "${sessions_json}" \
      '{
        status: $status,
        reason: $reason,
        scope: {
          description: $scope_desc,
          session_id: $scope_id,
          session_prefix: $scope_prefix
        },
        timeout_seconds: $timeout_seconds,
        poll_interval_seconds: $poll_interval_seconds,
        elapsed_seconds: $elapsed_seconds,
        counts: {
          scoped_sessions: $scoped_sessions,
          running: $running_count,
          pending_finalization: $pending_count,
          succeeded: $succeeded_count,
          failed: $failed_count,
          unknown: $unknown_count
        },
        sessions: $sessions
      }'
  else
    printf 'wait: status=%s reason=%s scope="%s" scoped=%s running=%s pending=%s succeeded=%s failed=%s unknown=%s elapsed=%ss\n' \
      "${status}" "${reason}" "$(session_filter_description)" "${scoped_sessions}" \
      "${running_count}" "${pending_count}" "${succeeded_count}" "${failed_count}" "${unknown_count}" "${elapsed_seconds}"

    if [[ "${failed_count}" -gt 0 ]]; then
      printf '%s\n' "${sessions_json}" | jq -r '.[] | select(.state == "failed") | "- \(.session_id): \(.reason)"'
    fi
  fi

  exit "${exit_code}"
}

declare -A SEEN_SESSION_IDS=()
default_active_scope_mode=0
default_active_scope_captured=0

if ! session_filter_active && [[ "${ALL_HISTORY}" -eq 0 ]]; then
  default_active_scope_mode=1
fi

start_epoch="$(date +%s)"

while true; do
  now_epoch="$(date +%s)"
  elapsed_seconds="$((now_epoch - start_epoch))"
  if (( elapsed_seconds < 0 )); then
    elapsed_seconds=0
  fi

  mapfile -t active_ids < <(collect_active_session_ids)

  if (( default_active_scope_mode == 0 )); then
    mapfile -t scoped_now < <(collect_scoped_session_ids)
    for id in "${scoped_now[@]:-}"; do
      [[ -n "${id}" ]] || continue
      SEEN_SESSION_IDS["${id}"]=1
    done
  else
    if (( default_active_scope_captured == 0 )); then
      for id in "${active_ids[@]:-}"; do
        [[ -n "${id}" ]] || continue
        SEEN_SESSION_IDS["${id}"]=1
      done

      if (( ${#SEEN_SESSION_IDS[@]} > 0 )) || (( elapsed_seconds >= POLL_INTERVAL_SECONDS )); then
        default_active_scope_captured=1
      fi
    fi
  fi

  seen_count="${#SEEN_SESSION_IDS[@]}"
  if (( seen_count == 0 )); then
    if (( default_active_scope_mode == 1 && default_active_scope_captured == 0 )); then
      sleep "${POLL_INTERVAL_SECONDS}"
      continue
    fi
    emit_final_result "success" "no_scoped_sessions" "${EXIT_SUCCESS}" "${elapsed_seconds}" "[]"
  fi

  declare -A ACTIVE_BY_ID=()
  for id in "${active_ids[@]:-}"; do
    [[ -n "${id}" ]] || continue
    ACTIVE_BY_ID["${id}"]=1
    if (( default_active_scope_mode == 0 )); then
      SEEN_SESSION_IDS["${id}"]=1
    fi
  done

  session_jsonl=""
  for id in "${!SEEN_SESSION_IDS[@]}"; do
    is_active=0
    if [[ -n "${ACTIVE_BY_ID[${id}]+x}" ]]; then
      is_active=1
    fi
    row="$(build_session_state_json "${id}" "${is_active}")"
    if [[ -n "${session_jsonl}" ]]; then
      session_jsonl+=$'\n'
    fi
    session_jsonl+="${row}"
  done

  sessions_json="$(printf '%s\n' "${session_jsonl}" | jq -s 'sort_by(.session_id)')"
  failed_count="$(printf '%s\n' "${sessions_json}" | jq -r '[.[] | select(.state == "failed")] | length')"
  running_count="$(printf '%s\n' "${sessions_json}" | jq -r '[.[] | select(.state == "running")] | length')"
  pending_count="$(printf '%s\n' "${sessions_json}" | jq -r '[.[] | select(.state == "pending")] | length')"
  unknown_count="$(printf '%s\n' "${sessions_json}" | jq -r '[.[] | select(.state == "unknown")] | length')"

  if (( failed_count > 0 )); then
    emit_final_result "failure" "scoped_failure_detected" "${EXIT_FAILURE}" "${elapsed_seconds}" "${sessions_json}"
  fi

  if (( running_count == 0 && pending_count == 0 && unknown_count == 0 )); then
    emit_final_result "success" "all_scoped_sessions_finished" "${EXIT_SUCCESS}" "${elapsed_seconds}" "${sessions_json}"
  fi

  if [[ -n "${TIMEOUT_SECONDS}" ]] && (( elapsed_seconds >= TIMEOUT_SECONDS )); then
    emit_final_result "timeout" "timeout" "${EXIT_TIMEOUT}" "${elapsed_seconds}" "${sessions_json}"
  fi

  sleep "${POLL_INTERVAL_SECONDS}"
done
