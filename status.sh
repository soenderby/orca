#!/usr/bin/env bash
set -euo pipefail

# Minimal batch-engine status: what sessions exist, their state, last result.

ROOT="$(git rev-parse --show-toplevel)"
SESSION_PREFIX="${SESSION_PREFIX:-orca-agent}"
METRICS_FILE="${ROOT}/agent-logs/metrics.jsonl"
SESSION_LOG_ROOT="${ROOT}/agent-logs/sessions"
OUTPUT_JSON=0

usage() {
  cat <<USAGE
Usage:
  status [--json]

Reports active orca sessions, their run state, and last result per session.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) OUTPUT_JSON=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "status: unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- data collection ---

tmux_available=0
tmux_sessions=""
if command -v tmux >/dev/null 2>&1; then
  tmux_available=1
  tmux_sessions="$(tmux ls -F '#S' 2>/dev/null | grep "^${SESSION_PREFIX}" || true)"
fi

tmux_count=0
if [[ -n "${tmux_sessions}" ]]; then
  tmux_count="$(printf '%s\n' "${tmux_sessions}" | wc -l | tr -d '[:space:]')"
fi

br_version="unavailable"
br_workspace=0
ready_count=0
in_progress_count=0
if command -v br >/dev/null 2>&1; then
  br_version="$(br --version 2>&1 | head -n 1)"
  if [[ -d "${ROOT}/.beads" ]]; then
    br_workspace=1
    ready_count="$(br ready --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
    in_progress_count="$(br list --status in_progress --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  fi
fi

# Per-session state from run artifacts
resolve_session_state() {
  local tmux_session="$1"
  local session_id=""
  local agent_name=""
  local state="unknown"
  local last_result=""
  local last_issue=""
  local run_dir=""
  local summary_file=""

  # Find session dir by scanning today and recent dates
  local session_dir=""
  local date_dir
  for date_dir in $(ls -d "${SESSION_LOG_ROOT}"/????/??/?? 2>/dev/null | sort -r | head -7); do
    local candidate
    for candidate in "${date_dir}"/${tmux_session}*/; do
      if [[ -d "${candidate}" ]]; then
        session_dir="${candidate%/}"
        break 2
      fi
    done
  done

  if [[ -n "${session_dir}" ]]; then
    session_id="$(basename "${session_dir}")"
    # Extract agent name from session id (e.g., orca-agent-1-20260320T... -> agent-1)
    agent_name="$(echo "${session_id}" | sed "s/^${SESSION_PREFIX}-//" | sed 's/-[0-9]\{8\}T[0-9]\{6\}Z$//')"
  fi

  # Check if tmux session is still alive
  if printf '%s\n' "${tmux_sessions}" | grep -qx "${tmux_session}" 2>/dev/null; then
    state="running"
  else
    state="finished"
  fi

  # Find latest run summary
  if [[ -n "${session_dir}" ]]; then
    run_dir="$(ls -d "${session_dir}"/runs/*/ 2>/dev/null | sort -r | head -1)"
    if [[ -n "${run_dir}" ]]; then
      summary_file="${run_dir}summary.json"
      if [[ -f "${summary_file}" ]]; then
        last_result="$(jq -r '.result // ""' "${summary_file}" 2>/dev/null || true)"
        last_issue="$(jq -r '.issue_id // ""' "${summary_file}" 2>/dev/null || true)"
        # Refine state: if tmux is alive but summary exists, check if run is still going
        if [[ "${state}" == "running" ]]; then
          local run_log="${run_dir}run.log"
          # If summary.json exists, the run is complete; agent-loop may be between runs or stopped
          state="running"
        fi
      fi
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "${tmux_session}" "${session_id}" "${agent_name}" "${state}" "${last_result}" "${last_issue}"
}

# Collect session data
session_rows=""
all_session_ids=""

# From live tmux sessions
if [[ -n "${tmux_sessions}" ]]; then
  while IFS= read -r s; do
    row="$(resolve_session_state "${s}")"
    session_rows="${session_rows:+${session_rows}
}${row}"
  done <<< "${tmux_sessions}"
fi

# Latest metrics entry
latest_agent=""
latest_result=""
latest_issue=""
latest_duration=""
latest_tokens=""
latest_age=""
if [[ -f "${METRICS_FILE}" && -s "${METRICS_FILE}" ]] && command -v jq >/dev/null 2>&1; then
  eval "$(tail -1 "${METRICS_FILE}" | jq -r '
    "latest_agent=\(.agent_name // "")",
    "latest_result=\(.result // "")",
    "latest_issue=\(.issue_id // "")",
    "latest_duration=\((.durations_seconds.iteration_total // 0) | tostring)",
    "latest_tokens=\((.tokens_used // 0) | tostring)"
  ' 2>/dev/null || true)"
  if [[ -n "${latest_result}" ]]; then
    local_ts="$(tail -1 "${METRICS_FILE}" | jq -r '.timestamp // ""' 2>/dev/null || true)"
    if [[ -n "${local_ts}" ]]; then
      epoch="$(date -d "${local_ts}" +%s 2>/dev/null || true)"
      if [[ -n "${epoch}" ]]; then
        age_s="$(( $(date +%s) - epoch ))"
        if (( age_s < 60 )); then
          latest_age="${age_s}s ago"
        elif (( age_s < 3600 )); then
          latest_age="$(( age_s / 60 ))m ago"
        elif (( age_s < 86400 )); then
          latest_age="$(( age_s / 3600 ))h ago"
        else
          latest_age="$(( age_s / 86400 ))d ago"
        fi
      fi
    fi
  fi
fi

# --- output ---

if [[ "${OUTPUT_JSON}" -eq 1 ]]; then
  sessions_json="[]"
  if [[ -n "${session_rows}" ]]; then
    sessions_json="$(printf '%s\n' "${session_rows}" | jq -R -s -c '
      split("\n") | map(select(length > 0)) | map(split("\t")) |
      map({
        tmux_session: .[0],
        session_id: (if .[1] == "" then null else .[1] end),
        agent_name: (if .[2] == "" then null else .[2] end),
        state: .[3],
        last_result: (if .[4] == "" then null else .[4] end),
        last_issue: (if .[5] == "" then null else .[5] end)
      })
    ')"
  fi

  jq -nc \
    --arg generated_at "$(date -Iseconds)" \
    --argjson sessions_total "${tmux_count}" \
    --arg br_version "${br_version}" \
    --argjson br_workspace "${br_workspace}" \
    --argjson ready_count "${ready_count}" \
    --argjson in_progress_count "${in_progress_count}" \
    --argjson sessions "${sessions_json}" \
    --arg latest_agent "${latest_agent}" \
    --arg latest_result "${latest_result}" \
    --arg latest_issue "${latest_issue}" \
    --arg latest_duration "${latest_duration}" \
    --arg latest_tokens "${latest_tokens}" \
    --arg latest_age "${latest_age}" \
    '{
      generated_at: $generated_at,
      active_sessions: $sessions_total,
      queue: { ready: $ready_count, in_progress: $in_progress_count },
      br: { version: $br_version, workspace: ($br_workspace == 1) },
      sessions: $sessions,
      latest: {
        agent: (if $latest_agent == "" then null else $latest_agent end),
        result: (if $latest_result == "" then null else $latest_result end),
        issue: (if $latest_issue == "" then null else $latest_issue end),
        duration: (if $latest_duration == "" then null else $latest_duration end),
        tokens: (if $latest_tokens == "" then null else $latest_tokens end),
        age: (if $latest_age == "" then null else $latest_age end)
      }
    }'
  exit 0
fi

# Human-readable output
echo "== orca status =="
echo "active sessions: ${tmux_count}"
echo "queue: ${ready_count} ready, ${in_progress_count} in progress"
if [[ -n "${latest_result}" ]]; then
  echo "latest: agent=${latest_agent} result=${latest_result} issue=${latest_issue} duration=${latest_duration}s tokens=${latest_tokens} ${latest_age}"
fi
echo ""

if [[ -n "${session_rows}" ]]; then
  echo "== sessions =="
  printf '%s\n' "${session_rows}" | while IFS=$'\t' read -r tmux_s sid aname st res iss; do
    line="- ${tmux_s}: state=${st}"
    [[ -n "${res}" ]] && line="${line} result=${res}"
    [[ -n "${iss}" ]] && line="${line} issue=${iss}"
    echo "${line}"
  done
  echo ""
fi

if [[ "${tmux_count}" -eq 0 ]]; then
  echo "(no active orca sessions)"
fi
