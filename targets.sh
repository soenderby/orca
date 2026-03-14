#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SESSION_PREFIX="${SESSION_PREFIX:-orca-agent}"
SESSION_LOG_ROOT="${ROOT}/agent-logs/sessions"

# shellcheck source=/dev/null
source "${ROOT}/lib/observed-registry.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/tmux-target.sh"

EXIT_SUCCESS=0
EXIT_FAILURE=3
EXIT_INVALID=4

OUTPUT_JSON=0
SESSION_FILTER_ID=""
SESSION_FILTER_PREFIX=""

usage() {
  cat <<'USAGE'
Usage:
  ./orca.sh targets [--json] [--session-id ID] [--session-prefix PREFIX]
  ./targets.sh [--json] [--session-id ID] [--session-prefix PREFIX]

Options:
  --json                  Emit machine-readable target inventory JSON array
  --session-id ID         Filter inventory to exact session id
  --session-prefix TEXT   Filter inventory to session ids with this prefix

Fields:
  id           Stable target id with mode namespace (`managed:*`, `observed:*`)
  mode         `managed` or `observed`
  tmux_target  tmux session/window target string when known
  active       true when currently reachable in tmux
  session_id   Canonical session identity (managed session id or observed registry id)

Exit codes:
  0  success
  3  operational failure
  4  invalid usage/config
USAGE
}

invalid() {
  echo "targets: $*" >&2
  exit "${EXIT_INVALID}"
}

fail() {
  echo "targets: $*" >&2
  exit "${EXIT_FAILURE}"
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

resolve_session_dir_for_tmux_session() {
  local tmux_session="$1"

  if [[ ! -d "${SESSION_LOG_ROOT}" ]]; then
    return 1
  fi

  find "${SESSION_LOG_ROOT}" -mindepth 1 -maxdepth 4 -type d \
    \( -name "${tmux_session}" -o -name "${tmux_session}-*" \) \
    2>/dev/null | sort | tail -n 1
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

managed_tmux_target_from_session_id() {
  local session_id="${1:-}"

  if [[ "${session_id}" =~ ^(.+)-[0-9]{8}T[0-9]{6}Z$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  printf '%s\n' ""
}

collect_managed_targets_json() {
  local tmux_sessions=""
  local tmux_session=""
  local session_dir=""
  local session_id=""
  local all_session_ids=""
  local tmux_target=""
  local active=false
  local row=""
  local row_lines=""

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

    active=false
    if [[ -n "${active_sessions[${session_id}]:-}" ]]; then
      active=true
    fi

    tmux_target="${tmux_session_by_session_id[${session_id}]:-}"
    if [[ -z "${tmux_target}" ]]; then
      tmux_target="$(managed_tmux_target_from_session_id "${session_id}")"
    fi

    row="$(
      jq -nc \
        --arg id "${session_id}" \
        --arg session_id "${session_id}" \
        --arg tmux_target "${tmux_target}" \
        --argjson active "${active}" \
        '{
          id: ("managed:" + $id),
          mode: "managed",
          tmux_target: (if $tmux_target == "" then null else $tmux_target end),
          active: $active,
          session_id: $session_id
        }'
    )"

    if [[ -n "${row_lines}" ]]; then
      row_lines+=$'\n'
    fi
    row_lines+="${row}"
  done <<< "${all_session_ids}"

  if [[ -z "${row_lines}" ]]; then
    printf '[]\n'
    return 0
  fi

  printf '%s\n' "${row_lines}" | jq -s -c 'sort_by(.id)'
}

observed_target_active_json() {
  local tmux_target="$1"

  if ! orca_tmux_target_validate "${tmux_target}" >/dev/null 2>&1; then
    fail "invalid observed tmux_target in registry: ${tmux_target}"
  fi

  if ! command -v tmux >/dev/null 2>&1; then
    printf 'false\n'
    return 0
  fi

  if orca_tmux_target_exists "${tmux_target}" >/dev/null 2>&1; then
    printf 'true\n'
    return 0
  fi

  printf 'false\n'
}

collect_observed_targets_json() {
  local entries=""
  local entry=""
  local observed_id=""
  local session_id=""
  local tmux_target=""
  local active_json=""
  local row=""
  local row_lines=""

  if ! entries="$(orca_observed_registry_list)"; then
    fail "failed to read observed registry"
  fi

  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    observed_id="$(jq -r '.id // ""' <<< "${entry}")"
    tmux_target="$(jq -r '.tmux_target // ""' <<< "${entry}")"
    session_id="${observed_id}"

    if ! session_matches_filter "${session_id}"; then
      continue
    fi

    active_json="$(observed_target_active_json "${tmux_target}")"

    row="$(
      jq -nc \
        --arg id "${observed_id}" \
        --arg session_id "${session_id}" \
        --arg tmux_target "${tmux_target}" \
        --argjson active "${active_json}" \
        '{
          id: ("observed:" + $id),
          mode: "observed",
          tmux_target: (if $tmux_target == "" then null else $tmux_target end),
          active: $active,
          session_id: $session_id
        }'
    )"

    if [[ -n "${row_lines}" ]]; then
      row_lines+=$'\n'
    fi
    row_lines+="${row}"
  done < <(jq -c '.[]' <<< "${entries}")

  if [[ -z "${row_lines}" ]]; then
    printf '[]\n'
    return 0
  fi

  printf '%s\n' "${row_lines}" | jq -s -c 'sort_by(.id)'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      OUTPUT_JSON=1
      ;;
    --session-id)
      if [[ $# -lt 2 ]]; then
        invalid "missing value for --session-id"
      fi
      SESSION_FILTER_ID="$2"
      shift
      ;;
    --session-prefix)
      if [[ $# -lt 2 ]]; then
        invalid "missing value for --session-prefix"
      fi
      SESSION_FILTER_PREFIX="$2"
      shift
      ;;
    -h|--help)
      usage
      exit "${EXIT_SUCCESS}"
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

managed_targets_json="$(collect_managed_targets_json)"
observed_targets_json="$(collect_observed_targets_json)"

inventory_json="$(
  jq -sc '
    add
    | sort_by(.mode, .id, (.tmux_target // ""), (.session_id // ""))
  ' <(printf '%s\n' "${managed_targets_json}") <(printf '%s\n' "${observed_targets_json}")
)"

if [[ "${OUTPUT_JSON}" -eq 1 ]]; then
  printf '%s\n' "${inventory_json}"
  exit "${EXIT_SUCCESS}"
fi

if [[ "$(jq -r 'length' <<< "${inventory_json}")" -eq 0 ]]; then
  echo "No switchable targets found."
  exit "${EXIT_SUCCESS}"
fi

jq -r '
  (["ID","MODE","TMUX_TARGET","ACTIVE","SESSION_ID"] | @tsv),
  (.[] | [.id, .mode, (.tmux_target // "-"), (.active | tostring), (.session_id // "-")] | @tsv)
' <<< "${inventory_json}"
