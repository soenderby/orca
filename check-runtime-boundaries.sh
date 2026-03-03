#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

runtime_targets=(
  orca.sh
  start.sh
  stop.sh
  status.sh
  setup-worktrees.sh
  agent-loop.sh
  with-lock.sh
  check-closed-deps-merged.sh
)

fail=0

if rg -n "scripts/orca/" "${runtime_targets[@]}" >/dev/null 2>&1; then
  echo "[boundary-check] found stale scripts/orca path references in runtime scripts:" >&2
  rg -n "scripts/orca/" "${runtime_targets[@]}" >&2 || true
  fail=1
fi

if rg -n "docs/planning|docs/research" "${runtime_targets[@]}" >/dev/null 2>&1; then
  echo "[boundary-check] runtime scripts must not depend on planning/research docs:" >&2
  rg -n "docs/planning|docs/research" "${runtime_targets[@]}" >&2 || true
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi

echo "[boundary-check] OK: runtime scripts are separated from planning docs and stale path prefixes"
