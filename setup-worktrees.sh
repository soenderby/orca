#!/usr/bin/env bash
set -euo pipefail

COUNT="${1:-2}"
ROOT="$(git rev-parse --show-toplevel)"
origin_available=0
BASE_REF=""

if ! [[ "${COUNT}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[setup] count must be a positive integer: ${COUNT}" >&2
  exit 1
fi

mkdir -p "${ROOT}/worktrees"

if git remote get-url origin >/dev/null 2>&1; then
  origin_available=1
else
  echo "[setup] warning: no origin remote configured; remote branch checks skipped" >&2
fi

detect_base_ref() {
  local current_branch

  if [[ -n "${ORCA_BASE_REF:-}" ]]; then
    printf '%s\n' "${ORCA_BASE_REF}"
    return 0
  fi

  warn_if_main_refs_diverge

  if git rev-parse --verify --quiet "main^{commit}" >/dev/null; then
    printf '%s\n' "main"
    return 0
  fi

  if git rev-parse --verify --quiet "origin/main^{commit}" >/dev/null; then
    printf '%s\n' "origin/main"
    return 0
  fi

  current_branch="$(git branch --show-current 2>/dev/null || true)"
  if [[ -n "${current_branch}" ]]; then
    printf '%s\n' "${current_branch}"
    return 0
  fi

  echo "[setup] unable to determine a base ref for new worktrees" >&2
  exit 1
}

warn_if_main_refs_diverge() {
  local counts
  local ahead
  local behind

  if ! git rev-parse --verify --quiet "main^{commit}" >/dev/null; then
    return 0
  fi

  if ! git rev-parse --verify --quiet "origin/main^{commit}" >/dev/null; then
    return 0
  fi

  counts="$(git rev-list --left-right --count main...origin/main 2>/dev/null || true)"
  if [[ -z "${counts}" ]]; then
    return 0
  fi

  read -r ahead behind <<< "${counts}"
  if [[ "${ahead}" != "0" || "${behind}" != "0" ]]; then
    echo "[setup] warning: local main and origin/main differ (local ahead ${ahead}, behind ${behind}); defaulting to local main" >&2
  fi
}

branch_in_any_worktree() {
  local branch_name="$1"

  git worktree list --porcelain \
    | awk -v target="refs/heads/${branch_name}" '
        $1 == "branch" && $2 == target { found = 1 }
        END { exit(found ? 0 : 1) }
      '
}

warn_if_remote_agent_branch_exists() {
  local branch_name="$1"

  if [[ "${origin_available}" -eq 1 ]] && git ls-remote --exit-code --heads origin "${branch_name}" >/dev/null 2>&1; then
    echo "[setup] note: remote branch origin/${branch_name} exists but is ignored"
    echo "[setup] note: agent branches are treated as local transport state"
  fi
}

create_worktree_if_missing() {
  local abs_path="$1"
  local rel_path="$2"
  local branch="$3"
  local base_ref="$4"

  if git worktree list --porcelain | awk '/^worktree / {print $2}' | grep -Fxq "${abs_path}"; then
    echo "[setup] ${rel_path} already exists"
    return 0
  fi

  warn_if_remote_agent_branch_exists "${branch}"

  if git show-ref --verify --quiet "refs/heads/${branch}"; then
    if branch_in_any_worktree "${branch}"; then
      echo "[setup] branch ${branch} is already checked out in another worktree; cannot recreate ${rel_path}" >&2
      return 1
    fi

    echo "[setup] resetting local ${branch} to ${base_ref} before creating ${rel_path}"
    git branch -f "${branch}" "${base_ref}"
    git branch --unset-upstream "${branch}" >/dev/null 2>&1 || true
    git worktree add "${abs_path}" "${branch}"
    return 0
  fi

  echo "[setup] creating ${rel_path} (new branch: ${branch} from ${base_ref})"
  git worktree add -b "${branch}" "${abs_path}" "${base_ref}"
  git -C "${abs_path}" branch --unset-upstream "${branch}" >/dev/null 2>&1 || true
}

BASE_REF="$(detect_base_ref)"
echo "[setup] base ref for new worktrees: ${BASE_REF}"

for i in $(seq 1 "${COUNT}"); do
  name="agent-${i}"
  rel_path="worktrees/${name}"
  abs_path="${ROOT}/${rel_path}"
  branch="swarm/${name}"

  create_worktree_if_missing "${abs_path}" "${rel_path}" "${branch}" "${BASE_REF}"
done

echo "[setup] done"
