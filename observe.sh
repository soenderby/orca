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
  ./orca.sh observe start --id AGENT_ID --lifecycle LIFECYCLE --tmux-target TARGET --cwd PATH -- <command...>
  ./observe.sh start --id AGENT_ID --lifecycle LIFECYCLE --tmux-target TARGET --cwd PATH -- <command...>

Commands:
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
