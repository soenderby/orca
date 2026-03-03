#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SESSION_PREFIX="${SESSION_PREFIX:-bb-agent}"
METRICS_FILE="${ROOT}/agent-logs/metrics.jsonl"
ORCA_STATUS_STALE_SECONDS="${ORCA_STATUS_STALE_SECONDS:-900}"
ORCA_STATUS_CLAIMED_LIMIT="${ORCA_STATUS_CLAIMED_LIMIT:-20}"
ORCA_STATUS_CLOSED_LIMIT="${ORCA_STATUS_CLOSED_LIMIT:-10}"
ORCA_STATUS_RECENT_METRIC_LIMIT="${ORCA_STATUS_RECENT_METRIC_LIMIT:-10}"
DOLT_CONTAINER_NAME="${DOLT_CONTAINER_NAME:-bookbinder-dolt}"
DOLT_EXPECT_HOST="${DOLT_EXPECT_HOST:-localhost}"
DOLT_EXPECT_PORT="${DOLT_EXPECT_PORT:-3307}"
FIELD_SEP=$'\x1f'

safe_run() {
  local context="$1"
  shift
  if "$@"; then
    return 0
  fi

  echo "(${context} failed)" >&2
  return 1
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

truncate_text() {
  local text="$1"
  local max_len="$2"

  if (( ${#text} <= max_len )); then
    printf '%s' "${text}"
    return 0
  fi

  printf '%s...' "${text:0:max_len-3}"
}

session_name_for_agent() {
  local agent_name="$1"

  if [[ "${agent_name}" =~ ^agent-[0-9]+$ ]]; then
    echo "${SESSION_PREFIX}-${agent_name#agent-}"
    return 0
  fi

  echo ""
}

session_is_up() {
  local session_name="$1"

  if [[ -z "${session_name}" ]]; then
    return 1
  fi

  if [[ -z "${tmux_sessions}" ]]; then
    return 1
  fi

  printf '%s\n' "${tmux_sessions}" | grep -Fxq "${session_name}"
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

dolt_mode="unknown"
dolt_database="unknown"
dolt_host_cfg="unknown"
dolt_port_cfg="unknown"
dolt_user_cfg="unknown"
dolt_container_state="unknown"
dolt_container_status_line=""
dolt_server_check="unknown"
dolt_server_error=""

if [[ -f "${ROOT}/.beads/metadata.json" ]]; then
  if command -v jq >/dev/null 2>&1; then
    dolt_mode="$(jq -r '.dolt_mode // empty' "${ROOT}/.beads/metadata.json" 2>/dev/null || true)"
    dolt_database="$(jq -r '.dolt_database // empty' "${ROOT}/.beads/metadata.json" 2>/dev/null || true)"
    dolt_host_cfg="$(jq -r '.dolt_server_host // empty' "${ROOT}/.beads/metadata.json" 2>/dev/null || true)"
    dolt_port_cfg="$(jq -r '.dolt_server_port // empty' "${ROOT}/.beads/metadata.json" 2>/dev/null || true)"
    dolt_user_cfg="$(jq -r '.dolt_server_user // empty' "${ROOT}/.beads/metadata.json" 2>/dev/null || true)"
  else
    dolt_mode="$(grep -Eo '"dolt_mode"[[:space:]]*:[[:space:]]*"[^"]+"' "${ROOT}/.beads/metadata.json" | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    dolt_database="$(grep -Eo '"dolt_database"[[:space:]]*:[[:space:]]*"[^"]+"' "${ROOT}/.beads/metadata.json" | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    dolt_host_cfg="$(grep -Eo '"dolt_server_host"[[:space:]]*:[[:space:]]*"[^"]+"' "${ROOT}/.beads/metadata.json" | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    dolt_port_cfg="$(grep -Eo '"dolt_server_port"[[:space:]]*:[[:space:]]*[0-9]+' "${ROOT}/.beads/metadata.json" | sed -E 's/.*: *([0-9]+)/\1/' || true)"
    dolt_user_cfg="$(grep -Eo '"dolt_server_user"[[:space:]]*:[[:space:]]*"[^"]+"' "${ROOT}/.beads/metadata.json" | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  fi
fi

dolt_mode="${dolt_mode:-unknown}"
dolt_database="${dolt_database:-unknown}"
dolt_host_cfg="${dolt_host_cfg:-unknown}"
dolt_port_cfg="${dolt_port_cfg:-unknown}"
dolt_user_cfg="${dolt_user_cfg:-unknown}"

if command -v docker >/dev/null 2>&1; then
  docker_ps_names_output=""
  if docker_ps_names_output="$(docker ps -a --filter "name=^${DOLT_CONTAINER_NAME}$" --format '{{.Names}}' 2>&1)"; then
    container_name="${docker_ps_names_output}"
    if [[ -n "${container_name}" ]]; then
      if docker inspect -f '{{.State.Running}}' "${DOLT_CONTAINER_NAME}" 2>/dev/null | grep -q '^true$'; then
        dolt_container_state="running"
      else
        dolt_container_state="stopped"
      fi
      dolt_container_status_line="$(docker ps -a --filter "name=^${DOLT_CONTAINER_NAME}$" --format '{{.Status}}' 2>/dev/null | head -n 1 || true)"
    else
      dolt_container_state="missing"
    fi
  else
    dolt_container_state="docker-inaccessible"
    dolt_container_status_line="$(printf '%s\n' "${docker_ps_names_output}" | head -n 1)"
  fi
else
  dolt_container_state="docker-unavailable"
fi

if [[ "${dolt_mode}" == "server" ]]; then
  bd_dolt_show_output=""
  if command -v bd >/dev/null 2>&1; then
    if bd_dolt_show_output="$(bd dolt show 2>&1)"; then
      dolt_server_check="ok"
    else
      dolt_server_check="failed"
      dolt_server_error="$(printf '%s\n' "${bd_dolt_show_output}" | head -n 1)"
    fi
  else
    dolt_server_check="bd-unavailable"
  fi
else
  dolt_server_check="not-server-mode"
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

worktree_list=""
if ! worktree_list="$(git worktree list 2>/dev/null)"; then
  worktree_list=""
fi

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
    dirty_path_count="$(git -C "${worktree_path}" status --porcelain --untracked-files=normal 2>/dev/null | wc -l | tr -d '[:space:]')"
    if [[ "${dirty_path_count}" =~ ^[1-9][0-9]*$ ]]; then
      dirty_agent_worktree_count="$((dirty_agent_worktree_count + 1))"
      agent_name="$(basename "${worktree_path}")"
      dirty_agent_worktree_rows+="${agent_name}${FIELD_SEP}${worktree_path}${FIELD_SEP}${dirty_path_count}"$'\n'
    fi
  done <<< "${agent_worktree_paths}"
fi

main_dirty_count="$(git -C "${ROOT}" status --porcelain 2>/dev/null | wc -l | tr -d '[:space:]')"

metrics_summary_available=0
metrics_file_status="missing"
metrics_rollup=""
agent_activity_rows=""
attention_event_rows=""
recent_metrics_rows=""

total_runs=0
completed_runs=0
blocked_runs=0
failed_runs=0
no_work_runs=0
last_timestamp=""
last_result=""
last_issue=""
last_agent=""
last_reason=""
last_duration=""
last_tokens=""

if [[ ! -f "${METRICS_FILE}" ]]; then
  metrics_file_status="missing"
elif [[ ! -s "${METRICS_FILE}" ]]; then
  metrics_file_status="empty"
elif ! command -v jq >/dev/null 2>&1; then
  metrics_file_status="jq_unavailable"
else
  metrics_rollup="$(
    jq -r -s '
      . as $rows
      | if ($rows | length) == 0 then ""
        else
          ($rows[-1]) as $last
          | [
              ($rows | length),
              ($rows | map(select(.result == "completed")) | length),
              ($rows | map(select(.result == "blocked")) | length),
              ($rows | map(select(.result == "failed")) | length),
              ($rows | map(select(.result == "no_work")) | length),
              ($last.timestamp // ""),
              ($last.result // ""),
              ($last.issue_id // ""),
              ($last.agent_name // ""),
              ($last.reason // ""),
              (($last.durations_seconds.iteration_total // 0) | tostring),
              (if $last.tokens_used == null then "n/a" else ($last.tokens_used | tostring) end)
            ]
          | map(tostring)
          | join("\u001f")
        end
    ' "${METRICS_FILE}" 2>/dev/null || true
  )"

  if [[ -n "${metrics_rollup}" ]]; then
    metrics_summary_available=1
    metrics_file_status="ok"
    IFS="${FIELD_SEP}" read -r \
      total_runs \
      completed_runs \
      blocked_runs \
      failed_runs \
      no_work_runs \
      last_timestamp \
      last_result \
      last_issue \
      last_agent \
      last_reason \
      last_duration \
      last_tokens <<< "${metrics_rollup}"
  else
    metrics_file_status="parse_error"
  fi

  agent_activity_rows="$(
    jq -r -s '
      reduce .[] as $row ({}; .[$row.agent_name] = $row)
      | to_entries
      | sort_by(.key)
      | .[]
      | .value
      | [
          (.agent_name // "unknown-agent"),
          (.session_id // ""),
          (.timestamp // ""),
          (.result // ""),
          (.issue_id // ""),
          (.summary.issue_status // ""),
          ((.durations_seconds.iteration_total // 0) | tostring),
          (if .tokens_used == null then "n/a" else (.tokens_used | tostring) end),
          (.summary.loop_action // ""),
          (.summary.loop_action_reason // "")
        ]
      | map(tostring)
      | join("\u001f")
    ' "${METRICS_FILE}" 2>/dev/null || true
  )"

  attention_event_rows="$(
    jq -r '
      select((.result // "") != "completed" and (.result // "") != "no_work")
      | [
          (.timestamp // "unknown-time"),
          (.agent_name // "unknown-agent"),
          (.result // "unknown"),
          (.issue_id // "none"),
          (.summary.loop_action_reason // .reason // "unknown")
        ]
      | map(tostring)
      | join("\u001f")
    ' "${METRICS_FILE}" 2>/dev/null | tail -n "${ORCA_STATUS_RECENT_METRIC_LIMIT}" || true
  )"

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
          | map(tostring)
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

if [[ "${dolt_mode}" == "server" ]]; then
  if [[ "${dolt_container_state}" != "running" ]]; then
    add_alert "Dolt server container ${DOLT_CONTAINER_NAME} is ${dolt_container_state}."
  fi
  if [[ "${dolt_server_check}" == "failed" ]]; then
    add_alert "Beads server-mode connectivity check failed (${dolt_server_error})."
  fi
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
    issue_display="${last_issue:-none}"
    add_alert "Most recent run result is ${last_result} (issue=${issue_display}, agent=${last_agent:-unknown-agent})."
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
  echo "metrics rows: unavailable (${metrics_file_status})"
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
echo "== dolt database =="
echo "mode: ${dolt_mode}"
echo "database: ${dolt_database}"
if [[ "${dolt_mode}" == "server" ]]; then
  echo "server config: host=${dolt_host_cfg:-${DOLT_EXPECT_HOST}} port=${dolt_port_cfg:-${DOLT_EXPECT_PORT}} user=${dolt_user_cfg}"
  echo "docker container (${DOLT_CONTAINER_NAME}): ${dolt_container_state}${dolt_container_status_line:+ (${dolt_container_status_line})}"
  if [[ "${dolt_server_check}" == "ok" ]]; then
    echo "bd connectivity: OK"
  elif [[ "${dolt_server_check}" == "failed" ]]; then
    echo "bd connectivity: FAILED (${dolt_server_error})"
  elif [[ "${dolt_server_check}" == "bd-unavailable" ]]; then
    echo "bd connectivity: bd not installed"
  else
    echo "bd connectivity: ${dolt_server_check}"
  fi
else
  echo "server config: n/a (mode=${dolt_mode})"
fi

echo
echo "== agent activity =="
if [[ -n "${agent_activity_rows}" ]]; then
  while IFS="${FIELD_SEP}" read -r agent_name session_id timestamp result issue_id issue_status duration_s tokens loop_action loop_action_reason; do
    [[ -z "${agent_name}" ]] && continue

    mapped_session="$(session_name_for_agent "${agent_name}")"
    session_state="n/a"
    if [[ -n "${mapped_session}" ]]; then
      if session_is_up "${mapped_session}"; then
        session_state="up"
      else
        session_state="down"
      fi
    fi

    issue_display="${issue_id:-none}"
    issue_status_display="${issue_status:-n/a}"
    loop_display="${loop_action:-n/a}"
    note_display=""
    if [[ -n "${loop_action_reason}" ]]; then
      note_display=" note=$(truncate_text "${loop_action_reason}" 96)"
    fi

    echo "- ${agent_name}: session=${session_state} result=${result:-unknown} issue=${issue_display} issue_status=${issue_status_display} age=$(format_age_from_timestamp "${timestamp}") duration=$(format_seconds_short "${duration_s}") tokens=${tokens} loop=${loop_display}${note_display}"
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
echo "== attention events (latest ${ORCA_STATUS_RECENT_METRIC_LIMIT}) =="
if [[ -n "${attention_event_rows}" ]]; then
  while IFS="${FIELD_SEP}" read -r timestamp agent_name result issue_id reason; do
    [[ -z "${timestamp}" ]] && continue
    echo "- ${timestamp} agent=${agent_name} result=${result} issue=${issue_id} reason=$(truncate_text "${reason}" 110)"
  done <<< "${attention_event_rows}"
else
  echo "(none)"
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
echo "== currently claimed beads =="
if command -v bd >/dev/null 2>&1; then
  if claimed_beads_output="$(
    bd list --status in_progress --sort updated --reverse --limit "${ORCA_STATUS_CLAIMED_LIMIT}" 2>&1
  )"; then
    if [[ -n "${claimed_beads_output}" ]]; then
      printf '%s\n' "${claimed_beads_output}"
    else
      echo "(none)"
    fi
  else
    printf '%s\n' "${claimed_beads_output}" >&2
    echo "(bd list --status in_progress failed)" >&2
  fi
else
  echo "(bd not installed)"
fi

echo
echo "== recently closed beads =="
if command -v bd >/dev/null 2>&1; then
  safe_run "bd list --status closed" bd list --status closed --limit "${ORCA_STATUS_CLOSED_LIMIT}" || true
else
  echo "(bd not installed)"
fi

echo
echo "== bd status =="
if command -v bd >/dev/null 2>&1; then
  safe_run "bd status" bd status || true
else
  echo "(bd not installed)"
fi

echo
echo "== latest metrics =="
if [[ -f "${METRICS_FILE}" ]]; then
  if [[ -n "${recent_metrics_rows}" ]]; then
    while IFS="${FIELD_SEP}" read -r timestamp agent_name issue_id result reason duration_s tokens; do
      [[ -z "${timestamp}" ]] && continue
      echo "${timestamp} ($(format_age_from_timestamp "${timestamp}")) agent=${agent_name} issue=${issue_id} result=${result} reason=${reason} total=$(format_seconds_short "${duration_s}") tokens=${tokens}"
    done <<< "${recent_metrics_rows}"
  elif command -v jq >/dev/null 2>&1; then
    if ! tail -n "${ORCA_STATUS_RECENT_METRIC_LIMIT}" "${METRICS_FILE}" | jq -r '
      . as $row
      | ($row.timestamp // "unknown-time")
        + " agent=" + ($row.agent_name // "unknown-agent")
        + " issue=" + ($row.issue_id // "unknown-issue")
        + " result=" + ($row.result // "unknown")
        + " reason=" + ($row.reason // "unknown")
        + " total_s=" + (($row.durations_seconds.iteration_total // 0) | tostring)
        + " tokens=" + (
            if $row.tokens_used == null then "n/a"
            else ($row.tokens_used | tostring) end
          )
    '; then
      echo "(metrics parse failed)"
    fi
  else
    tail -n "${ORCA_STATUS_RECENT_METRIC_LIMIT}" "${METRICS_FILE}"
  fi
else
  echo "(no metrics yet)"
fi
