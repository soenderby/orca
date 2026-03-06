#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  merge-main.sh [options]

Merges a local source branch into ORCA_PRIMARY_REPO/main under the shared writer lock.
Rejects source branches that carry .beads changes.

Options:
  --source <branch>   Source branch to merge (default: current branch)
  --repo <path>       Primary repo path (default: ORCA_PRIMARY_REPO or current repo root)
  --lock-helper <p>   Lock helper path (default: ORCA_WITH_LOCK_PATH or ./with-lock.sh)
  --scope <name>      Lock scope (default: ORCA_LOCK_SCOPE or merge)
  --timeout <sec>     Lock timeout seconds (default: ORCA_LOCK_TIMEOUT_SECONDS or 120)
USAGE
}

SOURCE_BRANCH=""
PRIMARY_REPO="${ORCA_PRIMARY_REPO:-}"
LOCK_HELPER_PATH="${ORCA_WITH_LOCK_PATH:-${SCRIPT_DIR}/with-lock.sh}"
LOCK_SCOPE="${ORCA_LOCK_SCOPE:-merge}"
LOCK_TIMEOUT_SECONDS="${ORCA_LOCK_TIMEOUT_SECONDS:-120}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      if [[ $# -lt 2 ]]; then
        echo "[merge-main] --source requires an argument" >&2
        exit 1
      fi
      SOURCE_BRANCH="$2"
      shift 2
      ;;
    --repo)
      if [[ $# -lt 2 ]]; then
        echo "[merge-main] --repo requires an argument" >&2
        exit 1
      fi
      PRIMARY_REPO="$2"
      shift 2
      ;;
    --lock-helper)
      if [[ $# -lt 2 ]]; then
        echo "[merge-main] --lock-helper requires an argument" >&2
        exit 1
      fi
      LOCK_HELPER_PATH="$2"
      shift 2
      ;;
    --scope)
      if [[ $# -lt 2 ]]; then
        echo "[merge-main] --scope requires an argument" >&2
        exit 1
      fi
      LOCK_SCOPE="$2"
      shift 2
      ;;
    --timeout|--lock-timeout)
      if [[ $# -lt 2 ]]; then
        echo "[merge-main] --timeout requires an argument" >&2
        exit 1
      fi
      LOCK_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[merge-main] unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${PRIMARY_REPO}" ]]; then
  PRIMARY_REPO="$(git rev-parse --show-toplevel)"
fi

if [[ -z "${SOURCE_BRANCH}" ]]; then
  SOURCE_BRANCH="$(git branch --show-current 2>/dev/null || true)"
fi

if [[ -z "${SOURCE_BRANCH}" || "${SOURCE_BRANCH}" == "HEAD" ]]; then
  echo "[merge-main] unable to determine source branch; pass --source <branch>" >&2
  exit 1
fi

if ! [[ "${SOURCE_BRANCH}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  echo "[merge-main] invalid source branch name: ${SOURCE_BRANCH}" >&2
  exit 1
fi

if ! [[ "${LOCK_SCOPE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[merge-main] invalid lock scope: ${LOCK_SCOPE}" >&2
  exit 1
fi

if ! [[ "${LOCK_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[merge-main] lock timeout must be a positive integer: ${LOCK_TIMEOUT_SECONDS}" >&2
  exit 1
fi

if ! git -C "${PRIMARY_REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[merge-main] --repo is not a git worktree: ${PRIMARY_REPO}" >&2
  exit 1
fi

if [[ ! -x "${LOCK_HELPER_PATH}" ]]; then
  echo "[merge-main] lock helper is not executable: ${LOCK_HELPER_PATH}" >&2
  exit 1
fi

"${LOCK_HELPER_PATH}" --scope "${LOCK_SCOPE}" --timeout "${LOCK_TIMEOUT_SECONDS}" -- \
  bash -lc '
    set -euo pipefail

    repo="$1"
    src_branch="$2"

    cleanup_after_failed_merge() {
      git -C "$repo" merge --abort >/dev/null 2>&1 || true
      git -C "$repo" reset --hard HEAD >/dev/null 2>&1 || true
    }

    primary_branch="$(git -C "$repo" branch --show-current)"
    if [[ "$primary_branch" != "main" ]]; then
      echo "[merge-main] expected primary repo on main, found: ${primary_branch}" >&2
      exit 1
    fi

    if ! git -C "$repo" diff --quiet || ! git -C "$repo" diff --cached --quiet; then
      echo "[merge-main] primary repo has uncommitted changes; aborting before fetch/merge" >&2
      git -C "$repo" status --short >&2
      exit 1
    fi

    git -C "$repo" fetch origin main
    git -C "$repo" checkout main
    git -C "$repo" pull --ff-only origin main

    if ! git -C "$repo" rev-parse --verify --quiet "${src_branch}^{commit}" >/dev/null; then
      echo "[merge-main] source branch must exist locally in shared repo: ${src_branch}" >&2
      echo "[merge-main] local Orca flow should merge local run branches without pushing them to origin" >&2
      exit 1
    fi

    beads_diff="$(git -C "$repo" diff --name-only "main...${src_branch}" -- .beads || true)"
    if [[ -n "$beads_diff" ]]; then
      echo "[merge-main] source branch carries .beads changes; queue writes must go through queue-write-main.sh" >&2
      printf "%s\n" "$beads_diff" >&2
      exit 1
    fi

    if ! git -C "$repo" merge --no-ff "${src_branch}"; then
      echo "[merge-main] merge failed; cleaning up primary repo state" >&2
      cleanup_after_failed_merge
      exit 1
    fi

    if ! git -C "$repo" push origin main; then
      echo "[merge-main] push failed after successful merge; leaving merge commit in primary repo for manual retry" >&2
      exit 1
    fi
  ' -- "${PRIMARY_REPO}" "${SOURCE_BRANCH}"
