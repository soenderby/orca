#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}" && git rev-parse --show-toplevel)"

usage() {
  cat <<'USAGE'
Usage:
  plan.sh [--slots N] [--output PATH] [--ready-json PATH] [--issues-jsonl PATH]

Options:
  --slots N         Max assignments to include in the plan (default: 1)
  --output PATH     Also write JSON plan artifact to PATH
  --ready-json PATH Read ready issues JSON array from PATH instead of `br ready --json`
  --issues-jsonl PATH
                    Read queue issue snapshot from PATH (default: .beads/issues.jsonl)
USAGE
}

SLOTS=1
OUTPUT_PATH=""
READY_JSON_PATH=""
ISSUES_JSONL_PATH="${ROOT}/.beads/issues.jsonl"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slots)
      if [[ $# -lt 2 ]]; then
        echo "[plan] --slots requires a numeric argument" >&2
        exit 1
      fi
      SLOTS="$2"
      shift 2
      ;;
    --output)
      if [[ $# -lt 2 ]]; then
        echo "[plan] --output requires a path argument" >&2
        exit 1
      fi
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --ready-json)
      if [[ $# -lt 2 ]]; then
        echo "[plan] --ready-json requires a path argument" >&2
        exit 1
      fi
      READY_JSON_PATH="$2"
      shift 2
      ;;
    --issues-jsonl)
      if [[ $# -lt 2 ]]; then
        echo "[plan] --issues-jsonl requires a path argument" >&2
        exit 1
      fi
      ISSUES_JSONL_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[plan] unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! [[ "${SLOTS}" =~ ^[0-9]+$ ]]; then
  echo "[plan] --slots must be a non-negative integer: ${SLOTS}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[plan] missing prerequisite: jq" >&2
  exit 1
fi

if [[ ! -f "${ISSUES_JSONL_PATH}" ]]; then
  echo "[plan] issues snapshot not found: ${ISSUES_JSONL_PATH}" >&2
  exit 1
fi

ready_json=""
if [[ -n "${READY_JSON_PATH}" ]]; then
  if [[ ! -f "${READY_JSON_PATH}" ]]; then
    echo "[plan] ready JSON path not found: ${READY_JSON_PATH}" >&2
    exit 1
  fi
  ready_json="$(cat "${READY_JSON_PATH}")"
else
  if ! ready_json="$(br ready --json 2>/dev/null)"; then
    echo "[plan] failed to query ready issues via br ready --json" >&2
    exit 1
  fi
fi

if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "${ready_json}"; then
  echo "[plan] ready issues JSON must be an array" >&2
  exit 1
fi

issue_labels_json="$(jq -sc '
  reduce .[] as $issue
    ({};
      .[$issue.id] = (($issue.labels // []) | map(select(type == "string")))
    )
' "${ISSUES_JSONL_PATH}")"

plan_json="$(jq -n \
  --argjson slots "${SLOTS}" \
  --argjson ready "${ready_json}" \
  --argjson issue_labels "${issue_labels_json}" '
    def labels_for($id): ($issue_labels[$id] // []);
    def ck_keys($labels): [ $labels[] | select(startswith("ck:")) | sub("^ck:"; "") ] | unique | sort;
    def intersects($left; $right): [ $left[] | select($right | index(.) != null) ];

    ($ready | sort_by((.priority // 2147483647), (.created_at // ""), .id)) as $sorted
    | reduce $sorted[] as $issue (
        {
          slots: $slots,
          assigned_items: [],
          held_items: [],
          decisions: [],
          used_contention_keys: [],
          has_exclusive_assignment: false
        };
        ($issue.id) as $issue_id
        | (labels_for($issue_id)) as $labels
        | ($labels | index("px:exclusive") != null) as $is_exclusive
        | ck_keys($labels) as $issue_ck
        | intersects($issue_ck; .used_contention_keys) as $shared_ck
        | if (.assigned_items | length) >= .slots then
            .held_items += [{ issue_id: $issue_id, reason_code: "not-enough-slots" }]
            | .decisions += [{
                issue_id: $issue_id,
                action: "held",
                reason_code: "not-enough-slots",
                labels: $labels
              }]
          elif .has_exclusive_assignment then
            .held_items += [{ issue_id: $issue_id, reason_code: "exclusive-already-selected" }]
            | .decisions += [{
                issue_id: $issue_id,
                action: "held",
                reason_code: "exclusive-already-selected",
                labels: $labels
              }]
          elif $is_exclusive and ((.assigned_items | length) > 0) then
            .held_items += [{ issue_id: $issue_id, reason_code: "exclusive-conflict" }]
            | .decisions += [{
                issue_id: $issue_id,
                action: "held",
                reason_code: "exclusive-conflict",
                labels: $labels
              }]
          elif ($shared_ck | length) > 0 then
            .held_items += [{
                issue_id: $issue_id,
                reason_code: "contention-key-conflict",
                conflict_key: ($shared_ck[0])
              }]
            | .decisions += [{
                issue_id: $issue_id,
                action: "held",
                reason_code: "contention-key-conflict",
                conflict_key: ($shared_ck[0]),
                labels: $labels
              }]
          else
            .assigned_items += [{
                issue_id: $issue_id,
                priority: ($issue.priority // null),
                created_at: ($issue.created_at // null),
                labels: $labels
              }]
            | .decisions += [{
                issue_id: $issue_id,
                action: "assigned",
                reason_code: "scheduled",
                labels: $labels
              }]
            | if $is_exclusive then
                .has_exclusive_assignment = true
              else
                .
              end
            | .used_contention_keys = ((.used_contention_keys + $issue_ck) | unique | sort)
          end
      )
    | {
        planner_version: "v1",
        input: {
          slots: .slots,
          ready_count: ($sorted | length)
        },
        assignments: (
          .assigned_items
          | to_entries
          | map({
              slot: (.key + 1),
              issue_id: .value.issue_id,
              priority: .value.priority,
              created_at: .value.created_at,
              labels: .value.labels
            })
        ),
        held: .held_items,
        decisions: .decisions
      }
  ')"

if [[ -n "${OUTPUT_PATH}" ]]; then
  mkdir -p "$(dirname "${OUTPUT_PATH}")"
  printf '%s\n' "${plan_json}" > "${OUTPUT_PATH}"
fi

printf '%s\n' "${plan_json}"
