#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"

# shellcheck source=/dev/null
source "${ROOT}/lib/observed-registry.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/tmux-target.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/follow-render.sh"

EXIT_SUCCESS=0
EXIT_FAILURE=3
EXIT_INVALID=4

usage() {
  cat <<'USAGE'
Usage:
  ./orca.sh follow [--poll-interval SECONDS] [--max-events N]
  ./follow.sh [--poll-interval SECONDS] [--max-events N]

Description:
  Emit merged managed+observed live events from now onward.
  Output is append-only, human-readable structured lines.

Options:
  --poll-interval N  Poll interval in seconds for observed targets (default: 5)
  --max-events N     Stop after N emitted events (default: 0 = unbounded)

Notes:
  Removed options rejected in follow context: --replay-baseline, --session-id,
  --session-prefix, --render.

Exit codes:
  0  success
  3  operational failure
  4  invalid usage/config
USAGE
}

invalid() {
  echo "follow: $*" >&2
  exit "${EXIT_INVALID}"
}

fail() {
  echo "follow: $*" >&2
  exit "${EXIT_FAILURE}"
}

is_non_negative_int() {
  local value="${1:-}"
  [[ "${value}" =~ ^[0-9]+$ ]]
}

is_positive_int() {
  local value="${1:-}"
  [[ "${value}" =~ ^[1-9][0-9]*$ ]]
}

FOLLOW_POLL_INTERVAL_SECONDS=5
FOLLOW_MAX_EVENTS=0
FOLLOW_INTERRUPTED=0
MANAGED_FOLLOW_PID=""
MANAGED_FOLLOW_FD=""
MANAGED_LAST_EVENT_LINE=""

reject_removed_option() {
  local opt="$1"
  invalid "${opt} is no longer supported; follow is live-from-now and unfiltered"
}

tmux_follow_health_probe() {
  local probe_output=""
  local probe_rc=0

  set +e
  probe_output="$(tmux start-server 2>&1)"
  probe_rc=$?
  set -e

  if [[ "${probe_rc}" -ne 0 ]]; then
    if [[ -n "${probe_output}" ]]; then
      echo "${probe_output}" >&2
    fi
    return 1
  fi

  return 0
}

tmux_follow_target_exists() {
  local target="${1:-}"
  local parsed=""
  local kind=""
  local session=""
  local window=""
  local cmd_output=""
  local cmd_rc=0
  local windows_output=""

  parsed="$(_orca_tmux_target_parse_components "${target}")" || return 2
  IFS=$'\t' read -r kind session window <<<"${parsed}"

  set +e
  cmd_output="$(tmux has-session -t "${session}" 2>&1)"
  cmd_rc=$?
  set -e
  if [[ "${cmd_rc}" -eq 0 ]]; then
    :
  elif [[ "${cmd_rc}" -eq 1 ]]; then
    if [[ -z "${cmd_output}" || "${cmd_output}" == *"can't find session"* ]]; then
      return 1
    fi
    if [[ -n "${cmd_output}" ]]; then
      echo "${cmd_output}" >&2
    fi
    return 2
  else
    if [[ -n "${cmd_output}" ]]; then
      echo "${cmd_output}" >&2
    fi
    return 2
  fi

  if [[ "${kind}" == "session" ]]; then
    return 0
  fi

  set +e
  windows_output="$(tmux list-windows -F '#W' -t "${session}" 2>&1)"
  cmd_rc=$?
  set -e
  if [[ "${cmd_rc}" -ne 0 ]]; then
    if [[ "${cmd_rc}" -eq 1 ]]; then
      if [[ -z "${windows_output}" || "${windows_output}" == *"can't find session"* ]]; then
        return 1
      fi
      if [[ -n "${windows_output}" ]]; then
        echo "${windows_output}" >&2
      fi
      return 2
    fi
    if [[ -n "${windows_output}" ]]; then
      echo "${windows_output}" >&2
    fi
    return 2
  fi

  if grep -Fx -- "${window}" <<<"${windows_output}" >/dev/null; then
    return 0
  fi

  return 1
}

collect_observed_follow_snapshot_json() {
  local entries_json=""
  local entry_json=""
  local session_id=""
  local tmux_target=""
  local lifecycle=""
  local active=false
  local row_json=""
  local rows_json="[]"
  local observed_at=""
  local target_probe_rc=0

  if ! entries_json="$(orca_observed_registry_list)"; then
    fail "failed to read observed registry"
  fi

  if ! tmux_follow_health_probe; then
    fail "tmux health probe failed during follow"
  fi

  while IFS= read -r entry_json; do
    [[ -n "${entry_json}" ]] || continue

    session_id="$(jq -r '.id' <<<"${entry_json}")"
    tmux_target="$(jq -r '.tmux_target' <<<"${entry_json}")"
    lifecycle="$(jq -r '.lifecycle // ""' <<<"${entry_json}")"
    active=false
    if tmux_follow_target_exists "${tmux_target}"; then
      active=true
    else
      target_probe_rc=$?
      if [[ "${target_probe_rc}" -ne 1 ]]; then
        fail "tmux target probe failed during follow: ${tmux_target}"
      fi
    fi
    observed_at="$(date -Iseconds)"

    row_json="$(
      jq -cn \
        --arg session_id "${session_id}" \
        --arg tmux_target "${tmux_target}" \
        --arg lifecycle "${lifecycle}" \
        --arg observed_at "${observed_at}" \
        --argjson active "${active}" \
        '{
          session_id: $session_id,
          tmux_target: $tmux_target,
          lifecycle: (if $lifecycle == "" then null else $lifecycle end),
          active: $active,
          observed_at: $observed_at
        }'
    )"
    rows_json="$(jq -c --argjson row "${row_json}" '. + [$row]' <<<"${rows_json}")"
  done < <(jq -c '.[]' <<<"${entries_json}")

  printf '%s\n' "${rows_json}" | jq -c 'sort_by(.session_id)'
}

emit_observed_follow_events_jsonl() {
  local previous_snapshot_json="$1"
  local current_snapshot_json="$2"

  jq -crs \
    --arg observed_at "$(date -Iseconds)" \
    '
      def index_by_session($arr):
        reduce $arr[] as $row ({}; .[$row.session_id] = $row);
      def emit($type; $session_id; $context; $active):
        {
          schema_version: "orca.monitor.v2",
          observed_at: $observed_at,
          event_type: $type,
          event_id: ($type + ":" + $session_id),
          session_id: $session_id,
          mode: "observed",
          lifecycle: ($context.lifecycle // null),
          tmux_target: ($context.tmux_target // null),
          session: {
            session_id: $session_id,
            tmux_target: ($context.tmux_target // null),
            lifecycle: ($context.lifecycle // null),
            active: $active
          }
        };

      index_by_session(.[0]) as $prev
      | index_by_session(.[1]) as $curr
      | ($prev + $curr | keys_unsorted | unique | sort) as $session_ids
      | [
          $session_ids[] as $sid
          | ($prev[$sid] // null) as $p
          | ($curr[$sid] // null) as $c
          | (
              if ($c != null and ($c.active == true) and (($p == null) or ($p.active != true))) then
                [emit("session_up"; $sid; $c; true)]
              else
                []
              end
            )
          + (
              if ($p != null and ($p.active == true) and (($c == null) or ($c.active != true))) then
                [emit("session_down"; $sid; ($c // $p); false)]
              else
                []
              end
            )
        ]
      | flatten
      | .[]
    ' <(printf '%s\n' "${previous_snapshot_json}") <(printf '%s\n' "${current_snapshot_json}")
}

start_managed_follow_stream() {
  local -a cmd=(bash "${ROOT}/status.sh" --follow --poll-interval "${FOLLOW_POLL_INTERVAL_SECONDS}" --max-events 0)

  exec {MANAGED_FOLLOW_FD}< <("${cmd[@]}")
  MANAGED_FOLLOW_PID="$!"
}

stop_managed_follow_stream() {
  local managed_exit_code=0
  local wait_attempt=0

  if [[ -n "${MANAGED_FOLLOW_FD}" ]]; then
    exec {MANAGED_FOLLOW_FD}<&-
    MANAGED_FOLLOW_FD=""
  fi

  if [[ -n "${MANAGED_FOLLOW_PID}" ]]; then
    if kill -0 "${MANAGED_FOLLOW_PID}" >/dev/null 2>&1; then
      kill "${MANAGED_FOLLOW_PID}" >/dev/null 2>&1 || true
      while kill -0 "${MANAGED_FOLLOW_PID}" >/dev/null 2>&1; do
        wait_attempt=$((wait_attempt + 1))
        if [[ "${wait_attempt}" -ge 20 ]]; then
          kill -9 "${MANAGED_FOLLOW_PID}" >/dev/null 2>&1 || true
          break
        fi
        sleep 0.1
      done
    fi
    set +e
    wait "${MANAGED_FOLLOW_PID}" >/dev/null 2>&1
    managed_exit_code=$?
    set -e
    MANAGED_FOLLOW_PID=""
  fi

  return "${managed_exit_code}"
}

emit_managed_follow_event_if_new() {
  local managed_event_line="$1"
  local rendered_line=""

  # Suppress exact duplicate line replay; do not globally dedupe by event_id.
  if [[ -n "${MANAGED_LAST_EVENT_LINE}" && "${managed_event_line}" == "${MANAGED_LAST_EVENT_LINE}" ]]; then
    return 1
  fi

  MANAGED_LAST_EVENT_LINE="${managed_event_line}"
  rendered_line="$(orca_follow_render_line "${managed_event_line}" structured)"
  printf '%s\n' "${rendered_line}"
  return 0
}

run_follow() {
  local previous_observed_snapshot_json="[]"
  local current_observed_snapshot_json=""
  local observed_event_lines=""
  local observed_event_line=""
  local managed_event_line=""
  local managed_read_rc=0
  local managed_exit_code=0
  local emitted=0
  local stop_requested=0
  local now_epoch=0
  local next_observed_poll_epoch=0

  MANAGED_LAST_EVENT_LINE=""

  if ! is_positive_int "${FOLLOW_POLL_INTERVAL_SECONDS}"; then
    invalid "--poll-interval must be a positive integer"
  fi
  if ! is_non_negative_int "${FOLLOW_MAX_EVENTS}"; then
    invalid "--max-events must be a non-negative integer"
  fi
  if ! command -v tmux >/dev/null 2>&1; then
    fail "tmux is required for follow"
  fi
  if ! tmux_follow_health_probe; then
    fail "tmux health probe failed for follow"
  fi

  previous_observed_snapshot_json="$(collect_observed_follow_snapshot_json)"

  start_managed_follow_stream
  trap 'FOLLOW_INTERRUPTED=1' INT TERM
  trap 'stop_managed_follow_stream >/dev/null 2>&1 || true' EXIT

  while true; do
    if [[ "${FOLLOW_INTERRUPTED}" -eq 1 ]]; then
      break
    fi

    now_epoch="$(date +%s)"
    if [[ "${next_observed_poll_epoch}" -eq 0 || "${now_epoch}" -ge "${next_observed_poll_epoch}" ]]; then
      current_observed_snapshot_json="$(collect_observed_follow_snapshot_json)"
      observed_event_lines="$(emit_observed_follow_events_jsonl "${previous_observed_snapshot_json}" "${current_observed_snapshot_json}")"
      if [[ -n "${observed_event_lines}" ]]; then
        while IFS= read -r observed_event_line; do
          [[ -n "${observed_event_line}" ]] || continue
          printf '%s\n' "$(orca_follow_render_line "${observed_event_line}" structured)"
          emitted=$((emitted + 1))
          if [[ "${FOLLOW_MAX_EVENTS}" -gt 0 && "${emitted}" -ge "${FOLLOW_MAX_EVENTS}" ]]; then
            stop_requested=1
            break
          fi
        done <<< "${observed_event_lines}"
        if [[ "${stop_requested}" -eq 1 ]]; then
          break
        fi
      fi
      previous_observed_snapshot_json="${current_observed_snapshot_json}"
      next_observed_poll_epoch=$((now_epoch + FOLLOW_POLL_INTERVAL_SECONDS))
    fi

    if IFS= read -r -t 0.2 -u "${MANAGED_FOLLOW_FD}" managed_event_line; then
      [[ -n "${managed_event_line}" ]] || continue
      if emit_managed_follow_event_if_new "${managed_event_line}"; then
        emitted=$((emitted + 1))
      fi
      if [[ "${FOLLOW_MAX_EVENTS}" -gt 0 && "${emitted}" -ge "${FOLLOW_MAX_EVENTS}" ]]; then
        break
      fi
      while IFS= read -r -t 0.01 -u "${MANAGED_FOLLOW_FD}" managed_event_line; do
        [[ -n "${managed_event_line}" ]] || continue
        if emit_managed_follow_event_if_new "${managed_event_line}"; then
          emitted=$((emitted + 1))
        fi
        if [[ "${FOLLOW_MAX_EVENTS}" -gt 0 && "${emitted}" -ge "${FOLLOW_MAX_EVENTS}" ]]; then
          stop_requested=1
          break
        fi
      done
      if [[ "${stop_requested}" -eq 1 ]]; then
        break
      fi
      continue
    else
      managed_read_rc=$?
      if [[ "${managed_read_rc}" -ne 142 && "${managed_read_rc}" -ne 1 ]]; then
        stop_managed_follow_stream >/dev/null 2>&1 || true
        fail "failed to read managed follow stream"
      fi

      if [[ "${managed_read_rc}" -eq 1 ]] && ! kill -0 "${MANAGED_FOLLOW_PID}" >/dev/null 2>&1; then
        set +e
        wait "${MANAGED_FOLLOW_PID}" >/dev/null 2>&1
        managed_exit_code=$?
        set -e
        MANAGED_FOLLOW_PID=""
        if [[ "${managed_exit_code}" -eq 0 ]]; then
          fail "managed follow stream exited unexpectedly"
        fi
        fail "managed follow stream failed with exit code ${managed_exit_code}"
      fi
    fi
  done

  trap - INT TERM EXIT
  stop_managed_follow_stream >/dev/null 2>&1 || true

  if [[ "${FOLLOW_INTERRUPTED}" -eq 1 ]]; then
    return 0
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  invalid "jq is required"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --poll-interval)
      [[ $# -ge 2 ]] || invalid "missing value for --poll-interval"
      FOLLOW_POLL_INTERVAL_SECONDS="$2"
      shift
      ;;
    --max-events)
      [[ $# -ge 2 ]] || invalid "missing value for --max-events"
      FOLLOW_MAX_EVENTS="$2"
      shift
      ;;
    --replay-baseline|--session-id|--session-prefix|--render)
      reject_removed_option "$1"
      ;;
    -h|--help)
      usage
      exit "${EXIT_SUCCESS}"
      ;;
    *)
      invalid "unknown option for follow: $1"
      ;;
  esac
  shift
done

run_follow
