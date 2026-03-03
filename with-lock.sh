#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  with-lock.sh [--scope <name>] [--timeout <seconds>] -- <command> [args...]

Options:
  --scope <name>       Lock scope name (default: merge)
  --timeout <seconds>  Lock wait timeout in seconds (default: 120)
USAGE
}

SCOPE="${ORCA_LOCK_SCOPE:-merge}"
TIMEOUT_SECONDS="${ORCA_LOCK_TIMEOUT_SECONDS:-120}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      if [[ $# -lt 2 ]]; then
        echo "[with-lock] --scope requires an argument" >&2
        exit 1
      fi
      SCOPE="$2"
      shift 2
      ;;
    --timeout|--lock-timeout)
      if [[ $# -lt 2 ]]; then
        echo "[with-lock] --timeout requires an argument" >&2
        exit 1
      fi
      TIMEOUT_SECONDS="$2"
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
    -*)
      echo "[with-lock] unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if ! [[ "${SCOPE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[with-lock] scope must contain only letters, digits, dot, underscore, or dash: ${SCOPE}" >&2
  exit 1
fi

if ! [[ "${TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[with-lock] timeout must be a positive integer: ${TIMEOUT_SECONDS}" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  echo "[with-lock] command is required after --" >&2
  usage >&2
  exit 1
fi

COMMON_GIT_DIR="$(git rev-parse --git-common-dir)"
COMMON_GIT_DIR="$(cd "${COMMON_GIT_DIR}" && pwd)"

if [[ "${SCOPE}" == "merge" ]]; then
  LOCK_FILE="${COMMON_GIT_DIR}/orca-global.lock"
else
  LOCK_FILE="${COMMON_GIT_DIR}/orca-global-${SCOPE}.lock"
fi

exec 9>"${LOCK_FILE}"
if ! flock -w "${TIMEOUT_SECONDS}" 9; then
  echo "[with-lock] timed out waiting for ${SCOPE} lock after ${TIMEOUT_SECONDS}s (${LOCK_FILE})" >&2
  exit 1
fi

"$@"
