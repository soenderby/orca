#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SESSION_PREFIX="${SESSION_PREFIX:-orca-agent}"
METRICS_FILE="${ROOT}/agent-logs/metrics.jsonl"
ORCA_STATUS_CACHE_DIR="${ORCA_STATUS_CACHE_DIR:-${ROOT}/agent-logs/cache}"
ORCA_STATUS_METRICS_CACHE_MAX_FILES="${ORCA_STATUS_METRICS_CACHE_MAX_FILES:-5}"
ORCA_STATUS_STALE_SECONDS="${ORCA_STATUS_STALE_SECONDS:-900}"
ORCA_STATUS_CLAIMED_LIMIT="${ORCA_STATUS_CLAIMED_LIMIT:-20}"
ORCA_STATUS_CLOSED_LIMIT="${ORCA_STATUS_CLOSED_LIMIT:-10}"
ORCA_STATUS_RECENT_METRIC_LIMIT="${ORCA_STATUS_RECENT_METRIC_LIMIT:-10}"
FIELD_SEP=$'\x1f'
STATUS_MODE="quick"

usage() {
  cat <<USAGE
Usage:
  ./orca.sh status [--quick|--full]
  ./status.sh [--quick|--full]

Modes:
  --quick  Fast active-operations summary (default)
  --full   Full diagnostics (legacy status output)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)
      STATUS_MODE="quick"
      ;;
    --full)
      STATUS_MODE="full"
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

  printf '%s\n' "${stat_output}"
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
            | unique_by(.agent_name)
            | sort_by(.agent_name)
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

run_quick_status() {
  local tmux_available=0
  local tmux_sessions=""
  local tmux_count=0
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
  local last_age_seconds

  if command -v tmux >/dev/null 2>&1; then
    tmux_available=1
    tmux_sessions="$(tmux ls -F '#S' 2>/dev/null | grep "^${SESSION_PREFIX}-" || true)"
  fi
  tmux_count="$(count_non_empty_lines "${tmux_sessions}")"

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
    local last_line
    local summary_line
    last_line="$(tail -n 1 "${METRICS_FILE}" 2>/dev/null || true)"
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
      if (( tmux_count > 0 && last_age_seconds > ORCA_STATUS_STALE_SECONDS )); then
        add_alert "Last metrics row is stale (${last_age_seconds}s old; threshold ${ORCA_STATUS_STALE_SECONDS}s)."
      fi
    fi
    if [[ "${last_result}" != "completed" && "${last_result}" != "no_work" ]]; then
      add_alert "Most recent run result is ${last_result} (issue=${last_issue:-none}, agent=${last_agent:-unknown-agent})."
    fi
  fi

  echo "== orca health (quick) =="
  echo "time: $(date -Iseconds)"
  echo "repo: ${ROOT}"
  echo "mode: quick (default; use --full for full diagnostics)"
  if [[ "${tmux_available}" -eq 1 ]]; then
    echo "sessions (${SESSION_PREFIX}-*): ${tmux_count}"
  else
    echo "sessions (${SESSION_PREFIX}-*): tmux not installed"
  fi
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
  echo "== active sessions =="
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

if [[ "${STATUS_MODE}" == "quick" ]]; then
  run_quick_status
  exit 0
fi

tmux_available=0
tmux_sessions=""
tmux_sessions_verbose=""
if command -v tmux >/dev/null 2>&1; then
  tmux_available=1
  tmux_sessions="$(tmux ls -F '#S' 2>/dev/null | grep "^${SESSION_PREFIX}-" || true)"
  tmux_sessions_verbose="$(tmux ls 2>/dev/null | grep "^${SESSION_PREFIX}-" || true)"
fi
tmux_count="$(count_non_empty_lines "${tmux_sessions}")"

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
  if load_full_metrics_summary_from_cache summary_line agent_activity_rows; then
    IFS="${FIELD_SEP}" read -r total_runs completed_runs blocked_runs failed_runs no_work_runs last_timestamp last_agent last_result last_issue last_duration last_tokens <<< "${summary_line}"
    metrics_summary_available=1
  fi

  recent_metrics_rows="$(
    tail -n "${ORCA_STATUS_RECENT_METRIC_LIMIT}" "${METRICS_FILE}" 2>/dev/null \
      | jq -r '
          [
            (.timestamp // "unknown-time"),
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
    if (( tmux_count > 0 && last_age_seconds > ORCA_STATUS_STALE_SECONDS )); then
      add_alert "Last metrics row is stale (${last_age_seconds}s old; threshold ${ORCA_STATUS_STALE_SECONDS}s)."
    fi
  fi

  if [[ "${last_result}" != "completed" && "${last_result}" != "no_work" ]]; then
    add_alert "Most recent run result is ${last_result} (issue=${last_issue:-none}, agent=${last_agent:-unknown-agent})."
  fi
fi

echo "== orca health =="
echo "time: $(date -Iseconds)"
echo "repo: ${ROOT}"
if [[ "${tmux_available}" -eq 1 ]]; then
  echo "sessions (${SESSION_PREFIX}-*): ${tmux_count}"
else
  echo "sessions (${SESSION_PREFIX}-*): tmux not installed"
fi
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
echo "== agent activity =="
if [[ -n "${agent_activity_rows}" ]]; then
  while IFS="${FIELD_SEP}" read -r agent_name timestamp result issue_id duration_s tokens loop_action loop_action_reason; do
    [[ -z "${agent_name}" ]] && continue
    echo "- ${agent_name}: result=${result} issue=${issue_id} age=$(format_age_from_timestamp "${timestamp}") duration=$(format_seconds_short "${duration_s}") tokens=${tokens} loop=${loop_action}${loop_action_reason:+ note=${loop_action_reason}}"
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
echo "== tmux sessions =="
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
    while IFS="${FIELD_SEP}" read -r timestamp agent_name issue_id result reason duration_s tokens; do
      [[ -z "${timestamp}" ]] && continue
      echo "${timestamp} ($(format_age_from_timestamp "${timestamp}")) agent=${agent_name} issue=${issue_id} result=${result} reason=${reason} total=$(format_seconds_short "${duration_s}") tokens=${tokens}"
    done <<< "${recent_metrics_rows}"
  else
    tail -n "${ORCA_STATUS_RECENT_METRIC_LIMIT}" "${METRICS_FILE}" || true
  fi
else
  echo "(no metrics yet)"
fi
