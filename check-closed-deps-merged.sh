#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  check-closed-deps-merged.sh <issue-id> [target-ref]

Checks closed dependencies for an issue and verifies each dependency ID appears
in commit history of the target integration ref (default: origin/main, fallback: main).

Exit codes:
  0: all closed blocking dependencies are represented in target ref history
  2: one or more closed blocking dependencies are not represented
  64: invalid usage or missing required tools
USAGE
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 64
fi

for cmd in bd jq git; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "[deps-check] missing required command: ${cmd}" >&2
    exit 64
  fi
done

issue_id="$1"
target_ref="${2:-origin/main}"

if ! git rev-parse --verify --quiet "${target_ref}^{commit}" >/dev/null; then
  if [[ "${target_ref}" == "origin/main" ]] && git rev-parse --verify --quiet "main^{commit}" >/dev/null; then
    target_ref="main"
  else
    echo "[deps-check] target ref not found: ${target_ref}" >&2
    exit 64
  fi
fi

deps_json="$(bd dep list "${issue_id}" --json)"

# discovered-from and tracks do not block execution in Orca runs.
mapfile -t closed_dep_ids < <(
  jq -r '
    .[]
    | select(.status == "closed")
    | select(.dependency_type != "discovered-from" and .dependency_type != "tracks")
    | .id
  ' <<<"${deps_json}"
)

if [[ "${#closed_dep_ids[@]}" -eq 0 ]]; then
  echo "[deps-check] no closed blocking dependencies for ${issue_id}"
  exit 0
fi

missing=()
for dep_id in "${closed_dep_ids[@]}"; do
  if git log "${target_ref}" --fixed-strings --grep="${dep_id}" -n 1 --oneline >/dev/null; then
    echo "[deps-check] merged on ${target_ref}: ${dep_id}"
  else
    echo "[deps-check] NOT merged on ${target_ref}: ${dep_id}"
    missing+=("${dep_id}")
  fi
done

if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "[deps-check] failing ${issue_id}: closed dependencies missing from ${target_ref}: ${missing[*]}" >&2
  exit 2
fi

echo "[deps-check] ok: all closed blocking dependencies are represented on ${target_ref}"
