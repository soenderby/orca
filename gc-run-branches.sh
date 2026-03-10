#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  gc-run-branches.sh [--apply] [--base REF] [--repo PATH]

Safely prune stale local run branches matching `swarm/*-run-*`.

Default behavior is dry-run reporting only. A branch is prunable when:
1) it is merged into the selected base ref (default: main)
2) it is not checked out in any worktree
3) it is not associated with an active tmux agent session

Options:
  --apply        Delete prunable branches (default: dry-run)
  --dry-run      Force dry-run mode
  --base REF     Base ref used for merged check (default: main)
  --repo PATH    Repo path (default: current repo root)
  -h, --help     Show help
USAGE
}

APPLY=0
BASE_REF="main"
REPO_PATH=""
SESSION_PREFIX="${SESSION_PREFIX:-orca-agent}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=1
      shift
      ;;
    --dry-run)
      APPLY=0
      shift
      ;;
    --base)
      if [[ $# -lt 2 ]]; then
        echo "[gc-run-branches] --base requires an argument" >&2
        exit 1
      fi
      BASE_REF="$2"
      shift 2
      ;;
    --repo)
      if [[ $# -lt 2 ]]; then
        echo "[gc-run-branches] --repo requires an argument" >&2
        exit 1
      fi
      REPO_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[gc-run-branches] unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${REPO_PATH}" ]]; then
  REPO_PATH="$(git rev-parse --show-toplevel)"
fi

if ! git -C "${REPO_PATH}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[gc-run-branches] --repo is not a git worktree: ${REPO_PATH}" >&2
  exit 1
fi

if ! git -C "${REPO_PATH}" rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null 2>&1; then
  echo "[gc-run-branches] base ref does not resolve to a commit: ${BASE_REF}" >&2
  exit 1
fi

mapfile -t run_branches < <(
  git -C "${REPO_PATH}" for-each-ref --format='%(refname:short)' 'refs/heads/swarm/*-run-*' | sort
)

if [[ "${#run_branches[@]}" -eq 0 ]]; then
  echo "[gc-run-branches] no local run branches found (pattern: swarm/*-run-*)"
  exit 0
fi

declare -A worktree_branch_set=()
while IFS= read -r worktree_branch; do
  [[ -z "${worktree_branch}" ]] && continue
  worktree_branch_set["${worktree_branch}"]=1
done < <(
  git -C "${REPO_PATH}" worktree list --porcelain \
    | awk '$1 == "branch" {sub("^refs/heads/", "", $2); print $2}'
)

declare -A active_agent_set=()
declare -A active_session_id_set=()
if command -v tmux >/dev/null 2>&1; then
  while IFS= read -r session_name; do
    [[ -z "${session_name}" ]] && continue
    if [[ "${session_name}" =~ ^${SESSION_PREFIX}-([0-9]+)$ ]]; then
      active_agent_set["agent-${BASH_REMATCH[1]}"]=1

      session_env_line="$(tmux show-environment -t "${session_name}" ORCA_SESSION_ID 2>/dev/null || true)"
      if [[ "${session_env_line}" =~ ^ORCA_SESSION_ID=(.+)$ ]]; then
        active_session_id_set["${BASH_REMATCH[1]}"]=1
      fi
    fi
  done < <(tmux ls -F '#S' 2>/dev/null || true)
fi

declare -a prunable_branches=()
declare -a protected_lines=()
declare -a unmerged_lines=()

for branch in "${run_branches[@]}"; do
  if [[ -n "${worktree_branch_set[${branch}]:-}" ]]; then
    protected_lines+=("${branch} :: active worktree checkout")
    continue
  fi

  session_protected=0
  for session_id in "${!active_session_id_set[@]}"; do
    if [[ "${branch}" == *"-${session_id}-"* ]]; then
      protected_lines+=("${branch} :: active session ${session_id}")
      session_protected=1
      break
    fi
  done
  if [[ "${session_protected}" -eq 1 ]]; then
    continue
  fi

  if [[ "${branch}" =~ ^swarm/(agent-[0-9]+)-run- ]] && [[ -n "${active_agent_set[${BASH_REMATCH[1]}]:-}" ]]; then
    protected_lines+=("${branch} :: active tmux session for ${BASH_REMATCH[1]}")
    continue
  fi

  if git -C "${REPO_PATH}" merge-base --is-ancestor "${branch}" "${BASE_REF}"; then
    prunable_branches+=("${branch}")
  else
    unmerged_lines+=("${branch} :: not merged into ${BASE_REF}")
  fi
done

mode_label="dry-run"
if [[ "${APPLY}" -eq 1 ]]; then
  mode_label="apply"
fi

echo "[gc-run-branches] mode: ${mode_label}"
echo "[gc-run-branches] repo: ${REPO_PATH}"
echo "[gc-run-branches] base ref: ${BASE_REF}"
echo "[gc-run-branches] scanned: ${#run_branches[@]}"
echo "[gc-run-branches] prunable: ${#prunable_branches[@]}"
echo "[gc-run-branches] protected: ${#protected_lines[@]}"
echo "[gc-run-branches] unmerged: ${#unmerged_lines[@]}"

if [[ "${#prunable_branches[@]}" -gt 0 ]]; then
  if [[ "${APPLY}" -eq 1 ]]; then
    echo "[gc-run-branches] deleting prunable branches:"
    for branch in "${prunable_branches[@]}"; do
      git -C "${REPO_PATH}" branch -d "${branch}" >/dev/null
      echo "  deleted ${branch}"
    done
  else
    echo "[gc-run-branches] branches that would be deleted:"
    for branch in "${prunable_branches[@]}"; do
      echo "  ${branch}"
    done
    echo "[gc-run-branches] rerun with --apply to delete."
  fi
fi

if [[ "${#protected_lines[@]}" -gt 0 ]]; then
  echo "[gc-run-branches] protected branches:"
  for line in "${protected_lines[@]}"; do
    echo "  ${line}"
  done
fi

if [[ "${#unmerged_lines[@]}" -gt 0 ]]; then
  echo "[gc-run-branches] skipped unmerged branches:"
  for line in "${unmerged_lines[@]}"; do
    echo "  ${line}"
  done
fi
