#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCA_GO_BIN="${ORCA_GO_BIN:-${SCRIPT_DIR}/orca-go}"
if [[ -x "${ORCA_GO_BIN}" ]]; then
  exec "${ORCA_GO_BIN}" queue-read-main "$@"
fi
POLICY_PATH="${ORCA_BR_GUARD_POLICY_PATH:-${SCRIPT_DIR}/lib/br-command-policy.sh}"

usage() {
  cat <<'USAGE'
Usage:
  queue-read-main.sh [options] -- <queue-read-command> [args...]

Runs a queue read command against ORCA_PRIMARY_REPO/main under the shared lock.

Options:
  --repo <path>         Primary repo path (default: ORCA_PRIMARY_REPO or current repo root)
  --lock-helper <path>  Lock helper path (default: ORCA_WITH_LOCK_PATH or ./with-lock.sh)
  --scope <name>        Lock scope (default: ORCA_LOCK_SCOPE or merge)
  --timeout <seconds>   Lock timeout seconds (default: ORCA_LOCK_TIMEOUT_SECONDS or 120)
  --fallback <mode>     Fallback when primary read fails: error|worktree (default: error)
  --worktree <path>     Worktree path used when --fallback worktree is selected (default: current dir)
USAGE
}

PRIMARY_REPO="${ORCA_PRIMARY_REPO:-}"
LOCK_HELPER_PATH="${ORCA_WITH_LOCK_PATH:-${SCRIPT_DIR}/with-lock.sh}"
LOCK_SCOPE="${ORCA_LOCK_SCOPE:-merge}"
LOCK_TIMEOUT_SECONDS="${ORCA_LOCK_TIMEOUT_SECONDS:-120}"
FALLBACK_MODE="error"
FALLBACK_WORKTREE="${PWD}"
BR_BINARY="${ORCA_BR_REAL_BIN:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      if [[ $# -lt 2 ]]; then
        echo "[queue-read-main] --repo requires an argument" >&2
        exit 1
      fi
      PRIMARY_REPO="$2"
      shift 2
      ;;
    --lock-helper)
      if [[ $# -lt 2 ]]; then
        echo "[queue-read-main] --lock-helper requires an argument" >&2
        exit 1
      fi
      LOCK_HELPER_PATH="$2"
      shift 2
      ;;
    --scope)
      if [[ $# -lt 2 ]]; then
        echo "[queue-read-main] --scope requires an argument" >&2
        exit 1
      fi
      LOCK_SCOPE="$2"
      shift 2
      ;;
    --timeout|--lock-timeout)
      if [[ $# -lt 2 ]]; then
        echo "[queue-read-main] --timeout requires an argument" >&2
        exit 1
      fi
      LOCK_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --fallback)
      if [[ $# -lt 2 ]]; then
        echo "[queue-read-main] --fallback requires an argument" >&2
        exit 1
      fi
      FALLBACK_MODE="$2"
      shift 2
      ;;
    --worktree)
      if [[ $# -lt 2 ]]; then
        echo "[queue-read-main] --worktree requires an argument" >&2
        exit 1
      fi
      FALLBACK_WORKTREE="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[queue-read-main] unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "[queue-read-main] queue read command is required after --" >&2
  usage >&2
  exit 1
fi

if [[ -z "${PRIMARY_REPO}" ]]; then
  PRIMARY_REPO="$(git rev-parse --show-toplevel)"
fi

if [[ ! -r "${POLICY_PATH}" ]]; then
  echo "[queue-read-main] br policy file is not readable: ${POLICY_PATH}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${POLICY_PATH}"

if ! [[ "${LOCK_SCOPE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[queue-read-main] invalid lock scope: ${LOCK_SCOPE}" >&2
  exit 1
fi

if ! [[ "${LOCK_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[queue-read-main] lock timeout must be a positive integer: ${LOCK_TIMEOUT_SECONDS}" >&2
  exit 1
fi

if [[ "${FALLBACK_MODE}" != "error" && "${FALLBACK_MODE}" != "worktree" ]]; then
  echo "[queue-read-main] --fallback must be one of: error, worktree" >&2
  exit 1
fi

resolve_br_binary() {
  local configured="$1"
  local resolved=""

  if [[ -n "${configured}" ]]; then
    if [[ ! -x "${configured}" ]]; then
      echo "[queue-read-main] ORCA_BR_REAL_BIN is not executable: ${configured}" >&2
      exit 1
    fi
    printf '%s\n' "${configured}"
    return 0
  fi

  resolved="$(command -v br || true)"
  if [[ -z "${resolved}" ]]; then
    echo "[queue-read-main] br binary is not available on PATH" >&2
    exit 1
  fi

  if [[ ! -x "${resolved}" ]]; then
    echo "[queue-read-main] br binary is not executable: ${resolved}" >&2
    exit 1
  fi

  printf '%s\n' "${resolved}"
}

validate_queue_read_command() {
  local -a cmd=("$@")
  local classification=""

  if [[ ${#cmd[@]} -eq 0 ]]; then
    echo "[queue-read-main] queue read command is required after --" >&2
    exit 1
  fi

  if [[ "${cmd[0]}" != "br" ]]; then
    echo "[queue-read-main] unsupported command: ${cmd[0]} (expected: br ...)" >&2
    exit 1
  fi

  if [[ ${#cmd[@]} -lt 2 ]]; then
    echo "[queue-read-main] br subcommand is required" >&2
    exit 1
  fi

  classification="$(orca_br_classify_command "${cmd[@]:1}")"
  if [[ "${classification}" != "read_only" ]]; then
    echo "[queue-read-main] command is not a queue read command: ${cmd[*]}" >&2
    exit 1
  fi
}

BR_BINARY="$(resolve_br_binary "${BR_BINARY}")"
queue_command_with_real_br=("$@")
validate_queue_read_command "${queue_command_with_real_br[@]}"
queue_command_with_real_br[0]="${BR_BINARY}"

if ! git -C "${PRIMARY_REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[queue-read-main] --repo is not a git worktree: ${PRIMARY_REPO}" >&2
  exit 1
fi

if [[ ! -x "${LOCK_HELPER_PATH}" ]]; then
  echo "[queue-read-main] lock helper is not executable: ${LOCK_HELPER_PATH}" >&2
  exit 1
fi

run_primary_queue_read() {
  "${LOCK_HELPER_PATH}" --scope "${LOCK_SCOPE}" --timeout "${LOCK_TIMEOUT_SECONDS}" -- \
    bash -lc '
      set -euo pipefail

      repo="$1"
      br_bin="$2"
      shift 2

      if [[ ! -x "$br_bin" ]]; then
        echo "[queue-read-main] br binary is not executable: ${br_bin}" >&2
        exit 1
      fi

      primary_branch="$(git -C "$repo" branch --show-current)"
      if [[ "$primary_branch" != "main" ]]; then
        echo "[queue-read-main] expected primary repo on main, found: ${primary_branch}" >&2
        exit 1
      fi

      git -C "$repo" fetch origin main >/dev/null 2>&1 || true
      git -C "$repo" checkout main >/dev/null 2>&1
      git -C "$repo" pull --ff-only origin main >/dev/null 2>&1 || true

      cd "$repo"
      "$br_bin" sync --import-only >/dev/null 2>&1
      "$@"
    ' -- "${PRIMARY_REPO}" "${BR_BINARY}" "${queue_command_with_real_br[@]}"
}

if run_primary_queue_read; then
  echo "[queue-read-main] queue_read_source=primary repo=${PRIMARY_REPO}" >&2
  exit 0
fi

primary_status=$?
echo "[queue-read-main] primary queue read failed (exit=${primary_status})" >&2

if [[ "${FALLBACK_MODE}" != "worktree" ]]; then
  echo "[queue-read-main] queue_read_source=unavailable fallback=error" >&2
  exit "${primary_status}"
fi

if ! git -C "${FALLBACK_WORKTREE}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[queue-read-main] fallback worktree is not a git worktree: ${FALLBACK_WORKTREE}" >&2
  exit "${primary_status}"
fi

(
  cd "${FALLBACK_WORKTREE}"
  "${queue_command_with_real_br[@]}"
)
fallback_status=$?
if [[ "${fallback_status}" -ne 0 ]]; then
  echo "[queue-read-main] queue_read_source=worktree fallback=worktree failed exit=${fallback_status}" >&2
  exit "${fallback_status}"
fi

echo "[queue-read-main] queue_read_source=worktree fallback=worktree" >&2
