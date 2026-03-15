#!/usr/bin/env bash

orca_follow_render_mode_valid() {
  local mode="${1:-}"
  [[ "${mode}" == "jsonl" || "${mode}" == "structured" ]]
}

orca_follow_render_line() {
  local event_line="${1:-}"
  local render_mode="${2:-jsonl}"
  local event_fields_json=""
  local timestamp=""
  local mode=""
  local event_type=""
  local session_id=""
  local run_id=""
  local target=""

  if [[ "${render_mode}" == "jsonl" ]]; then
    printf '%s\n' "${event_line}"
    return 0
  fi

  event_fields_json="$(
    jq -c '
      {
        timestamp: (.observed_at // ""),
        mode: (.mode // ""),
        event_type: (.event_type // ""),
        session_id: (.session_id // ""),
        run_id: (.run.run_id // ""),
        target: (.tmux_target // .session.tmux_target // "")
      }
    ' <<<"${event_line}" 2>/dev/null || true
  )"

  if [[ -z "${event_fields_json}" ]]; then
    printf '%s\n' "${event_line}"
    return 0
  fi

  timestamp="$(jq -r '.timestamp' <<<"${event_fields_json}" 2>/dev/null || true)"
  mode="$(jq -r '.mode' <<<"${event_fields_json}" 2>/dev/null || true)"
  event_type="$(jq -r '.event_type' <<<"${event_fields_json}" 2>/dev/null || true)"
  session_id="$(jq -r '.session_id' <<<"${event_fields_json}" 2>/dev/null || true)"
  run_id="$(jq -r '.run_id' <<<"${event_fields_json}" 2>/dev/null || true)"
  target="$(jq -r '.target' <<<"${event_fields_json}" 2>/dev/null || true)"

  if [[ -z "${timestamp}" ]]; then
    timestamp="unknown-time"
  fi
  if [[ -z "${mode}" ]]; then
    mode="unknown"
  fi
  if [[ -z "${event_type}" ]]; then
    event_type="unknown"
  fi
  if [[ -z "${session_id}" ]]; then
    session_id="unknown"
  fi
  if [[ -z "${target}" ]]; then
    target="none"
  fi

  if [[ -n "${run_id}" ]]; then
    printf '%s\n' "${timestamp} mode=${mode} event_type=${event_type} session_id=${session_id} run_id=${run_id} target=${target}"
  else
    printf '%s\n' "${timestamp} mode=${mode} event_type=${event_type} session_id=${session_id} target=${target}"
  fi
}
