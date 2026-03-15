#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  dispatch-loop.sh [options]

External async dispatch loop for Orca-style queue execution.
This is intentionally NOT an `orca` subcommand.

Behavior:
  - Poll open/ready/session signals.
  - If no active sessions and ready work exists, launch a bounded Orca start wave.
  - Continue until stopped, or until open count reaches zero (default).

Options:
  --repo <path>              Repository root to run commands in (default: git top-level or cwd)
  --max-slots <n>            Max slots to launch per wave (default: 2)
  --poll-interval <sec>      Poll interval seconds (default: 20)
  --lock-file <path>         Lock file path (default: <git-common-dir>/orca-dispatch-loop.lock)
  --wait-lock                Wait for lock instead of exiting when already running

  --open-count-cmd <cmd>     Command returning integer open count
  --ready-count-cmd <cmd>    Command returning integer ready count
  --active-count-cmd <cmd>   Command returning integer active session count
  --launch-cmd <cmd>         Launch command (uses DISPATCH_SLOTS env var)

  --once                     Run a single poll cycle, then exit
  --no-stop-when-open-zero   Keep running even when open count is zero
  --dry-run                  Do not launch; print planned launch commands
  -h, --help                 Show help

Default command hooks:
  open   : br list --status open --json 2>/dev/null | jq "length"
  ready  : br ready --json 2>/dev/null | jq "length"
  active : ./orca.sh status --quick --json 2>/dev/null | jq -r ".signals.sessions_total // 0"
  launch : ./orca.sh start "${DISPATCH_SLOTS}" --runs 1
USAGE
}

log() {
  printf '[dispatch-loop] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

require_integer() {
  local label="$1"
  local value="$2"
  if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
    echo "[dispatch-loop] ${label} must be a non-negative integer, got: ${value}" >&2
    exit 1
  fi
}

resolve_repo_root() {
  local requested="${1:-}"
  if [[ -n "${requested}" ]]; then
    printf '%s\n' "${requested}"
    return 0
  fi

  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    git rev-parse --show-toplevel
  else
    pwd
  fi
}

resolve_default_lock_file() {
  local repo="$1"
  local common_git_dir=""

  if ! common_git_dir="$(git -C "${repo}" rev-parse --git-common-dir 2>/dev/null)"; then
    echo "[dispatch-loop] failed to resolve git common dir for repo: ${repo}" >&2
    exit 1
  fi

  if [[ "${common_git_dir}" != /* ]]; then
    common_git_dir="$(cd "${repo}" && cd "${common_git_dir}" && pwd)"
  fi

  printf '%s\n' "${common_git_dir}/orca-dispatch-loop.lock"
}

run_count_command() {
  local label="$1"
  local command_text="$2"
  local output=""

  if ! output="$(cd "${REPO}" && DISPATCH_REPO="${REPO}" bash -lc "${command_text}")"; then
    echo "[dispatch-loop] ${label} command failed: ${command_text}" >&2
    return 1
  fi

  output="$(printf '%s' "${output}" | tr -d '[:space:]')"
  if ! [[ "${output}" =~ ^[0-9]+$ ]]; then
    echo "[dispatch-loop] ${label} command must emit an integer, got: ${output}" >&2
    echo "[dispatch-loop] command: ${command_text}" >&2
    return 1
  fi

  printf '%s\n' "${output}"
}

REPO=""
MAX_SLOTS=2
POLL_INTERVAL=20
LOCK_FILE=""
WAIT_LOCK=0
ONCE=0
STOP_WHEN_OPEN_ZERO=1
DRY_RUN=0

OPEN_COUNT_CMD='br list --status open --json 2>/dev/null | jq "length"'
READY_COUNT_CMD='br ready --json 2>/dev/null | jq "length"'
ACTIVE_COUNT_CMD='./orca.sh status --quick --json 2>/dev/null | jq -r ".signals.sessions_total // 0"'
LAUNCH_CMD='./orca.sh start "${DISPATCH_SLOTS}" --runs 1'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { echo "[dispatch-loop] --repo requires an argument" >&2; exit 1; }
      REPO="$2"
      shift 2
      ;;
    --max-slots)
      [[ $# -ge 2 ]] || { echo "[dispatch-loop] --max-slots requires an argument" >&2; exit 1; }
      MAX_SLOTS="$2"
      shift 2
      ;;
    --poll-interval)
      [[ $# -ge 2 ]] || { echo "[dispatch-loop] --poll-interval requires an argument" >&2; exit 1; }
      POLL_INTERVAL="$2"
      shift 2
      ;;
    --lock-file)
      [[ $# -ge 2 ]] || { echo "[dispatch-loop] --lock-file requires an argument" >&2; exit 1; }
      LOCK_FILE="$2"
      shift 2
      ;;
    --wait-lock)
      WAIT_LOCK=1
      shift
      ;;
    --open-count-cmd)
      [[ $# -ge 2 ]] || { echo "[dispatch-loop] --open-count-cmd requires an argument" >&2; exit 1; }
      OPEN_COUNT_CMD="$2"
      shift 2
      ;;
    --ready-count-cmd)
      [[ $# -ge 2 ]] || { echo "[dispatch-loop] --ready-count-cmd requires an argument" >&2; exit 1; }
      READY_COUNT_CMD="$2"
      shift 2
      ;;
    --active-count-cmd)
      [[ $# -ge 2 ]] || { echo "[dispatch-loop] --active-count-cmd requires an argument" >&2; exit 1; }
      ACTIVE_COUNT_CMD="$2"
      shift 2
      ;;
    --launch-cmd)
      [[ $# -ge 2 ]] || { echo "[dispatch-loop] --launch-cmd requires an argument" >&2; exit 1; }
      LAUNCH_CMD="$2"
      shift 2
      ;;
    --once)
      ONCE=1
      shift
      ;;
    --no-stop-when-open-zero)
      STOP_WHEN_OPEN_ZERO=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[dispatch-loop] unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

REPO="$(resolve_repo_root "${REPO}")"

if ! git -C "${REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[dispatch-loop] --repo must be a git worktree: ${REPO}" >&2
  exit 1
fi

require_integer "max-slots" "${MAX_SLOTS}"
require_integer "poll-interval" "${POLL_INTERVAL}"

if [[ "${MAX_SLOTS}" -eq 0 ]]; then
  echo "[dispatch-loop] --max-slots must be >= 1" >&2
  exit 1
fi
if [[ "${POLL_INTERVAL}" -eq 0 ]]; then
  echo "[dispatch-loop] --poll-interval must be >= 1" >&2
  exit 1
fi

if [[ -z "${LOCK_FILE}" ]]; then
  LOCK_FILE="$(resolve_default_lock_file "${REPO}")"
fi
mkdir -p "$(dirname "${LOCK_FILE}")"

exec 9>"${LOCK_FILE}"
if [[ "${WAIT_LOCK}" -eq 1 ]]; then
  flock 9
else
  if ! flock -n 9; then
    echo "[dispatch-loop] another dispatcher holds lock: ${LOCK_FILE}" >&2
    exit 11
  fi
fi

log "starting repo=${REPO} max_slots=${MAX_SLOTS} poll_interval=${POLL_INTERVAL}s lock=${LOCK_FILE}"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "dry-run enabled; launch commands will not execute"
fi

while true; do
  open_count="$(run_count_command "open-count" "${OPEN_COUNT_CMD}")"
  ready_count="$(run_count_command "ready-count" "${READY_COUNT_CMD}")"
  active_count="$(run_count_command "active-count" "${ACTIVE_COUNT_CMD}")"

  log "state open=${open_count} ready=${ready_count} active=${active_count}"

  if [[ "${STOP_WHEN_OPEN_ZERO}" -eq 1 && "${open_count}" -eq 0 ]]; then
    log "open count reached zero; exiting"
    exit 0
  fi

  if [[ "${active_count}" -eq 0 && "${ready_count}" -gt 0 ]]; then
    slots="${ready_count}"
    if (( slots > MAX_SLOTS )); then
      slots="${MAX_SLOTS}"
    fi

    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "would launch slots=${slots} command=${LAUNCH_CMD}"
    else
      log "launching slots=${slots}"
      if ! (cd "${REPO}" && DISPATCH_REPO="${REPO}" DISPATCH_SLOTS="${slots}" bash -lc "${LAUNCH_CMD}"); then
        log "launch command failed (will retry next cycle)"
      fi
    fi
  fi

  if [[ "${ONCE}" -eq 1 ]]; then
    log "once mode complete; exiting"
    exit 0
  fi

  sleep "${POLL_INTERVAL}"
done
