#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"

# shellcheck source=/dev/null
source "${ROOT}/lib/observed-registry.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/tmux-target.sh"

EXIT_SUCCESS=0
EXIT_FAILURE=3
EXIT_INVALID=4

usage() {
  cat <<'USAGE'
Usage:
  ./orca.sh observe add --id AGENT_ID --lifecycle LIFECYCLE --tmux-target TARGET [--cwd PATH]
  ./orca.sh observe remove --id AGENT_ID
  ./orca.sh observe list [--json]
  ./orca.sh observe start --id AGENT_ID --lifecycle LIFECYCLE --tmux-target TARGET --cwd PATH -- <command...>
  ./observe.sh add --id AGENT_ID --lifecycle LIFECYCLE --tmux-target TARGET [--cwd PATH]
  ./observe.sh remove --id AGENT_ID
  ./observe.sh list [--json]
  ./observe.sh start --id AGENT_ID --lifecycle LIFECYCLE --tmux-target TARGET --cwd PATH -- <command...>

Commands:
  add    Register an existing tmux target in observed registry
  remove Remove observed registry entry by id
  list   Print observed registry entries
  start  Create detached tmux target and register it as observed

Exit codes:
  0  success
  3  operational failure
  4  invalid usage/config
USAGE
}

invalid() {
  echo "observe: $*" >&2
  exit "${EXIT_INVALID}"
}

fail() {
  echo "observe: $*" >&2
  exit "${EXIT_FAILURE}"
}

is_valid_agent_id() {
  local value="${1:-}"
  [[ "${value}" =~ ^[A-Za-z0-9._:-]+$ ]]
}

is_valid_lifecycle() {
  local value="${1:-}"
  [[ "${value}" == "ephemeral" || "${value}" == "persistent" ]]
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

command_to_string() {
  local cmd=("$@")
  local result=""
  if [[ "${#cmd[@]}" -eq 0 ]]; then
    echo ""
    return 0
  fi
  printf -v result '%q ' "${cmd[@]}"
  result="${result% }"
  printf '%s\n' "${result}"
}

cmd_add() {
  local id=""
  local lifecycle=""
  local tmux_target=""
  local cwd=""
  local entry_json=""
  local added=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)
        [[ $# -ge 2 ]] || invalid "missing value for --id"
        id="$2"
        shift
        ;;
      --lifecycle)
        [[ $# -ge 2 ]] || invalid "missing value for --lifecycle"
        lifecycle="$2"
        shift
        ;;
      --tmux-target)
        [[ $# -ge 2 ]] || invalid "missing value for --tmux-target"
        tmux_target="$2"
        shift
        ;;
      --cwd)
        [[ $# -ge 2 ]] || invalid "missing value for --cwd"
        cwd="$2"
        shift
        ;;
      -h|--help)
        usage
        exit "${EXIT_SUCCESS}"
        ;;
      *)
        invalid "unknown option for observe add: $1"
        ;;
    esac
    shift
  done

  [[ -n "${id}" ]] || invalid "--id is required"
  [[ -n "${lifecycle}" ]] || invalid "--lifecycle is required"
  [[ -n "${tmux_target}" ]] || invalid "--tmux-target is required"

  if ! is_valid_agent_id "${id}"; then
    invalid "--id must match ^[A-Za-z0-9._:-]+$"
  fi
  if ! is_valid_lifecycle "${lifecycle}"; then
    invalid "--lifecycle must be one of: ephemeral, persistent"
  fi
  if ! orca_tmux_target_validate "${tmux_target}" >/dev/null; then
    invalid "invalid --tmux-target: ${tmux_target}"
  fi
  if [[ -n "${cwd}" && ! -d "${cwd}" ]]; then
    invalid "--cwd must be an existing directory: ${cwd}"
  fi
  if ! command -v tmux >/dev/null 2>&1; then
    fail "tmux is required for observe add"
  fi
  if ! orca_tmux_target_exists "${tmux_target}"; then
    fail "tmux target does not exist: ${tmux_target}"
  fi

  entry_json="$(
    jq -cn \
      --arg id "${id}" \
      --arg lifecycle "${lifecycle}" \
      --arg tmux_target "${tmux_target}" \
      --arg created_at "$(now_utc)" \
      --arg cwd "${cwd}" \
      '{
        id: $id,
        mode: "observed",
        lifecycle: $lifecycle,
        tmux_target: $tmux_target,
        created_at: $created_at,
        source: "monitor_add"
      } + (if $cwd == "" then {} else {cwd: $cwd} end)'
  )"

  if ! added="$(orca_observed_registry_add "${entry_json}")"; then
    fail "failed to register observed target"
  fi

  printf '%s\n' "${added}"
}

cmd_remove() {
  local id=""
  local removed=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)
        [[ $# -ge 2 ]] || invalid "missing value for --id"
        id="$2"
        shift
        ;;
      -h|--help)
        usage
        exit "${EXIT_SUCCESS}"
        ;;
      *)
        invalid "unknown option for observe remove: $1"
        ;;
    esac
    shift
  done

  [[ -n "${id}" ]] || invalid "--id is required"
  if ! is_valid_agent_id "${id}"; then
    invalid "--id must match ^[A-Za-z0-9._:-]+$"
  fi

  if ! removed="$(orca_observed_registry_remove "${id}")"; then
    fail "failed to remove observed target id=${id}"
  fi

  printf '%s\n' "${removed}"
}

cmd_list() {
  local output_json=0
  local entries=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        output_json=1
        ;;
      -h|--help)
        usage
        exit "${EXIT_SUCCESS}"
        ;;
      *)
        invalid "unknown option for observe list: $1"
        ;;
    esac
    shift
  done

  if ! entries="$(orca_observed_registry_list)"; then
    fail "failed to read observed registry"
  fi

  if [[ "${output_json}" -eq 1 ]]; then
    printf '%s\n' "${entries}"
    return 0
  fi

  if [[ "$(jq -r 'length' <<<"${entries}")" -eq 0 ]]; then
    echo "No observed targets registered."
    return 0
  fi

  jq -r '
    (["ID","LIFECYCLE","TMUX_TARGET","CWD","SOURCE"] | @tsv),
    (.[] | [.id, (.lifecycle // "-"), .tmux_target, (.cwd // "-"), (.source // "-")] | @tsv)
  ' <<<"${entries}"
}

cmd_start() {
  local id=""
  local lifecycle=""
  local tmux_target=""
  local cwd=""
  local parsed_json=""
  local kind=""
  local session=""
  local window=""
  local repo_root=""
  local created_at=""
  local command_string=""
  local entry_json=""
  local added=""
  local cmd=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)
        [[ $# -ge 2 ]] || invalid "missing value for --id"
        id="$2"
        shift
        ;;
      --lifecycle)
        [[ $# -ge 2 ]] || invalid "missing value for --lifecycle"
        lifecycle="$2"
        shift
        ;;
      --tmux-target)
        [[ $# -ge 2 ]] || invalid "missing value for --tmux-target"
        tmux_target="$2"
        shift
        ;;
      --cwd)
        [[ $# -ge 2 ]] || invalid "missing value for --cwd"
        cwd="$2"
        shift
        ;;
      --)
        shift
        cmd=("$@")
        break
        ;;
      -h|--help)
        usage
        exit "${EXIT_SUCCESS}"
        ;;
      *)
        invalid "unknown option for observe start: $1"
        ;;
    esac
    shift
  done

  [[ -n "${id}" ]] || invalid "--id is required"
  [[ -n "${lifecycle}" ]] || invalid "--lifecycle is required"
  [[ -n "${tmux_target}" ]] || invalid "--tmux-target is required"
  [[ -n "${cwd}" ]] || invalid "--cwd is required"
  [[ "${#cmd[@]}" -gt 0 ]] || invalid "command after -- is required"

  if ! is_valid_agent_id "${id}"; then
    invalid "--id must match ^[A-Za-z0-9._:-]+$"
  fi
  if ! is_valid_lifecycle "${lifecycle}"; then
    invalid "--lifecycle must be one of: ephemeral, persistent"
  fi
  if ! orca_tmux_target_validate "${tmux_target}" >/dev/null; then
    invalid "invalid --tmux-target: ${tmux_target}"
  fi
  if [[ ! -d "${cwd}" ]]; then
    invalid "--cwd must be an existing directory: ${cwd}"
  fi

  parsed_json="$(orca_tmux_target_parse "${tmux_target}")"
  kind="$(jq -r '.kind' <<<"${parsed_json}")"
  session="$(jq -r '.session' <<<"${parsed_json}")"
  window="$(jq -r '.window // empty' <<<"${parsed_json}")"

  if tmux has-session -t "${session}" >/dev/null 2>&1; then
    fail "tmux session already exists: ${session}"
  fi

  if [[ "${kind}" == "session" ]]; then
    tmux new-session -d -s "${session}" -c "${cwd}" "${cmd[@]}" || fail "failed to create tmux session: ${session}"
  else
    tmux new-session -d -s "${session}" -n "${window}" -c "${cwd}" "${cmd[@]}" || fail "failed to create tmux session/window: ${tmux_target}"
  fi

  repo_root="$(git -C "${cwd}" rev-parse --show-toplevel 2>/dev/null || true)"
  created_at="$(now_utc)"
  command_string="$(command_to_string "${cmd[@]}")"
  entry_json="$(
    jq -cn \
      --arg id "${id}" \
      --arg lifecycle "${lifecycle}" \
      --arg tmux_target "${tmux_target}" \
      --arg cwd "${cwd}" \
      --arg command "${command_string}" \
      --arg created_at "${created_at}" \
      --arg repo_root "${repo_root}" \
      '{
        id: $id,
        mode: "observed",
        lifecycle: $lifecycle,
        tmux_target: $tmux_target,
        cwd: $cwd,
        command: $command,
        created_at: $created_at,
        source: "observe_start"
      } + (if $repo_root == "" then {} else {repo_root: $repo_root} end)'
  )"

  if ! added="$(orca_observed_registry_add "${entry_json}")"; then
    echo "observe: registry add failed; attempting tmux rollback for session ${session}" >&2
    if ! tmux kill-session -t "${session}" >/dev/null 2>&1; then
      echo "observe: rollback tmux kill-session failed for ${session}" >&2
    fi
    fail "failed to register observed target after tmux creation"
  fi

  printf '%s\n' "${added}"
}

if ! command -v jq >/dev/null 2>&1; then
  invalid "jq is required"
fi
if ! command -v tmux >/dev/null 2>&1; then
  fail "tmux is required"
fi

subcommand="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "${subcommand}" in
  add)
    cmd_add "$@"
    ;;
  remove)
    cmd_remove "$@"
    ;;
  list)
    cmd_list "$@"
    ;;
  start)
    cmd_start "$@"
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    invalid "unknown observe command: ${subcommand}"
    ;;
esac
