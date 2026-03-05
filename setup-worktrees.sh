#!/usr/bin/env bash
set -euo pipefail

COUNT="${1:-2}"
ROOT="$(git rev-parse --show-toplevel)"
origin_available=0

if ! [[ "${COUNT}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[setup] count must be a positive integer: ${COUNT}" >&2
  exit 1
fi

mkdir -p "${ROOT}/worktrees"

if git remote get-url origin >/dev/null 2>&1; then
  origin_available=1
else
  echo "[setup] warning: no origin remote configured; upstream setup skipped" >&2
fi

ensure_upstream() {
  local worktree_path="$1"
  local branch_name="$2"
  local upstream_ref
  local upstream_remote
  local upstream_branch
  local ls_remote_status
  local current_branch=""

  if ! git -C "${worktree_path}" show-ref --verify --quiet "refs/heads/${branch_name}"; then
    current_branch="$(git -C "${worktree_path}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ -n "${current_branch}" && "${current_branch}" != "HEAD" ]]; then
      echo "[setup] warning: ${branch_name} not present in ${worktree_path}; using existing checkout ${current_branch}"
    else
      echo "[setup] warning: ${branch_name} not present in ${worktree_path}; skipping upstream setup"
    fi
    return 0
  fi

  upstream_ref="$(git -C "${worktree_path}" for-each-ref --format='%(upstream:short)' "refs/heads/${branch_name}")"
  if [[ -n "${upstream_ref}" ]]; then
    upstream_remote="${upstream_ref%%/*}"
    upstream_branch="${upstream_ref#*/}"
    if git -C "${worktree_path}" ls-remote --exit-code --heads "${upstream_remote}" "${upstream_branch}" >/dev/null 2>&1; then
      echo "[setup] upstream exists for ${branch_name}: ${upstream_ref}"
      return 0
    fi
    ls_remote_status=$?

    if [[ "${ls_remote_status}" -ne 2 ]]; then
      echo "[setup] warning: could not verify upstream ref for ${branch_name}: ${upstream_ref}; proceeding without restore" >&2
      return 0
    fi

    echo "[setup] upstream configured but remote ref missing for ${branch_name}: ${upstream_ref}; recreating"
    if git -C "${worktree_path}" push -u "${upstream_remote}" "${branch_name}" >/dev/null 2>&1; then
      echo "[setup] upstream restored for ${branch_name}: ${upstream_remote}/${branch_name}"
      return 0
    fi

    echo "[setup] failed to restore missing upstream ref for ${branch_name}: ${upstream_ref}" >&2
    return 1
  fi

  if [[ "${origin_available}" -eq 0 ]]; then
    echo "[setup] warning: cannot set upstream for ${branch_name} without origin remote" >&2
    return 0
  fi

  if git -C "${worktree_path}" branch --set-upstream-to "origin/${branch_name}" "${branch_name}" >/dev/null 2>&1; then
    echo "[setup] upstream set for ${branch_name}: origin/${branch_name}"
    return 0
  fi

  echo "[setup] creating upstream for ${branch_name} via push"
  if git -C "${worktree_path}" push -u origin "${branch_name}" >/dev/null 2>&1; then
    echo "[setup] upstream set for ${branch_name}: origin/${branch_name}"
    return 0
  fi

  echo "[setup] failed to set upstream for ${branch_name}; check remote access and branch state" >&2
  return 1
}

create_worktree_if_missing() {
  local abs_path="$1"
  local rel_path="$2"
  local branch="$3"

  if git worktree list --porcelain | awk '/^worktree / {print $2}' | grep -Fxq "${abs_path}"; then
    echo "[setup] ${rel_path} already exists"
    return 0
  fi

  if git show-ref --verify --quiet "refs/heads/${branch}"; then
    echo "[setup] creating ${rel_path} from local branch ${branch}"
    git worktree add "${abs_path}" "${branch}"
    return 0
  fi

  if [[ "${origin_available}" -eq 1 ]] && git ls-remote --exit-code --heads origin "${branch}" >/dev/null 2>&1; then
    echo "[setup] creating ${rel_path} from origin/${branch}"
    git worktree add -b "${branch}" "${abs_path}" "origin/${branch}"
    return 0
  fi

  echo "[setup] creating ${rel_path} (new branch: ${branch} from main)"
  git worktree add -b "${branch}" "${abs_path}" main
}

for i in $(seq 1 "${COUNT}"); do
  name="agent-${i}"
  rel_path="worktrees/${name}"
  abs_path="${ROOT}/${rel_path}"
  branch="swarm/${name}"

  create_worktree_if_missing "${abs_path}" "${rel_path}" "${branch}"
  ensure_upstream "${abs_path}" "${branch}"
done

echo "[setup] done"
