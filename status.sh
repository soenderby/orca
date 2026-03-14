#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SESSION_PREFIX="${SESSION_PREFIX:-orca-agent}"
METRICS_FILE="${ROOT}/agent-logs/metrics.jsonl"
SESSION_LOG_ROOT="${ROOT}/agent-logs/sessions"
ORCA_STATUS_CACHE_DIR="${ORCA_STATUS_CACHE_DIR:-${ROOT}/agent-logs/cache}"
ORCA_STATUS_METRICS_CACHE_MAX_FILES="${ORCA_STATUS_METRICS_CACHE_MAX_FILES:-5}"
ORCA_STATUS_STALE_SECONDS="${ORCA_STATUS_STALE_SECONDS:-900}"
ORCA_STATUS_CLAIMED_LIMIT="${ORCA_STATUS_CLAIMED_LIMIT:-20}"
ORCA_STATUS_CLOSED_LIMIT="${ORCA_STATUS_CLOSED_LIMIT:-10}"
ORCA_STATUS_RECENT_METRIC_LIMIT="${ORCA_STATUS_RECENT_METRIC_LIMIT:-10}"
FIELD_SEP=$'\x1f'
STATUS_MODE="quick"
SESSION_FILTER_ID=""
SESSION_FILTER_PREFIX=""
OUTPUT_JSON=0
FOLLOW_MODE=0
FOLLOW_POLL_INTERVAL_SECONDS=2
FOLLOW_MAX_EVENTS=0

usage() {
  cat <<USAGE
Usage:
  ./orca.sh status [--quick|--full] [--json] [--session-id ID] [--session-prefix PREFIX]
  ./orca.sh status --follow [--poll-interval SECONDS] [--max-events N] [--session-id ID] [--session-prefix PREFIX]
  ./status.sh [--quick|--full] [--json] [--session-id ID] [--session-prefix PREFIX]
  ./status.sh --follow [--poll-interval SECONDS] [--max-events N] [--session-id ID] [--session-prefix PREFIX]

Modes:
  --quick  Fast active-operations summary (default)
  --full   Full diagnostics (legacy status output)
  --json   Emit machine-readable status payload (schema_version included)
  --follow Emit JSONL lifecycle transition events for scoped sessions

Session scope:
  --session-id ID        Only include data for an exact session id
  --session-prefix TEXT  Only include data where session id starts with TEXT

Follow options:
  --poll-interval N      Follow poll interval in seconds (default: 2)
  --max-events N         Stop follow mode after N emitted events (default: 0=unbounded)
USAGE
}

is_non_negative_int() {
  local value="${1:-}"
  [[ "${value}" =~ ^[0-9]+$ ]]
}

is_positive_int() {
  local value="${1:-}"
  [[ "${value}" =~ ^[1-9][0-9]*$ ]]
}

invalid() {
  echo "status: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)
      STATUS_MODE="quick"
      ;;
    --full)
      STATUS_MODE="full"
      ;;
    --json)
      OUTPUT_JSON=1
      ;;
    --follow)
      FOLLOW_MODE=1
      ;;
    --poll-interval)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --poll-interval" >&2
        usage >&2
        exit 1
      fi
      FOLLOW_POLL_INTERVAL_SECONDS="$2"
      shift
      ;;
    --max-events)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --max-events" >&2
        usage >&2
        exit 1
      fi
      FOLLOW_MAX_EVENTS="$2"
      shift
      ;;
    --session-id)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --session-id" >&2
        usage >&2
        exit 1
      fi
      SESSION_FILTER_ID="$2"
      shift
      ;;
    --session-prefix)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --session-prefix" >&2
        usage >&2
        exit 1
      fi
      SESSION_FILTER_PREFIX="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown status option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if ! is_positive_int "${FOLLOW_POLL_INTERVAL_SECONDS}"; then
  invalid "--poll-interval must be a positive integer"
fi
if ! is_non_negative_int "${FOLLOW_MAX_EVENTS}"; then
  invalid "--max-events must be a non-negative integer"
fi
if [[ "${FOLLOW_MODE}" -eq 1 ]] && [[ "${OUTPUT_JSON}" -eq 1 ]]; then
  invalid "--json is not supported with --follow (follow mode always emits JSON lines)"
fi
if [[ "${FOLLOW_MODE}" -eq 1 ]] && ! command -v jq >/dev/null 2>&1; then
  invalid "--follow requires jq"
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
    echo "all sessions"
  else
    echo "${parts}"
  fi
}

filter_metrics_json_stream() {
  local input_file="$1"

  if ! session_filter_active; then
    cat "${input_file}"
    return 0
  fi

  jq -c \
    --arg sid "${SESSION_FILTER_ID}" \
    --arg sp "${SESSION_FILTER_PREFIX}" \
    '
      select(
        (($sid | length) == 0 or (.session_id // "") == $sid)
        and
        (($sp | length) == 0 or ((.session_id // "") | startswith($sp)))
      )
    ' "${input_file}" 2>/dev/null || true
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

extract_agent_name_from_session_log() {
  local session_log="$1"

  if [[ ! -f "${session_log}" ]]; then
    return 1
  fi

  awk -F'[][]' '/^\[[^]]+\] \[[^]]+\] / {agent=$4} END {if (agent != "") print agent}' "${session_log}"
}

build_active_session_rows() {
  local tmux_sessions_input="${1:-}"
  local rows=""
  local running_count=0
  local total_count=0
  local tmux_session=""
  local session_dir=""
  local session_id=""
  local session_log=""
  local agent_name=""
  local latest_run_dir=""
  local run_name=""
  local run_log=""
  local state=""
  local updated_at=""
  local run_age="unknown"
  local row=""

  while IFS= read -r tmux_session; do
    [[ -z "${tmux_session}" ]] && continue

    session_dir="$(resolve_session_dir_for_tmux_session "${tmux_session}" || true)"
    session_id=""
    if [[ -n "${session_dir}" ]]; then
      session_id="$(basename "${session_dir}")"
    fi

    if ! session_matches_filter "${session_id}"; then
      continue
    fi

    total_count=$((total_count + 1))
    session_log="${session_dir}/session.log"
    agent_name="$(extract_agent_name_from_session_log "${session_log}" 2>/dev/null || true)"
    if [[ -z "${agent_name}" ]]; then
      agent_name="${tmux_session#${SESSION_PREFIX}-}"
      [[ -n "${agent_name}" ]] || agent_name="${tmux_session}"
    fi

    latest_run_dir=""
    if [[ -d "${session_dir}/runs" ]]; then
      latest_run_dir="$(find "${session_dir}/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)"
    fi

    state="idle"
    run_name="none"
    run_age="unknown"
    if [[ -n "${latest_run_dir}" ]]; then
      run_name="$(basename "${latest_run_dir}")"
      run_log="${latest_run_dir}/run.log"
      if [[ -f "${run_log}" ]]; then
        updated_at="$(stat -c '%y' "${run_log}" 2>/dev/null || true)"
        if [[ -n "${updated_at}" ]]; then
          run_age="$(format_age_from_timestamp "${updated_at}")"
        fi
        if grep -q "running agent command" "${run_log}" 2>/dev/null && ! grep -q "agent command exited with" "${run_log}" 2>/dev/null; then
          state="running"
          running_count=$((running_count + 1))
        fi
      fi
    fi

    row="${tmux_session}${FIELD_SEP}${session_id}${FIELD_SEP}${agent_name}${FIELD_SEP}${state}${FIELD_SEP}${run_age}${FIELD_SEP}${run_name}"
    if [[ -n "${rows}" ]]; then
      rows+=$'\n'
    fi
    rows+="${row}"
  done <<< "${tmux_sessions_input}"

  printf '%s\n' "${running_count}${FIELD_SEP}${total_count}"
  printf '%s\n' "${rows}"
}

count_non_empty_lines() {
  local text="${1:-}"
  if [[ -z "${text}" ]]; then
    echo "0"
    return 0
  fi

  printf '%s\n' "${text}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]'
}

timestamp_to_epoch() {
  local timestamp="$1"

  if [[ -z "${timestamp}" ]]; then
    return 1
  fi

  date -d "${timestamp}" +%s 2>/dev/null
}

format_age_from_timestamp() {
  local timestamp="$1"
  local now_epoch
  local ts_epoch
  local age_seconds

  now_epoch="$(date +%s)"
  if ! ts_epoch="$(timestamp_to_epoch "${timestamp}")"; then
    echo "unknown"
    return 0
  fi

  age_seconds="$((now_epoch - ts_epoch))"
  if (( age_seconds < 0 )); then
    age_seconds=0
  fi

  if (( age_seconds < 60 )); then
    echo "${age_seconds}s ago"
    return 0
  fi

  if (( age_seconds < 3600 )); then
    echo "$((age_seconds / 60))m ago"
    return 0
  fi

  if (( age_seconds < 86400 )); then
    echo "$((age_seconds / 3600))h ago"
    return 0
  fi

  echo "$((age_seconds / 86400))d ago"
}

format_seconds_short() {
  local value="$1"
  local total
  local minutes
  local seconds

  if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
    echo "${value}"
    return 0
  fi

  total="${value}"
  if (( total < 60 )); then
    echo "${total}s"
    return 0
  fi

  if (( total < 3600 )); then
    minutes="$((total / 60))"
    seconds="$((total % 60))"
    printf '%dm%02ds\n' "${minutes}" "${seconds}"
    return 0
  fi

  printf '%dh%02dm\n' "$((total / 3600))" "$(((total % 3600) / 60))"
}

declare -a ALERTS=()
add_alert() {
  local message="$1"
  local existing

  for existing in "${ALERTS[@]:-}"; do
    if [[ "${existing}" == "${message}" ]]; then
      return 0
    fi
  done

  ALERTS+=("${message}")
}

metrics_fingerprint() {
  local file_path="$1"
  local stat_output=""

  if [[ ! -f "${file_path}" ]]; then
    return 1
  fi

  stat_output="$(stat -c '%s:%Y' "${file_path}" 2>/dev/null || true)"
  if [[ -z "${stat_output}" ]]; then
    return 1
  fi

  printf '%s\n' "${stat_output}:v2"
}

load_full_metrics_summary_from_cache() {
  local -n out_summary_line_ref="$1"
  local -n out_agent_rows_ref="$2"
  local metrics_fp=""
  local cache_key=""
  local cache_file=""
  local tmp_cache_file=""
  local combined_json=""
  local -a _status_cache_files=()

  out_summary_line_ref=""
  out_agent_rows_ref=""

  if [[ ! -f "${METRICS_FILE}" || ! -s "${METRICS_FILE}" || ! -r "${METRICS_FILE}" ]]; then
    return 1
  fi

  if ! metrics_fp="$(metrics_fingerprint "${METRICS_FILE}")"; then
    return 1
  fi

  cache_key="$(printf '%s\n' "${metrics_fp}" | tr -c '[:alnum:]' '_')"
  cache_file="${ORCA_STATUS_CACHE_DIR}/status-metrics-full-${cache_key}.json"

  if [[ ! -f "${cache_file}" ]]; then
    mkdir -p "${ORCA_STATUS_CACHE_DIR}"
    tmp_cache_file="$(mktemp "${ORCA_STATUS_CACHE_DIR}/status-metrics-full-${cache_key}.tmp.XXXXXX")"
    if ! jq -s -c '
      def row_to_text:
        [
          (.agent_name // "unknown-agent"),
          (.session_id // "unknown-session"),
          (.timestamp // "unknown-time"),
          (.result // "unknown"),
          (.issue_id // "none"),
          ((.durations_seconds.iteration_total // 0) | tostring),
          (if .tokens_used == null then "n/a" else (.tokens_used | tostring) end),
          ((.summary.loop_action // .loop_action // "n/a") | tostring),
          ((.summary.loop_action_reason // .loop_action_reason // "") | tostring)
        ] | join("\u001f");
      if length == 0 then
        {
          summary_line: "",
          agent_activity_rows: []
        }
      else
        {
          summary_line: (
            [
              (length | tostring),
              (map(select(.result == "completed")) | length | tostring),
              (map(select(.result == "blocked")) | length | tostring),
              (map(select(.result == "failed")) | length | tostring),
              (map(select(.result == "no_work")) | length | tostring),
              (.[-1].timestamp // ""),
              (.[-1].agent_name // ""),
              (.[-1].result // ""),
              (.[-1].issue_id // ""),
              ((.[-1].durations_seconds.iteration_total // 0) | tostring),
              (if .[-1].tokens_used == null then "n/a" else (.[-1].tokens_used | tostring) end)
            ] | join("\u001f")
          ),
          agent_activity_rows: (
            sort_by(.timestamp // "")
            | reverse
            | unique_by([.agent_name, .session_id])
            | sort_by(.agent_name, (.session_id // ""))
            | map(row_to_text)
          )
        }
      end
    ' "${METRICS_FILE}" > "${tmp_cache_file}" 2>/dev/null; then
      rm -f "${tmp_cache_file}"
      return 1
    fi

    mv "${tmp_cache_file}" "${cache_file}"

    mapfile -t _status_cache_files < <(ls -1t "${ORCA_STATUS_CACHE_DIR}"/status-metrics-full-*.json 2>/dev/null || true)
    if (( ${#_status_cache_files[@]} > ORCA_STATUS_METRICS_CACHE_MAX_FILES )); then
      printf '%s\n' "${_status_cache_files[@]:ORCA_STATUS_METRICS_CACHE_MAX_FILES}" | xargs -r rm -f
    fi
  fi

  combined_json="$(cat "${cache_file}" 2>/dev/null || true)"
  if [[ -z "${combined_json}" ]]; then
    return 1
  fi

  out_summary_line_ref="$(printf '%s\n' "${combined_json}" | jq -r '.summary_line // ""' 2>/dev/null || true)"
  out_agent_rows_ref="$(printf '%s\n' "${combined_json}" | jq -r '.agent_activity_rows[]?' 2>/dev/null || true)"

  if [[ -z "${out_summary_line_ref}" ]]; then
    return 1
  fi

  return 0
}

load_filtered_metrics_summary() {
  local -n out_summary_line_ref="$1"
  local -n out_agent_rows_ref="$2"
  local filtered_rows=""

  out_summary_line_ref=""
  out_agent_rows_ref=""

  if [[ ! -f "${METRICS_FILE}" || ! -s "${METRICS_FILE}" || ! -r "${METRICS_FILE}" ]]; then
    return 1
  fi

  filtered_rows="$(filter_metrics_json_stream "${METRICS_FILE}")"
  if [[ -z "${filtered_rows}" ]]; then
    return 1
  fi

  out_summary_line_ref="$(
    printf '%s\n' "${filtered_rows}" | jq -s -r '
      if length == 0 then
        ""
      else
        [
          (length | tostring),
          (map(select(.result == "completed")) | length | tostring),
          (map(select(.result == "blocked")) | length | tostring),
          (map(select(.result == "failed")) | length | tostring),
          (map(select(.result == "no_work")) | length | tostring),
          (.[-1].timestamp // ""),
          (.[-1].agent_name // ""),
          (.[-1].result // ""),
          (.[-1].issue_id // ""),
          ((.[-1].durations_seconds.iteration_total // 0) | tostring),
          (if .[-1].tokens_used == null then "n/a" else (.[-1].tokens_used | tostring) end)
        ] | join("\u001f")
      end
    ' 2>/dev/null || true
  )"

  out_agent_rows_ref="$(
    printf '%s\n' "${filtered_rows}" | jq -s -r '
      def row_to_text:
        [
          (.agent_name // "unknown-agent"),
          (.session_id // "unknown-session"),
          (.timestamp // "unknown-time"),
          (.result // "unknown"),
          (.issue_id // "none"),
          ((.durations_seconds.iteration_total // 0) | tostring),
          (if .tokens_used == null then "n/a" else (.tokens_used | tostring) end),
          ((.summary.loop_action // .loop_action // "n/a") | tostring),
          ((.summary.loop_action_reason // .loop_action_reason // "") | tostring)
        ] | join("\u001f");
      sort_by(.timestamp // "")
      | reverse
      | unique_by([.agent_name, .session_id])
      | sort_by(.agent_name, (.session_id // ""))
      | map(row_to_text)
      | .[]?
    ' 2>/dev/null || true
  )"

  [[ -n "${out_summary_line_ref}" ]]
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

collect_session_ids_from_logs() {
  if [[ ! -d "${SESSION_LOG_ROOT}" ]]; then
    return 0
  fi

  find "${SESSION_LOG_ROOT}" -type f -name 'session.log' -print 2>/dev/null \
    | xargs -r -n1 dirname \
    | xargs -r -n1 basename \
    | sort -u
}

collect_follow_snapshot_json() {
  local tmux_sessions=""
  local tmux_session=""
  local session_dir=""
  local session_id=""
  local run_dir=""
  local run_id=""
  local run_log=""
  local summary_path=""
  local run_state=""
  local run_result=""
  local issue_status=""
  local run_exit_code=""
  local first=1
  local sessions_json="["
  local all_session_ids=""

  declare -A active_sessions=()
  declare -A tmux_session_by_session_id=()

  if command -v tmux >/dev/null 2>&1; then
    tmux_sessions="$(tmux ls -F '#S' 2>/dev/null | grep "^${SESSION_PREFIX}-" || true)"
    while IFS= read -r tmux_session; do
      [[ -n "${tmux_session}" ]] || continue
      session_dir="$(resolve_session_dir_for_tmux_session "${tmux_session}" || true)"
      if [[ -n "${session_dir}" ]]; then
        session_id="$(basename "${session_dir}")"
      else
        session_id="${tmux_session}"
      fi
      if ! session_matches_filter "${session_id}"; then
        continue
      fi
      active_sessions["${session_id}"]=1
      tmux_session_by_session_id["${session_id}"]="${tmux_session}"
    done <<< "${tmux_sessions}"
  fi

  all_session_ids="$(
    {
      printf '%s\n' "${!active_sessions[@]:-}"
      collect_session_ids_from_logs
    } | sed '/^[[:space:]]*$/d' | sort -u
  )"

  while IFS= read -r session_id; do
    [[ -n "${session_id}" ]] || continue
    if ! session_matches_filter "${session_id}"; then
      continue
    fi

    run_id=""
    run_log=""
    summary_path=""
    run_state="none"
    run_result=""
    issue_status=""
    run_exit_code=""

    run_dir="$(latest_run_dir_for_session "${session_id}" || true)"
    if [[ -n "${run_dir}" ]]; then
      run_id="$(basename "${run_dir}")"
      run_log="${run_dir}/run.log"
      summary_path="${run_dir}/summary.json"

      if [[ -f "${summary_path}" ]]; then
        run_result="$(jq -r '.result // ""' "${summary_path}" 2>/dev/null || true)"
        issue_status="$(jq -r '.issue_status // ""' "${summary_path}" 2>/dev/null || true)"
        if [[ "${run_result}" == "completed" || "${run_result}" == "no_work" ]]; then
          run_state="completed"
        elif [[ -n "${run_result}" ]]; then
          run_state="failed"
        fi
      fi

      if [[ "${run_state}" == "none" && -f "${run_log}" ]]; then
        if grep -q "running agent command" "${run_log}" 2>/dev/null && ! grep -q "agent command exited with" "${run_log}" 2>/dev/null; then
          run_state="running"
        else
          run_exit_code="$(grep -E 'agent command exited with [0-9]+' "${run_log}" 2>/dev/null | tail -n 1 | sed -E 's/.*agent command exited with ([0-9]+).*/\1/' || true)"
          if [[ "${run_exit_code}" =~ ^[0-9]+$ ]]; then
            if [[ "${run_exit_code}" -eq 0 ]]; then
              run_state="completed"
              run_result="${run_result:-completed}"
            else
              run_state="failed"
              run_result="${run_result:-failed}"
            fi
          fi
        fi
      fi
    fi

    session_json="$(
      jq -nc \
        --arg session_id "${session_id}" \
        --arg tmux_session "${tmux_session_by_session_id[${session_id}]:-}" \
        --arg run_id "${run_id}" \
        --arg run_state "${run_state}" \
        --arg run_result "${run_result}" \
        --arg issue_status "${issue_status}" \
        --arg summary_path "${summary_path}" \
        --arg run_log_path "${run_log}" \
        --arg observed_at "$(date -Iseconds)" \
        --argjson active "$([[ -n "${active_sessions[${session_id}]:-}" ]] && echo true || echo false)" \
        '{
          session_id: $session_id,
          tmux_session: (if $tmux_session == "" then null else $tmux_session end),
          active: $active,
          latest_run_id: (if $run_id == "" then null else $run_id end),
          latest_run_state: $run_state,
          latest_run_result: (if $run_result == "" then null else $run_result end),
          latest_issue_status: (if $issue_status == "" then null else $issue_status end),
          latest_summary_path: (if $summary_path == "" then null else $summary_path end),
          latest_run_log_path: (if $run_log_path == "" then null else $run_log_path end),
          observed_at: $observed_at
        }'
    )"

    if [[ "${first}" -eq 1 ]]; then
      first=0
    else
      sessions_json+=","
    fi
    sessions_json+="${session_json}"
  done <<< "${all_session_ids}"

  sessions_json+="]"
  printf '%s\n' "${sessions_json}" | jq -c 'sort_by(.session_id)'
}

emit_follow_events_jsonl() {
  local previous_snapshot_json="$1"
  local current_snapshot_json="$2"

  jq -crs \
    --arg observed_at "$(date -Iseconds)" \
    '
      def index_by_session($arr):
        reduce $arr[] as $row ({}; .[$row.session_id] = $row);
      def emit($type; $id; $session; $context; $payload):
        {
          schema_version: "orca.monitor.v2",
          observed_at: $observed_at,
          event_type: $type,
          event_id: $id,
          session_id: $session,
          mode: "managed",
          tmux_target: ($context.tmux_session // null)
        } + $payload;

      index_by_session(.[0]) as $prev
      | index_by_session(.[1]) as $curr
      | ($prev + $curr | keys_unsorted | unique | sort) as $session_ids
      | [
          $session_ids[] as $sid
          | ($prev[$sid] // null) as $p
          | ($curr[$sid] // null) as $c
          | (
              if ($c != null and ($c.active == true) and (($p == null) or ($p.active != true))) then
                [emit("session_up"; ("session_up:" + $sid); $sid; $c; {session: $c})]
              else
                []
              end
            )
          + (
              if ($c != null and ($c.latest_run_id != null) and ($c.latest_run_id != "") and ($c.latest_run_state == "running") and (($p == null) or ($p.latest_run_id != $c.latest_run_id) or ($p.latest_run_state != "running"))) then
                [emit("run_started"; ("run_started:" + $sid + ":" + $c.latest_run_id); $sid; $c; {run: {run_id: $c.latest_run_id, state: $c.latest_run_state, result: $c.latest_run_result, issue_status: $c.latest_issue_status, summary_path: $c.latest_summary_path}})]
              else
                []
              end
            )
          + (
              if ($c != null and ($c.latest_run_id != null) and ($c.latest_run_id != "") and ($c.latest_run_state == "completed") and (($p == null) or ($p.latest_run_id != $c.latest_run_id) or ($p.latest_run_state != "completed"))) then
                [emit("run_completed"; ("run_completed:" + $sid + ":" + $c.latest_run_id); $sid; $c; {run: {run_id: $c.latest_run_id, state: $c.latest_run_state, result: $c.latest_run_result, issue_status: $c.latest_issue_status, summary_path: $c.latest_summary_path}})]
              else
                []
              end
            )
          + (
              if ($c != null and ($c.latest_run_id != null) and ($c.latest_run_id != "") and ($c.latest_run_state == "failed") and (($p == null) or ($p.latest_run_id != $c.latest_run_id) or ($p.latest_run_state != "failed"))) then
                [emit("run_failed"; ("run_failed:" + $sid + ":" + $c.latest_run_id); $sid; $c; {run: {run_id: $c.latest_run_id, state: $c.latest_run_state, result: $c.latest_run_result, issue_status: $c.latest_issue_status, summary_path: $c.latest_summary_path}})]
              else
                []
              end
            )
          + (
              if ($p != null and ($p.active == true) and (($c == null) or ($c.active != true))) then
                [emit("session_down"; ("session_down:" + $sid); $sid; ($c // $p); {session: (($c // $p) + {active: false})})]
              else
                []
              end
            )
        ]
      | flatten
      | .[]
    ' <(printf '%s\n' "${previous_snapshot_json}") <(printf '%s\n' "${current_snapshot_json}")
}

run_follow_monitor() {
  local previous_snapshot_json="[]"
  local current_snapshot_json=""
  local emitted=0
  local lines=""
  local line=""
  local line_count=0

  while true; do
    current_snapshot_json="$(collect_follow_snapshot_json)"
    lines="$(emit_follow_events_jsonl "${previous_snapshot_json}" "${current_snapshot_json}")"
    if [[ -n "${lines}" ]]; then
      printf '%s\n' "${lines}"
      line_count="$(printf '%s\n' "${lines}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')"
      emitted=$((emitted + line_count))
      if [[ "${FOLLOW_MAX_EVENTS}" -gt 0 && "${emitted}" -ge "${FOLLOW_MAX_EVENTS}" ]]; then
        break
      fi
    fi
    previous_snapshot_json="${current_snapshot_json}"
    sleep "${FOLLOW_POLL_INTERVAL_SECONDS}"
  done
}

run_quick_status() {
  local tmux_available=0
  local tmux_sessions=""
  local tmux_count=0
  local active_session_rows=""
  local active_session_counts=""
  local active_running_count=0
  local scoped_session_count=0
  local worktree_list=""
  local agent_worktree_paths=""
  local agent_worktree_count=0
  local main_dirty_count=0
  local br_available=0
  local br_version="unavailable"
  local br_workspace_present=0
  local metrics_available=0
  local last_timestamp=""
  local last_agent=""
  local last_result=""
  local last_issue=""
  local last_duration="0"
  local last_tokens="n/a"
  local claimed_json="[]"
  local claimed_count=0
  local claimed_rows=""
  local metrics_rows=""
  local last_line=""
  local last_age_seconds

  if command -v tmux >/dev/null 2>&1; then
    tmux_available=1
    tmux_sessions="$(tmux ls -F '#S' 2>/dev/null | grep "^${SESSION_PREFIX}-" || true)"
  fi
  tmux_count="$(count_non_empty_lines "${tmux_sessions}")"
  active_session_counts="$(build_active_session_rows "${tmux_sessions}")"
  active_session_rows="$(printf '%s\n' "${active_session_counts}" | sed -n '2,$p')"
  active_session_counts="$(printf '%s\n' "${active_session_counts}" | sed -n '1p')"
  if [[ -n "${active_session_counts}" ]]; then
    IFS="${FIELD_SEP}" read -r active_running_count scoped_session_count <<< "${active_session_counts}"
  fi

  worktree_list="$(git worktree list 2>/dev/null || true)"
  agent_worktree_paths="$(
    printf '%s\n' "${worktree_list}" \
      | awk -v root="${ROOT}/worktrees/agent-" '$1 ~ "^" root {print $1}'
  )"
  agent_worktree_count="$(
    printf '%s\n' "${agent_worktree_paths}" \
      | sed '/^[[:space:]]*$/d' \
      | wc -l \
      | tr -d '[:space:]'
  )"

  main_dirty_count="$(count_non_empty_lines "$(git -C "${ROOT}" status --porcelain --untracked-files=normal 2>/dev/null || true)")"

  if command -v br >/dev/null 2>&1; then
    br_version="$(br --version 2>&1 | head -n 1)"
    if br --version >/dev/null 2>&1; then
      br_available=1
    fi
  fi
  if [[ -d "${ROOT}/.beads" ]]; then
    br_workspace_present=1
  fi

  if [[ -f "${METRICS_FILE}" && -s "${METRICS_FILE}" && -r "${METRICS_FILE}" ]] && command -v jq >/dev/null 2>&1; then
    local summary_line
    metrics_rows="$(filter_metrics_json_stream "${METRICS_FILE}")"
    last_line="$(printf '%s\n' "${metrics_rows}" | tail -n 1)"
    if [[ -n "${last_line}" ]]; then
      summary_line="$(
        printf '%s\n' "${last_line}" | jq -r '
          [
            (.timestamp // ""),
            (.agent_name // ""),
            (.result // ""),
            (.issue_id // ""),
            ((.durations_seconds.iteration_total // 0) | tostring),
            (if .tokens_used == null then "n/a" else (.tokens_used | tostring) end)
          ] | join("\u001f")
        ' 2>/dev/null || true
      )"
      if [[ -n "${summary_line}" ]]; then
        IFS="${FIELD_SEP}" read -r last_timestamp last_agent last_result last_issue last_duration last_tokens <<< "${summary_line}"
        metrics_available=1
      fi
    fi
  fi

  if [[ "${br_available}" -eq 1 && "${br_workspace_present}" -eq 1 ]]; then
    claimed_json="$(br list --status in_progress --sort updated --reverse --limit "${ORCA_STATUS_CLAIMED_LIMIT}" --json 2>/dev/null || echo "[]")"
    claimed_count="$(printf '%s\n' "${claimed_json}" | jq -r 'length' 2>/dev/null || echo "0")"
    claimed_rows="$(printf '%s\n' "${claimed_json}" | jq -r '.[:5][] | "\(.id): \(.title)"' 2>/dev/null || true)"
  fi

  if [[ "${tmux_available}" -eq 1 && "${tmux_count}" -eq 0 ]]; then
    add_alert "No active tmux sessions with prefix ${SESSION_PREFIX}."
  fi
  if [[ "${main_dirty_count}" -gt 0 ]]; then
    add_alert "Primary repo has ${main_dirty_count} uncommitted path(s)."
  fi
  if [[ "${br_available}" -eq 0 ]]; then
    add_alert "br (beads_rust) is not installed or not executable."
  fi
  if [[ "${br_workspace_present}" -eq 0 ]]; then
    add_alert "Queue workspace missing: ${ROOT}/.beads (run br init)."
  fi
  if [[ "${metrics_available}" -eq 1 ]]; then
    if last_age_seconds="$(timestamp_to_epoch "${last_timestamp}")"; then
      last_age_seconds="$(( $(date +%s) - last_age_seconds ))"
      if (( last_age_seconds < 0 )); then
        last_age_seconds=0
      fi
      if (( scoped_session_count > 0 && last_age_seconds > ORCA_STATUS_STALE_SECONDS && active_running_count == 0 )); then
        add_alert "Last metrics row is stale (${last_age_seconds}s old; threshold ${ORCA_STATUS_STALE_SECONDS}s) and no active run is detected."
      fi
    fi
    if [[ "${last_result}" != "completed" && "${last_result}" != "no_work" ]]; then
      add_alert "Most recent run result is ${last_result} (issue=${last_issue:-none}, agent=${last_agent:-unknown-agent})."
    fi
  fi

  if [[ "${OUTPUT_JSON}" -eq 1 ]]; then
    local alerts_json="[]"
    local active_sessions_json="[]"
    local claimed_top_json="[]"
    local health_status="OK"

    if [[ "${#ALERTS[@]}" -gt 0 ]]; then
      alerts_json="$(printf '%s\n' "${ALERTS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
      health_status="ATTENTION"
    fi
    if [[ -n "${active_session_rows}" ]]; then
      active_sessions_json="$(
        printf '%s\n' "${active_session_rows}" | jq -R -s -c '
          split("\n")
          | map(select(length > 0))
          | map(split("\u001f"))
          | map({
              tmux_session: .[0],
              session_id: (if .[1] == "" then null else .[1] end),
              agent_name: (if .[2] == "" then null else .[2] end),
              state: .[3],
              updated_age: .[4],
              latest_run_id: .[5]
            })
        ' 2>/dev/null || echo "[]"
      )"
    fi
    if [[ -n "${claimed_json}" ]]; then
      claimed_top_json="$(printf '%s\n' "${claimed_json}" | jq -c '.[0:5]' 2>/dev/null || echo "[]")"
    fi

    jq -nc \
      --arg schema_version "orca.status.v1" \
      --arg generated_at "$(date -Iseconds)" \
      --arg repo "${ROOT}" \
      --arg mode "quick" \
      --arg session_filter_id "${SESSION_FILTER_ID}" \
      --arg session_filter_prefix "${SESSION_FILTER_PREFIX}" \
      --arg session_scope_description "$(session_filter_description)" \
      --arg health_status "${health_status}" \
      --arg br_version "${br_version}" \
      --arg latest_timestamp "${last_timestamp}" \
      --arg latest_agent "${last_agent}" \
      --arg latest_result "${last_result}" \
      --arg latest_issue "${last_issue}" \
      --arg latest_duration "${last_duration}" \
      --arg latest_tokens "${last_tokens}" \
      --arg latest_age "$(if [[ -n "${last_timestamp}" ]]; then format_age_from_timestamp "${last_timestamp}"; else echo ""; fi)" \
      --argjson tmux_available "$([[ "${tmux_available}" -eq 1 ]] && echo true || echo false)" \
      --argjson sessions_total "${tmux_count}" \
      --argjson active_running_count "${active_running_count}" \
      --argjson scoped_session_count "${scoped_session_count}" \
      --argjson agent_worktree_count "${agent_worktree_count}" \
      --argjson main_dirty_count "${main_dirty_count}" \
      --argjson claimed_count "${claimed_count}" \
      --argjson metrics_available "$([[ "${metrics_available}" -eq 1 ]] && echo true || echo false)" \
      --argjson br_workspace_present "$([[ "${br_workspace_present}" -eq 1 ]] && echo true || echo false)" \
      --argjson alerts "${alerts_json}" \
      --argjson active_sessions "${active_sessions_json}" \
      --argjson claimed_top "${claimed_top_json}" \
      '{
        schema_version: $schema_version,
        generated_at: $generated_at,
        repo: $repo,
        mode: $mode,
        session_scope: {
          id: (if $session_filter_id == "" then null else $session_filter_id end),
          prefix: (if $session_filter_prefix == "" then null else $session_filter_prefix end),
          description: $session_scope_description
        },
        health: {
          status: $health_status,
          alert_count: ($alerts | length),
          alerts: $alerts
        },
        signals: {
          tmux_available: $tmux_available,
          sessions_total: $sessions_total,
          active_running_count: $active_running_count,
          scoped_session_count: $scoped_session_count,
          agent_worktree_count: $agent_worktree_count,
          primary_repo_dirty_paths: $main_dirty_count,
          claimed_count: $claimed_count
        },
        latest_activity: (
          if $metrics_available then
            {
              timestamp: (if $latest_timestamp == "" then null else $latest_timestamp end),
              age: (if $latest_age == "" then null else $latest_age end),
              agent_name: (if $latest_agent == "" then null else $latest_agent end),
              result: (if $latest_result == "" then null else $latest_result end),
              issue_id: (if $latest_issue == "" then null else $latest_issue end),
              duration_seconds: ($latest_duration | tonumber? // 0),
              tokens_used: ($latest_tokens | tonumber? // null)
            }
          else
            null
          end
        ),
        queue_backend: {
          br_version: $br_version,
          workspace_present: $br_workspace_present
        },
        active_sessions: $active_sessions,
        active_claims_top: $claimed_top
      }'
    return 0
  fi

  echo "== orca health (quick) =="
  echo "time: $(date -Iseconds)"
  echo "repo: ${ROOT}"
  echo "mode: quick (default; use --full for full diagnostics)"
  echo "session scope: $(session_filter_description)"
  if [[ "${tmux_available}" -eq 1 ]]; then
    echo "sessions (${SESSION_PREFIX}-*): ${tmux_count}"
  else
    echo "sessions (${SESSION_PREFIX}-*): tmux not installed"
  fi
  echo "active runs (scoped): ${active_running_count}/${scoped_session_count}"
  echo "agent worktrees: ${agent_worktree_count}"
  echo "primary repo dirty paths: ${main_dirty_count}"
  echo "claimed issues: ${claimed_count}"
  if [[ "${metrics_available}" -eq 1 ]]; then
    echo "latest activity: $(format_age_from_timestamp "${last_timestamp}") agent=${last_agent:-unknown-agent} result=${last_result:-unknown} issue=${last_issue:-none} duration=$(format_seconds_short "${last_duration}") tokens=${last_tokens:-n/a}"
  else
    echo "latest activity: unavailable"
  fi

  if [[ "${#ALERTS[@]}" -eq 0 ]]; then
    echo "health: OK"
  else
    echo "health: ATTENTION (${#ALERTS[@]} alert(s))"
    for alert in "${ALERTS[@]}"; do
      echo "- ${alert}"
    done
  fi

  echo
  echo "== queue backend (quick) =="
  echo "br version: ${br_version}"
  echo "workspace: $([[ "${br_workspace_present}" -eq 1 ]] && echo present || echo missing)"

  echo
  echo "== active sessions (scoped) =="
  if [[ -n "${active_session_rows}" ]]; then
    while IFS="${FIELD_SEP}" read -r tmux_session_name session_id agent_name state run_age run_name; do
      [[ -z "${tmux_session_name}" ]] && continue
      echo "- ${tmux_session_name}: session=${session_id:-unknown} agent=${agent_name:-unknown-agent} state=${state} latest_run=${run_name} updated=${run_age}"
    done <<< "${active_session_rows}"
  else
    echo "(none)"
  fi

  echo
  echo "== tmux sessions (raw) =="
  if [[ "${tmux_available}" -eq 1 ]]; then
    if [[ -n "${tmux_sessions}" ]]; then
      printf '%s\n' "${tmux_sessions}"
    else
      echo "(none)"
    fi
  else
    echo "(tmux not installed)"
  fi

  echo
  echo "== active claims (top 5) =="
  if [[ -n "${claimed_rows}" ]]; then
    printf '%s\n' "${claimed_rows}"
  else
    echo "(none)"
  fi
}

if [[ "${FOLLOW_MODE}" -eq 1 ]]; then
  if [[ "${STATUS_MODE}" == "full" ]]; then
    invalid "--follow cannot be combined with --full"
  fi
  run_follow_monitor
  exit 0
fi

if [[ "${STATUS_MODE}" == "quick" ]]; then
  run_quick_status
  exit 0
fi

tmux_available=0
tmux_sessions=""
tmux_sessions_verbose=""
active_session_rows=""
active_session_counts=""
active_running_count=0
scoped_session_count=0
if command -v tmux >/dev/null 2>&1; then
  tmux_available=1
  tmux_sessions="$(tmux ls -F '#S' 2>/dev/null | grep "^${SESSION_PREFIX}-" || true)"
  tmux_sessions_verbose="$(tmux ls 2>/dev/null | grep "^${SESSION_PREFIX}-" || true)"
fi
tmux_count="$(count_non_empty_lines "${tmux_sessions}")"
active_session_counts="$(build_active_session_rows "${tmux_sessions}")"
active_session_rows="$(printf '%s\n' "${active_session_counts}" | sed -n '2,$p')"
active_session_counts="$(printf '%s\n' "${active_session_counts}" | sed -n '1p')"
if [[ -n "${active_session_counts}" ]]; then
  IFS="${FIELD_SEP}" read -r active_running_count scoped_session_count <<< "${active_session_counts}"
fi

worktree_list="$(git worktree list 2>/dev/null || true)"
agent_worktree_paths="$(
  printf '%s\n' "${worktree_list}" \
    | awk -v root="${ROOT}/worktrees/agent-" '$1 ~ "^" root {print $1}'
)"

agent_worktree_count="$(
  printf '%s\n' "${agent_worktree_paths}" \
    | sed '/^[[:space:]]*$/d' \
    | wc -l \
    | tr -d '[:space:]'
)"

dirty_agent_worktree_count=0
dirty_agent_worktree_rows=""
if [[ -n "${agent_worktree_paths}" ]]; then
  while IFS= read -r worktree_path; do
    [[ -z "${worktree_path}" ]] && continue

    if ! git -C "${worktree_path}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      continue
    fi

    dirty_paths="$(git -C "${worktree_path}" status --porcelain --untracked-files=normal 2>/dev/null || true)"
    dirty_count="$(count_non_empty_lines "${dirty_paths}")"
    if [[ "${dirty_count}" -gt 0 ]]; then
      dirty_agent_worktree_count=$((dirty_agent_worktree_count + 1))
      agent_name="$(basename "${worktree_path}")"
      row="${agent_name}${FIELD_SEP}${worktree_path}${FIELD_SEP}${dirty_count}"
      if [[ -n "${dirty_agent_worktree_rows}" ]]; then
        dirty_agent_worktree_rows+=$'\n'
      fi
      dirty_agent_worktree_rows+="${row}"
    fi
  done <<< "${agent_worktree_paths}"
fi

main_dirty_count="$(count_non_empty_lines "$(git -C "${ROOT}" status --porcelain --untracked-files=normal 2>/dev/null || true)")"

br_available=0
br_version=""
br_workspace_present=0
br_doctor_ok="unknown"
br_doctor_output=""
br_sync_status_output=""

if command -v br >/dev/null 2>&1; then
  br_version_raw="$(br --version 2>&1 || true)"
  br_version="$(printf '%s\n' "${br_version_raw}" | head -n 1)"
  if br --version >/dev/null 2>&1; then
    br_available=1
  fi
fi

if [[ -d "${ROOT}/.beads" ]]; then
  br_workspace_present=1
fi

if [[ "${br_available}" -eq 1 && "${br_workspace_present}" -eq 1 ]]; then
  if br_doctor_output="$(br doctor 2>&1)"; then
    br_doctor_ok="yes"
  else
    br_doctor_ok="no"
  fi

  br_sync_status_output="$(br sync --status 2>&1 || true)"
fi

metrics_summary_available=0
total_runs=0
completed_runs=0
blocked_runs=0
failed_runs=0
no_work_runs=0
last_timestamp=""
last_agent=""
last_result=""
last_issue=""
last_duration="0"
last_tokens="n/a"
agent_activity_rows=""
recent_metrics_rows=""

if [[ -f "${METRICS_FILE}" && -s "${METRICS_FILE}" && -r "${METRICS_FILE}" ]] && command -v jq >/dev/null 2>&1; then
  summary_line=""
  if session_filter_active; then
    if load_filtered_metrics_summary summary_line agent_activity_rows; then
      IFS="${FIELD_SEP}" read -r total_runs completed_runs blocked_runs failed_runs no_work_runs last_timestamp last_agent last_result last_issue last_duration last_tokens <<< "${summary_line}"
      metrics_summary_available=1
    fi
  elif load_full_metrics_summary_from_cache summary_line agent_activity_rows; then
    IFS="${FIELD_SEP}" read -r total_runs completed_runs blocked_runs failed_runs no_work_runs last_timestamp last_agent last_result last_issue last_duration last_tokens <<< "${summary_line}"
    metrics_summary_available=1
  fi

  recent_metrics_rows="$(
    filter_metrics_json_stream "${METRICS_FILE}" \
      | tail -n "${ORCA_STATUS_RECENT_METRIC_LIMIT}" \
      | jq -r '
        [
          (.timestamp // "unknown-time"),
          (.session_id // "unknown-session"),
          (.agent_name // "unknown-agent"),
          (.issue_id // "none"),
          (.result // "unknown"),
          (.reason // "unknown"),
          ((.durations_seconds.iteration_total // 0) | tostring),
          (if .tokens_used == null then "n/a" else (.tokens_used | tostring) end)
        ]
        | join("\u001f")
      ' 2>/dev/null || true
  )"
fi

if [[ "${tmux_available}" -eq 1 && "${tmux_count}" -eq 0 ]]; then
  add_alert "No active tmux sessions with prefix ${SESSION_PREFIX}."
fi

if [[ "${main_dirty_count}" -gt 0 ]]; then
  add_alert "Primary repo has ${main_dirty_count} uncommitted path(s)."
fi

if [[ "${dirty_agent_worktree_count}" -gt 0 ]]; then
  add_alert "${dirty_agent_worktree_count} agent worktree(s) have uncommitted changes; next start may fail run branch setup."
fi

if [[ "${br_available}" -eq 0 ]]; then
  add_alert "br (beads_rust) is not installed or not executable."
fi

if [[ "${br_workspace_present}" -eq 0 ]]; then
  add_alert "Queue workspace missing: ${ROOT}/.beads (run br init)."
fi

if [[ "${br_doctor_ok}" == "no" ]]; then
  add_alert "br doctor failed; queue workspace is unhealthy."
fi

if [[ "${metrics_summary_available}" -eq 1 ]]; then
  last_age_seconds=""
  if last_age_seconds="$(timestamp_to_epoch "${last_timestamp}")"; then
    last_age_seconds="$(( $(date +%s) - last_age_seconds ))"
    if (( last_age_seconds < 0 )); then
      last_age_seconds=0
    fi
    if (( scoped_session_count > 0 && last_age_seconds > ORCA_STATUS_STALE_SECONDS && active_running_count == 0 )); then
      add_alert "Last metrics row is stale (${last_age_seconds}s old; threshold ${ORCA_STATUS_STALE_SECONDS}s) and no active run is detected."
    fi
  fi

  if [[ "${last_result}" != "completed" && "${last_result}" != "no_work" ]]; then
    add_alert "Most recent run result is ${last_result} (issue=${last_issue:-none}, agent=${last_agent:-unknown-agent})."
  fi
fi

if [[ "${OUTPUT_JSON}" -eq 1 ]]; then
  alerts_json="[]"
  active_sessions_json="[]"
  agent_activity_json="[]"
  dirty_worktrees_json="[]"
  recent_metrics_json="[]"
  claimed_issues_json="[]"
  closed_issues_json="[]"
  br_sync_status_lines_json="[]"
  health_status="OK"

  if [[ "${#ALERTS[@]}" -gt 0 ]]; then
    alerts_json="$(printf '%s\n' "${ALERTS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
    health_status="ATTENTION"
  fi
  if [[ -n "${active_session_rows}" ]]; then
    active_sessions_json="$(
      printf '%s\n' "${active_session_rows}" | jq -R -s -c '
        split("\n")
        | map(select(length > 0))
        | map(split("\u001f"))
        | map({
            tmux_session: .[0],
            session_id: (if .[1] == "" then null else .[1] end),
            agent_name: (if .[2] == "" then null else .[2] end),
            state: .[3],
            updated_age: .[4],
            latest_run_id: .[5]
          })
      ' 2>/dev/null || echo "[]"
    )"
  fi
  if [[ -n "${agent_activity_rows}" ]]; then
    agent_activity_json="$(
      printf '%s\n' "${agent_activity_rows}" | jq -R -s -c '
        split("\n")
        | map(select(length > 0))
        | map(split("\u001f"))
        | map({
            agent_name: .[0],
            session_id: (if .[1] == "" then null else .[1] end),
            timestamp: (if .[2] == "" then null else .[2] end),
            result: (if .[3] == "" then null else .[3] end),
            issue_id: (if .[4] == "" then null else .[4] end),
            duration_seconds: (.[5] | tonumber? // 0),
            tokens_used: (.[6] | tonumber? // null),
            loop_action: (if .[7] == "" then null else .[7] end),
            loop_action_reason: (if .[8] == "" then null else .[8] end)
          })
      ' 2>/dev/null || echo "[]"
    )"
  fi
  if [[ -n "${dirty_agent_worktree_rows}" ]]; then
    dirty_worktrees_json="$(
      printf '%s\n' "${dirty_agent_worktree_rows}" | jq -R -s -c '
        split("\n")
        | map(select(length > 0))
        | map(split("\u001f"))
        | map({
            agent_name: .[0],
            worktree_path: .[1],
            dirty_paths: (.[2] | tonumber? // 0)
          })
      ' 2>/dev/null || echo "[]"
    )"
  fi
  if [[ -n "${recent_metrics_rows}" ]]; then
    recent_metrics_json="$(
      printf '%s\n' "${recent_metrics_rows}" | jq -R -s -c '
        split("\n")
        | map(select(length > 0))
        | map(split("\u001f"))
        | map({
            timestamp: .[0],
            session_id: .[1],
            agent_name: .[2],
            issue_id: .[3],
            result: .[4],
            reason: .[5],
            duration_seconds: (.[6] | tonumber? // 0),
            tokens_used: (.[7] | tonumber? // null)
          })
      ' 2>/dev/null || echo "[]"
    )"
  fi
  if [[ "${br_available}" -eq 1 ]]; then
    claimed_issues_json="$(br list --status in_progress --sort updated --reverse --limit "${ORCA_STATUS_CLAIMED_LIMIT}" --json 2>/dev/null || echo "[]")"
    closed_issues_json="$(br list --status closed --sort updated --reverse --limit "${ORCA_STATUS_CLOSED_LIMIT}" --json 2>/dev/null || echo "[]")"
  fi
  if [[ -n "${br_sync_status_output}" ]]; then
    br_sync_status_lines_json="$(printf '%s\n' "${br_sync_status_output}" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  fi

  jq -nc \
    --arg schema_version "orca.status.v1" \
    --arg generated_at "$(date -Iseconds)" \
    --arg repo "${ROOT}" \
    --arg mode "full" \
    --arg session_filter_id "${SESSION_FILTER_ID}" \
    --arg session_filter_prefix "${SESSION_FILTER_PREFIX}" \
    --arg session_scope_description "$(session_filter_description)" \
    --arg health_status "${health_status}" \
    --arg br_version "${br_version}" \
    --arg br_doctor_ok "${br_doctor_ok}" \
    --arg latest_timestamp "${last_timestamp}" \
    --arg latest_age "$(if [[ -n "${last_timestamp}" ]]; then format_age_from_timestamp "${last_timestamp}"; else echo ""; fi)" \
    --arg latest_agent "${last_agent}" \
    --arg latest_result "${last_result}" \
    --arg latest_issue "${last_issue}" \
    --arg latest_duration "${last_duration}" \
    --arg latest_tokens "${last_tokens}" \
    --argjson tmux_available "$([[ "${tmux_available}" -eq 1 ]] && echo true || echo false)" \
    --argjson sessions_total "${tmux_count}" \
    --argjson active_running_count "${active_running_count}" \
    --argjson scoped_session_count "${scoped_session_count}" \
    --argjson agent_worktree_count "${agent_worktree_count}" \
    --argjson dirty_agent_worktree_count "${dirty_agent_worktree_count}" \
    --argjson main_dirty_count "${main_dirty_count}" \
    --argjson metrics_summary_available "$([[ "${metrics_summary_available}" -eq 1 ]] && echo true || echo false)" \
    --argjson total_runs "${total_runs}" \
    --argjson completed_runs "${completed_runs}" \
    --argjson blocked_runs "${blocked_runs}" \
    --argjson failed_runs "${failed_runs}" \
    --argjson no_work_runs "${no_work_runs}" \
    --argjson br_available "$([[ "${br_available}" -eq 1 ]] && echo true || echo false)" \
    --argjson br_workspace_present "$([[ "${br_workspace_present}" -eq 1 ]] && echo true || echo false)" \
    --argjson alerts "${alerts_json}" \
    --argjson active_sessions "${active_sessions_json}" \
    --argjson agent_activity "${agent_activity_json}" \
    --argjson dirty_worktrees "${dirty_worktrees_json}" \
    --argjson recent_metrics "${recent_metrics_json}" \
    --argjson claimed_issues "${claimed_issues_json}" \
    --argjson closed_issues "${closed_issues_json}" \
    --argjson br_sync_status_lines "${br_sync_status_lines_json}" \
    '{
      schema_version: $schema_version,
      generated_at: $generated_at,
      repo: $repo,
      mode: $mode,
      session_scope: {
        id: (if $session_filter_id == "" then null else $session_filter_id end),
        prefix: (if $session_filter_prefix == "" then null else $session_filter_prefix end),
        description: $session_scope_description
      },
      health: {
        status: $health_status,
        alert_count: ($alerts | length),
        alerts: $alerts
      },
      signals: {
        tmux_available: $tmux_available,
        sessions_total: $sessions_total,
        active_running_count: $active_running_count,
        scoped_session_count: $scoped_session_count,
        agent_worktree_count: $agent_worktree_count,
        dirty_agent_worktree_count: $dirty_agent_worktree_count,
        primary_repo_dirty_paths: $main_dirty_count
      },
      metrics_summary: (
        if $metrics_summary_available then
          {
            total_runs: $total_runs,
            completed_runs: $completed_runs,
            blocked_runs: $blocked_runs,
            failed_runs: $failed_runs,
            no_work_runs: $no_work_runs,
            last_run: {
              timestamp: (if $latest_timestamp == "" then null else $latest_timestamp end),
              age: (if $latest_age == "" then null else $latest_age end),
              agent_name: (if $latest_agent == "" then null else $latest_agent end),
              result: (if $latest_result == "" then null else $latest_result end),
              issue_id: (if $latest_issue == "" then null else $latest_issue end),
              duration_seconds: ($latest_duration | tonumber? // 0),
              tokens_used: ($latest_tokens | tonumber? // null)
            }
          }
        else
          null
        end
      ),
      queue_backend: {
        br_available: $br_available,
        br_version: $br_version,
        workspace_present: $br_workspace_present,
        doctor: $br_doctor_ok,
        sync_status_lines: $br_sync_status_lines
      },
      active_sessions: $active_sessions,
      agent_activity: $agent_activity,
      dirty_agent_worktrees: $dirty_worktrees,
      queue_snapshots: {
        in_progress: $claimed_issues,
        closed: $closed_issues
      },
      recent_metrics: $recent_metrics
    }'
  exit 0
fi

echo "== orca health =="
echo "time: $(date -Iseconds)"
echo "repo: ${ROOT}"
echo "session scope: $(session_filter_description)"
if [[ "${tmux_available}" -eq 1 ]]; then
  echo "sessions (${SESSION_PREFIX}-*): ${tmux_count}"
else
  echo "sessions (${SESSION_PREFIX}-*): tmux not installed"
fi
echo "active runs (scoped): ${active_running_count}/${scoped_session_count}"
echo "agent worktrees: ${agent_worktree_count}"
echo "dirty agent worktrees: ${dirty_agent_worktree_count}"
echo "primary repo dirty paths: ${main_dirty_count}"

if [[ "${metrics_summary_available}" -eq 1 ]]; then
  echo "metrics rows: ${total_runs} (completed=${completed_runs}, blocked=${blocked_runs}, failed=${failed_runs}, no_work=${no_work_runs})"
  echo "last run: $(format_age_from_timestamp "${last_timestamp}") agent=${last_agent:-unknown-agent} result=${last_result:-unknown} issue=${last_issue:-none} duration=$(format_seconds_short "${last_duration}") tokens=${last_tokens:-n/a}"
else
  echo "metrics rows: unavailable"
fi

if [[ "${#ALERTS[@]}" -eq 0 ]]; then
  echo "health: OK"
else
  echo "health: ATTENTION (${#ALERTS[@]} alert(s))"
  for alert in "${ALERTS[@]}"; do
    echo "- ${alert}"
  done
fi

echo
echo "== queue backend (br) =="
if [[ "${br_available}" -eq 1 ]]; then
  echo "br version: ${br_version}"
else
  echo "br version: unavailable"
fi
echo "workspace: $([[ "${br_workspace_present}" -eq 1 ]] && echo present || echo missing)"
if [[ "${br_doctor_ok}" == "yes" ]]; then
  echo "doctor: OK"
elif [[ "${br_doctor_ok}" == "no" ]]; then
  echo "doctor: FAILED"
  printf '%s\n' "${br_doctor_output}" | head -n 5
else
  echo "doctor: not checked"
fi

echo
echo "== active sessions (scoped) =="
if [[ -n "${active_session_rows}" ]]; then
  while IFS="${FIELD_SEP}" read -r tmux_session_name session_id agent_name state run_age run_name; do
    [[ -z "${tmux_session_name}" ]] && continue
    echo "- ${tmux_session_name}: session=${session_id:-unknown} agent=${agent_name:-unknown-agent} state=${state} latest_run=${run_name} updated=${run_age}"
  done <<< "${active_session_rows}"
else
  echo "(none)"
fi

echo
echo "== agent activity =="
if [[ -n "${agent_activity_rows}" ]]; then
  while IFS="${FIELD_SEP}" read -r agent_name session_id timestamp result issue_id duration_s tokens loop_action loop_action_reason; do
    [[ -z "${agent_name}" ]] && continue
    echo "- ${agent_name}: session=${session_id:-unknown-session} result=${result} issue=${issue_id} age=$(format_age_from_timestamp "${timestamp}") duration=$(format_seconds_short "${duration_s}") tokens=${tokens} loop=${loop_action}${loop_action_reason:+ note=${loop_action_reason}}"
  done <<< "${agent_activity_rows}"
else
  echo "(no parsed metrics rows)"
fi

echo
echo "== agent worktree hygiene =="
if [[ -n "${dirty_agent_worktree_rows}" ]]; then
  while IFS="${FIELD_SEP}" read -r agent_name worktree_path dirty_path_count; do
    [[ -z "${agent_name}" ]] && continue
    echo "- ${agent_name}: dirty_paths=${dirty_path_count} path=${worktree_path}"
  done <<< "${dirty_agent_worktree_rows}"
else
  echo "(all agent worktrees clean)"
fi

echo
echo "== tmux sessions (raw) =="
if [[ "${tmux_available}" -eq 1 ]]; then
  if [[ -n "${tmux_sessions_verbose}" ]]; then
    printf '%s\n' "${tmux_sessions_verbose}"
  else
    echo "(none)"
  fi
else
  echo "(tmux not installed)"
fi

echo
echo "== worktrees =="
if [[ -n "${worktree_list}" ]]; then
  printf '%s\n' "${worktree_list}"
else
  echo "(none)"
fi

echo
echo "== currently claimed issues =="
if [[ "${br_available}" -eq 1 ]]; then
  br list --status in_progress --sort updated --reverse --limit "${ORCA_STATUS_CLAIMED_LIMIT}" || true
else
  echo "(br not installed)"
fi

echo
echo "== recently closed issues =="
if [[ "${br_available}" -eq 1 ]]; then
  br list --status closed --sort updated --reverse --limit "${ORCA_STATUS_CLOSED_LIMIT}" || true
else
  echo "(br not installed)"
fi

echo
echo "== br sync status =="
if [[ "${br_available}" -eq 1 && "${br_workspace_present}" -eq 1 ]]; then
  if [[ -n "${br_sync_status_output}" ]]; then
    printf '%s\n' "${br_sync_status_output}"
  else
    echo "(no output)"
  fi
else
  echo "(unavailable)"
fi

echo
echo "== latest metrics =="
if [[ -f "${METRICS_FILE}" ]]; then
  if [[ -n "${recent_metrics_rows}" ]]; then
    while IFS="${FIELD_SEP}" read -r timestamp session_id agent_name issue_id result reason duration_s tokens; do
      [[ -z "${timestamp}" ]] && continue
      echo "${timestamp} ($(format_age_from_timestamp "${timestamp}")) session=${session_id} agent=${agent_name} issue=${issue_id} result=${result} reason=${reason} total=$(format_seconds_short "${duration_s}") tokens=${tokens}"
    done <<< "${recent_metrics_rows}"
  else
    filter_metrics_json_stream "${METRICS_FILE}" | tail -n "${ORCA_STATUS_RECENT_METRIC_LIMIT}" || true
  fi
else
  echo "(no metrics yet)"
fi
