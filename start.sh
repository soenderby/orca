#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  start.sh [count] [--runs N | --continuous] [--reasoning-level LEVEL]

Options:
  count         Number of worker sessions/worktrees to launch (default: 2)
  --runs N      Stop each agent loop after N completed issue runs
  --continuous  Keep each loop unbounded (agent can request stop) (default)
  --reasoning-level LEVEL
                Set `model_reasoning_effort` for default codex agent command
USAGE
}

COUNT=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_PREFIX="${SESSION_PREFIX:-bb-agent}"
AGENT_MODEL="${AGENT_MODEL:-gpt-5.3-codex}"
AGENT_REASONING_LEVEL="${AGENT_REASONING_LEVEL:-}"
AGENT_COMMAND_WAS_SET=0
if [[ -n "${AGENT_COMMAND+x}" ]]; then
  AGENT_COMMAND_WAS_SET=1
fi
AGENT_COMMAND="${AGENT_COMMAND:-codex exec --dangerously-bypass-approvals-and-sandbox --model ${AGENT_MODEL}}"
MAX_RUNS="${MAX_RUNS:-0}"
RUN_SLEEP_SECONDS="${RUN_SLEEP_SECONDS:-2}"
ORCA_TIMING_METRICS="${ORCA_TIMING_METRICS:-1}"
ORCA_COMPACT_SUMMARY="${ORCA_COMPACT_SUMMARY:-1}"
ORCA_LOCK_SCOPE="${ORCA_LOCK_SCOPE:-merge}"
ORCA_LOCK_TIMEOUT_SECONDS="${ORCA_LOCK_TIMEOUT_SECONDS:-120}"
DOLT_CONTAINER_NAME="${DOLT_CONTAINER_NAME:-bookbinder-dolt}"
DOLT_IMAGE="${DOLT_IMAGE:-dolthub/dolt:latest}"
DOLT_BIND_HOST="${DOLT_BIND_HOST:-127.0.0.1}"
DOLT_BIND_PORT="${DOLT_BIND_PORT:-3307}"
DOLT_SERVER_PORT="${DOLT_SERVER_PORT:-3306}"
DOLT_READY_MAX_ATTEMPTS="${DOLT_READY_MAX_ATTEMPTS:-30}"
DOLT_READY_WAIT_SECONDS="${DOLT_READY_WAIT_SECONDS:-1}"

session_date_path() {
  local session_id="$1"
  local stamp

  if [[ "${session_id}" =~ ([0-9]{8})T[0-9]{6}Z ]]; then
    stamp="${BASH_REMATCH[1]}"
    printf '%s/%s/%s\n' "${stamp:0:4}" "${stamp:4:2}" "${stamp:6:2}"
    return 0
  fi

  date -u +%Y/%m/%d
}

ensure_dolt_server() {
  local dolt_data_dir
  local exists
  local is_running
  local attempt

  if ! command -v docker >/dev/null 2>&1; then
    echo "[start] missing prerequisite: docker (required for Dolt server mode)" >&2
    exit 1
  fi

  dolt_data_dir="${DOLT_DATA_DIR:-${ROOT}/.beads/dolt}"
  if [[ ! -d "${dolt_data_dir}" ]]; then
    echo "[start] missing Dolt data directory: ${dolt_data_dir}" >&2
    exit 1
  fi

  exists="$(docker ps -a --filter "name=^${DOLT_CONTAINER_NAME}$" --format '{{.Names}}')"
  if [[ -n "${exists}" ]]; then
    is_running="$(docker inspect -f '{{.State.Running}}' "${DOLT_CONTAINER_NAME}" 2>/dev/null || true)"
    if [[ "${is_running}" == "true" ]]; then
      echo "[start] Dolt server container already running: ${DOLT_CONTAINER_NAME}"
    else
      echo "[start] starting Dolt server container: ${DOLT_CONTAINER_NAME}"
      docker start "${DOLT_CONTAINER_NAME}" >/dev/null
    fi
  else
    echo "[start] creating Dolt server container: ${DOLT_CONTAINER_NAME}"
    docker run -d \
      --name "${DOLT_CONTAINER_NAME}" \
      -p "${DOLT_BIND_HOST}:${DOLT_BIND_PORT}:${DOLT_SERVER_PORT}" \
      -v "${dolt_data_dir}:/var/lib/dolt" \
      "${DOLT_IMAGE}" \
      sql-server \
      --host 0.0.0.0 \
      --port "${DOLT_SERVER_PORT}" \
      --data-dir /var/lib/dolt >/dev/null
  fi

  for ((attempt=1; attempt<=DOLT_READY_MAX_ATTEMPTS; attempt+=1)); do
    if docker exec "${DOLT_CONTAINER_NAME}" dolt sql -q "SELECT 1;" >/dev/null 2>&1; then
      if (( attempt > 1 )); then
        echo "[start] Dolt SQL server ready after ${attempt} attempts"
      fi
      break
    fi

    if (( attempt == 1 )); then
      echo "[start] waiting for Dolt SQL server readiness"
    fi

    if (( attempt == DOLT_READY_MAX_ATTEMPTS )); then
      echo "[start] Dolt SQL server did not become ready after ${DOLT_READY_MAX_ATTEMPTS} attempts" >&2
      echo "[start] recent Dolt container logs (${DOLT_CONTAINER_NAME}):" >&2
      docker logs --tail 20 "${DOLT_CONTAINER_NAME}" >&2 || true
      exit 1
    fi

    sleep "${DOLT_READY_WAIT_SECONDS}"
  done

  docker exec "${DOLT_CONTAINER_NAME}" dolt sql -q \
    "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY ''; \
     GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION; \
     FLUSH PRIVILEGES;" >/dev/null
}

check_prerequisites() {
  local missing=()
  local cmd
  local agent_command_bin

  for cmd in git tmux bd jq flock; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  agent_command_bin="${AGENT_COMMAND%% *}"
  if [[ -n "${agent_command_bin}" ]] && ! command -v "${agent_command_bin}" >/dev/null 2>&1; then
    missing+=("${agent_command_bin} (from AGENT_COMMAND)")
  fi

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "[start] missing prerequisites: ${missing[*]}" >&2
    exit 1
  fi
}

worktree_is_clean() {
  local worktree="$1"
  [[ -z "$(git -C "${worktree}" status --porcelain --untracked-files=normal 2>/dev/null)" ]]
}

validate_worktree_readiness_for_start() {
  local index="$1"
  local session="${SESSION_PREFIX}-${index}"
  local worktree="${ROOT}/worktrees/agent-${index}"
  local branch_name
  local status_lines
  local line

  if tmux has-session -t "${session}" 2>/dev/null; then
    return 0
  fi

  if ! git -C "${worktree}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "[start] expected git worktree is missing or invalid: ${worktree}" >&2
    return 1
  fi

  if worktree_is_clean "${worktree}"; then
    return 0
  fi

  branch_name="$(git -C "${worktree}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  echo "[start] worktree is not clean and cannot safely create run branches: ${worktree}" >&2
  echo "[start] checked branch: ${branch_name:-unknown}" >&2
  echo "[start] fix: commit/stash/discard changes in this worktree, then rerun start" >&2
  status_lines="$(git -C "${worktree}" status --short 2>/dev/null || true)"
  if [[ -n "${status_lines}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      echo "[start]   ${line}" >&2
    done <<< "${status_lines}"
  fi

  return 1
}

validate_all_worktrees_before_launch() {
  local i
  local failed=0

  for i in $(seq 1 "${COUNT}"); do
    if ! validate_worktree_readiness_for_start "${i}"; then
      failed=1
    fi
  done

  if [[ "${failed}" -eq 1 ]]; then
    echo "[start] refusing to launch sessions until all non-running agent worktrees are clean" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs)
      if [[ $# -lt 2 ]]; then
        echo "[start] --runs requires a numeric argument" >&2
        exit 1
      fi
      MAX_RUNS="$2"
      shift 2
      ;;
    --continuous)
      MAX_RUNS=0
      shift
      ;;
    --reasoning-level)
      if [[ $# -lt 2 ]]; then
        echo "[start] --reasoning-level requires an argument" >&2
        exit 1
      fi
      AGENT_REASONING_LEVEL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "${COUNT}" ]]; then
        COUNT="$1"
        shift
      else
        echo "[start] unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

COUNT="${COUNT:-2}"

check_prerequisites

ROOT="$(git rev-parse --show-toplevel)"
PROMPT_TEMPLATE="${PROMPT_TEMPLATE:-${ROOT}/AGENT_PROMPT.md}"

if ! [[ "${COUNT}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[start] count must be a positive integer: ${COUNT}" >&2
  exit 1
fi

if ! [[ "${MAX_RUNS}" =~ ^[0-9]+$ ]]; then
  echo "[start] runs must be a non-negative integer: ${MAX_RUNS}" >&2
  exit 1
fi

if ! [[ "${RUN_SLEEP_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "[start] RUN_SLEEP_SECONDS must be a non-negative integer: ${RUN_SLEEP_SECONDS}" >&2
  exit 1
fi

if ! [[ "${ORCA_TIMING_METRICS}" =~ ^[01]$ ]]; then
  echo "[start] ORCA_TIMING_METRICS must be 0 or 1: ${ORCA_TIMING_METRICS}" >&2
  exit 1
fi

if ! [[ "${ORCA_COMPACT_SUMMARY}" =~ ^[01]$ ]]; then
  echo "[start] ORCA_COMPACT_SUMMARY must be 0 or 1: ${ORCA_COMPACT_SUMMARY}" >&2
  exit 1
fi

if ! [[ "${ORCA_LOCK_SCOPE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[start] ORCA_LOCK_SCOPE must contain only letters, digits, dot, underscore, or dash: ${ORCA_LOCK_SCOPE}" >&2
  exit 1
fi

if ! [[ "${ORCA_LOCK_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[start] ORCA_LOCK_TIMEOUT_SECONDS must be a positive integer: ${ORCA_LOCK_TIMEOUT_SECONDS}" >&2
  exit 1
fi

if ! [[ "${DOLT_READY_MAX_ATTEMPTS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[start] DOLT_READY_MAX_ATTEMPTS must be a positive integer: ${DOLT_READY_MAX_ATTEMPTS}" >&2
  exit 1
fi

if ! [[ "${DOLT_READY_WAIT_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "[start] DOLT_READY_WAIT_SECONDS must be a non-negative integer: ${DOLT_READY_WAIT_SECONDS}" >&2
  exit 1
fi

if [[ -n "${AGENT_REASONING_LEVEL}" && ! "${AGENT_REASONING_LEVEL}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[start] reasoning level must contain only letters, digits, dot, underscore, or dash: ${AGENT_REASONING_LEVEL}" >&2
  exit 1
fi

if [[ -n "${AGENT_REASONING_LEVEL}" ]]; then
  if [[ "${AGENT_COMMAND_WAS_SET}" -eq 1 ]]; then
    echo "[start] AGENT_COMMAND override detected; --reasoning-level will not modify AGENT_COMMAND" >&2
  else
    AGENT_COMMAND="${AGENT_COMMAND} -c model_reasoning_effort=${AGENT_REASONING_LEVEL}"
  fi
fi

if [[ ! -f "${PROMPT_TEMPLATE}" ]]; then
  echo "[start] missing prompt template: ${PROMPT_TEMPLATE}" >&2
  exit 1
fi

if [[ "${MAX_RUNS}" -eq 0 ]]; then
  mode_message="continuous (agent-controlled stop)"
else
  mode_message="${MAX_RUNS} runs per agent"
fi

echo "[start] run mode: ${mode_message}"
ensure_dolt_server

"${SCRIPT_DIR}/setup-worktrees.sh" "${COUNT}"
validate_all_worktrees_before_launch

for i in $(seq 1 "${COUNT}"); do
  session="${SESSION_PREFIX}-${i}"
  session_id="${session}-$(date -u +%Y%m%dT%H%M%SZ)"
  worktree="${ROOT}/worktrees/agent-${i}"

  if tmux has-session -t "${session}" 2>/dev/null; then
    echo "[start] session ${session} already running"
    continue
  fi

  echo "[start] launching ${session} in ${worktree}"
  tmux_cmd="$(printf "cd %q && AGENT_NAME=%q AGENT_SESSION_ID=%q WORKTREE=%q AGENT_MODEL=%q AGENT_REASONING_LEVEL=%q AGENT_COMMAND=%q PROMPT_TEMPLATE=%q MAX_RUNS=%q RUN_SLEEP_SECONDS=%q ORCA_TIMING_METRICS=%q ORCA_COMPACT_SUMMARY=%q ORCA_LOCK_SCOPE=%q ORCA_LOCK_TIMEOUT_SECONDS=%q %q" \
    "${ROOT}" \
    "agent-${i}" \
    "${session_id}" \
    "${worktree}" \
    "${AGENT_MODEL}" \
    "${AGENT_REASONING_LEVEL}" \
    "${AGENT_COMMAND}" \
    "${PROMPT_TEMPLATE}" \
    "${MAX_RUNS}" \
    "${RUN_SLEEP_SECONDS}" \
    "${ORCA_TIMING_METRICS}" \
    "${ORCA_COMPACT_SUMMARY}" \
    "${ORCA_LOCK_SCOPE}" \
    "${ORCA_LOCK_TIMEOUT_SECONDS}" \
    "${SCRIPT_DIR}/agent-loop.sh")"
  tmux new-session -d -s "${session}" "${tmux_cmd}"

  sleep 1
  if ! tmux has-session -t "${session}" 2>/dev/null; then
    session_log="${ROOT}/agent-logs/sessions/$(session_date_path "${session_id}")/${session_id}/session.log"
    echo "[start] warning: ${session} exited during startup" >&2
    if [[ -f "${session_log}" ]]; then
      echo "[start] recent startup log (${session_log}):" >&2
      tail -n 20 "${session_log}" >&2 || true
    else
      echo "[start] no session log found yet; inspect agent-logs/sessions/" >&2
    fi
  fi
done

echo "[start] running sessions:"
tmux ls | grep "^${SESSION_PREFIX}-" || true
