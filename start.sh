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

ensure_br_workspace() {
  local doctor_output

  if [[ ! -d "${ROOT}/.beads" ]]; then
    echo "[start] missing .beads workspace in repo root: ${ROOT}/.beads" >&2
    echo "[start] run: br init && br config set id.prefix orca" >&2
    exit 1
  fi

  if doctor_output="$(br doctor 2>&1)"; then
    return 0
  fi

  echo "[start] br workspace check failed (br doctor)" >&2
  if [[ -n "${doctor_output}" ]]; then
    printf '%s\n' "${doctor_output}" | head -n 20 >&2
  fi
  echo "[start] fix the workspace above, then rerun start" >&2
  exit 1
}

check_prerequisites() {
  local missing=()
  local cmd
  local agent_command_bin

  for cmd in git tmux br jq flock; do
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

ensure_br_workspace

if [[ "${MAX_RUNS}" -eq 0 ]]; then
  mode_message="continuous (agent-controlled stop)"
else
  mode_message="${MAX_RUNS} runs per agent"
fi

echo "[start] run mode: ${mode_message}"

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
