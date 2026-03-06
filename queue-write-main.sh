#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  queue-write-main.sh [options] -- <queue-command> [args...]

Runs a queue mutation command against ORCA_PRIMARY_REPO/main under the shared
writer lock, with import/flush and optional .beads commit/push.

Options:
  --repo <path>       Primary repo path (default: ORCA_PRIMARY_REPO or current repo root)
  --lock-helper <p>   Lock helper path (default: ORCA_WITH_LOCK_PATH or ./with-lock.sh)
  --scope <name>      Lock scope (default: ORCA_LOCK_SCOPE or merge)
  --timeout <sec>     Lock timeout seconds (default: ORCA_LOCK_TIMEOUT_SECONDS or 120)
  --actor <name>      Actor label for default commit message (default: AGENT_NAME or orca-agent)
  --message <text>    Commit message for .beads changes
USAGE
}

PRIMARY_REPO="${ORCA_PRIMARY_REPO:-}"
LOCK_HELPER_PATH="${ORCA_WITH_LOCK_PATH:-${SCRIPT_DIR}/with-lock.sh}"
LOCK_SCOPE="${ORCA_LOCK_SCOPE:-merge}"
LOCK_TIMEOUT_SECONDS="${ORCA_LOCK_TIMEOUT_SECONDS:-120}"
ACTOR="${AGENT_NAME:-orca-agent}"
COMMIT_MESSAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      if [[ $# -lt 2 ]]; then
        echo "[queue-write-main] --repo requires an argument" >&2
        exit 1
      fi
      PRIMARY_REPO="$2"
      shift 2
      ;;
    --lock-helper)
      if [[ $# -lt 2 ]]; then
        echo "[queue-write-main] --lock-helper requires an argument" >&2
        exit 1
      fi
      LOCK_HELPER_PATH="$2"
      shift 2
      ;;
    --scope)
      if [[ $# -lt 2 ]]; then
        echo "[queue-write-main] --scope requires an argument" >&2
        exit 1
      fi
      LOCK_SCOPE="$2"
      shift 2
      ;;
    --timeout|--lock-timeout)
      if [[ $# -lt 2 ]]; then
        echo "[queue-write-main] --timeout requires an argument" >&2
        exit 1
      fi
      LOCK_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --actor)
      if [[ $# -lt 2 ]]; then
        echo "[queue-write-main] --actor requires an argument" >&2
        exit 1
      fi
      ACTOR="$2"
      shift 2
      ;;
    --message)
      if [[ $# -lt 2 ]]; then
        echo "[queue-write-main] --message requires an argument" >&2
        exit 1
      fi
      COMMIT_MESSAGE="$2"
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
      echo "[queue-write-main] unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "[queue-write-main] queue command is required after --" >&2
  usage >&2
  exit 1
fi

if [[ -z "${PRIMARY_REPO}" ]]; then
  PRIMARY_REPO="$(git rev-parse --show-toplevel)"
fi

if ! [[ "${LOCK_SCOPE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[queue-write-main] invalid lock scope: ${LOCK_SCOPE}" >&2
  exit 1
fi

if ! [[ "${LOCK_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[queue-write-main] lock timeout must be a positive integer: ${LOCK_TIMEOUT_SECONDS}" >&2
  exit 1
fi

if [[ -z "${COMMIT_MESSAGE}" ]]; then
  COMMIT_MESSAGE="queue: update by ${ACTOR}"
fi

if ! git -C "${PRIMARY_REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[queue-write-main] --repo is not a git worktree: ${PRIMARY_REPO}" >&2
  exit 1
fi

if [[ ! -x "${LOCK_HELPER_PATH}" ]]; then
  echo "[queue-write-main] lock helper is not executable: ${LOCK_HELPER_PATH}" >&2
  exit 1
fi

"${LOCK_HELPER_PATH}" --scope "${LOCK_SCOPE}" --timeout "${LOCK_TIMEOUT_SECONDS}" -- \
  bash -lc '
    set -euo pipefail

    repo="$1"
    commit_message="$2"
    shift 2

    primary_branch="$(git -C "$repo" branch --show-current)"
    if [[ "$primary_branch" != "main" ]]; then
      echo "[queue-write-main] expected primary repo on main, found: ${primary_branch}" >&2
      exit 1
    fi

    if ! git -C "$repo" diff --quiet || ! git -C "$repo" diff --cached --quiet; then
      echo "[queue-write-main] primary repo has uncommitted changes; aborting" >&2
      git -C "$repo" status --short >&2
      exit 1
    fi

    git -C "$repo" fetch origin main
    git -C "$repo" checkout main
    git -C "$repo" pull --ff-only origin main

    cd "$repo"
    br sync --import-only
    "$@"
    br sync --flush-only

    git add .beads/
    if ! git diff --cached --quiet; then
      git commit -m "$commit_message"
      git push origin main
    fi
  ' -- "${PRIMARY_REPO}" "${COMMIT_MESSAGE}" "$@"
