#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}" && git rev-parse --show-toplevel)"

usage() {
  cat <<'USAGE'
Usage:
  dep-sanity.sh [--issues-jsonl PATH] [--output PATH] [--strict]

Options:
  --issues-jsonl PATH  Queue issues snapshot path (default: .beads/issues.jsonl)
  --output PATH        Also write JSON report to PATH
  --strict             Exit non-zero when hazards are found
USAGE
}

ISSUES_JSONL_PATH="${ROOT}/.beads/issues.jsonl"
OUTPUT_PATH=""
STRICT_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issues-jsonl)
      if [[ $# -lt 2 ]]; then
        echo "[dep-sanity] --issues-jsonl requires a path argument" >&2
        exit 1
      fi
      ISSUES_JSONL_PATH="$2"
      shift 2
      ;;
    --output)
      if [[ $# -lt 2 ]]; then
        echo "[dep-sanity] --output requires a path argument" >&2
        exit 1
      fi
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --strict)
      STRICT_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[dep-sanity] unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "[dep-sanity] missing prerequisite: jq" >&2
  exit 1
fi

if [[ ! -f "${ISSUES_JSONL_PATH}" ]]; then
  echo "[dep-sanity] issues snapshot not found: ${ISSUES_JSONL_PATH}" >&2
  exit 1
fi

issues_json="$(jq -sc '.' "${ISSUES_JSONL_PATH}")"
if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "${issues_json}"; then
  echo "[dep-sanity] issues snapshot must parse to a JSON array" >&2
  exit 1
fi

issue_count="$(jq -r 'length' <<< "${issues_json}")"
dependency_count="$(jq -r '[.[] | (.dependencies // [])[]?] | length' <<< "${issues_json}")"

declare -A issue_status=()
declare -A active_issues=()
declare -A active_nodes_present=()
declare -A indegree=()
declare -A adjacency=()
declare -A active_blocks_edge=()
declare -A undirected_types=()
declare -a hazards=()

is_active_status() {
  local status="$1"
  [[ "${status}" == "open" || "${status}" == "in_progress" || "${status}" == "blocked" ]]
}

add_hazard() {
  local code="$1"
  local details_json="$2"
  hazards+=("{\"code\":\"${code}\",\"severity\":\"error\",\"details\":${details_json}}")
}

while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  id="$(jq -r '.id // empty' <<< "${line}")"
  status="$(jq -r '.status // "open"' <<< "${line}")"
  if [[ -z "${id}" ]]; then
    continue
  fi
  issue_status["${id}"]="${status}"
  if is_active_status "${status}"; then
    active_issues["${id}"]=1
    active_nodes_present["${id}"]=1
    indegree["${id}"]="${indegree[${id}]:-0}"
    adjacency["${id}"]="${adjacency[${id}]:-}"
  fi
done < <(jq -c '.[] | {id, status}' <<< "${issues_json}")

while IFS= read -r dep; do
  [[ -z "${dep}" ]] && continue

  from_id="$(jq -r '.issue_id // empty' <<< "${dep}")"
  to_id="$(jq -r '.depends_on_id // empty' <<< "${dep}")"
  dep_type="$(jq -r '.type // "blocks"' <<< "${dep}")"

  if [[ -z "${from_id}" || -z "${to_id}" ]]; then
    continue
  fi

  if [[ "${from_id}" < "${to_id}" ]]; then
    undirected_key="${from_id}|${to_id}"
  else
    undirected_key="${to_id}|${from_id}"
  fi
  existing_types="${undirected_types[${undirected_key}]:-}"
  if [[ -z "${existing_types}" ]]; then
    undirected_types["${undirected_key}"]="${dep_type}"
  elif [[ ",${existing_types}," != *",${dep_type},"* ]]; then
    undirected_types["${undirected_key}"]="${existing_types},${dep_type}"
  fi

  if [[ -n "${active_issues[${from_id}]:-}" && -n "${active_issues[${to_id}]:-}" ]]; then
    if [[ "${from_id}" == "${to_id}" ]]; then
      add_hazard "self-dependency-active" "$(jq -cn --arg issue_id "${from_id}" --arg type "${dep_type}" '{issue_id: $issue_id, type: $type}')"
      continue
    fi

    active_nodes_present["${from_id}"]=1
    active_nodes_present["${to_id}"]=1
    adjacency["${from_id}"]+="${to_id}"$'\n'
    indegree["${to_id}"]=$(( ${indegree[${to_id}]:-0} + 1 ))
    indegree["${from_id}"]="${indegree[${from_id}]:-0}"

    if [[ "${dep_type}" == "blocks" ]]; then
      active_blocks_edge["${from_id}|${to_id}"]=1
    fi
  fi
done < <(jq -c '.[] | (.dependencies // [])[]? | {issue_id, depends_on_id, type}' <<< "${issues_json}")

for pair_key in "${!undirected_types[@]}"; do
  pair_types="${undirected_types[${pair_key}]}"
  if [[ ",${pair_types}," == *",parent-child,"* && ",${pair_types}," == *",blocks,"* ]]; then
    left_id="${pair_key%%|*}"
    right_id="${pair_key#*|}"
    add_hazard "mixed-parent-child-blocks" "$(jq -cn \
      --arg left_id "${left_id}" \
      --arg right_id "${right_id}" \
      '{issue_a: $left_id, issue_b: $right_id}')"
  fi
done

for edge_key in "${!active_blocks_edge[@]}"; do
  from_id="${edge_key%%|*}"
  to_id="${edge_key#*|}"
  if [[ -n "${active_blocks_edge[${to_id}|${from_id}]:-}" && "${from_id}" < "${to_id}" ]]; then
    add_hazard "mutual-blocks-active" "$(jq -cn \
      --arg issue_a "${from_id}" \
      --arg issue_b "${to_id}" \
      '{issue_a: $issue_a, issue_b: $issue_b}')"
  fi
done

declare -A queued=()
declare -a queue=()
for node_id in "${!active_nodes_present[@]}"; do
  if [[ "${indegree[${node_id}]:-0}" -eq 0 ]]; then
    queue+=("${node_id}")
    queued["${node_id}"]=1
  fi
done
IFS=$'\n' queue=($(printf '%s\n' "${queue[@]}" | sort))
unset IFS

removed_count=0
while [[ "${#queue[@]}" -gt 0 ]]; do
  current="${queue[0]}"
  queue=("${queue[@]:1}")
  ((removed_count += 1))

  mapfile -t neighbors < <(printf '%s' "${adjacency[${current}]:-}" | awk 'NF {print}' | sort -u)
  for neighbor in "${neighbors[@]}"; do
    if [[ -z "${neighbor}" ]]; then
      continue
    fi
    indegree["${neighbor}"]=$(( ${indegree[${neighbor}]:-0} - 1 ))
    if [[ "${indegree[${neighbor}]}" -eq 0 && -z "${queued[${neighbor}]:-}" ]]; then
      queue+=("${neighbor}")
      queued["${neighbor}"]=1
    fi
  done
  if [[ "${#queue[@]}" -gt 1 ]]; then
    IFS=$'\n' queue=($(printf '%s\n' "${queue[@]}" | sort))
    unset IFS
  fi
done

total_active_nodes="${#active_nodes_present[@]}"
if [[ "${removed_count}" -lt "${total_active_nodes}" ]]; then
  cycle_nodes=()
  for node_id in "${!active_nodes_present[@]}"; do
    if [[ "${indegree[${node_id}]:-0}" -gt 0 ]]; then
      cycle_nodes+=("${node_id}")
    fi
  done
  if [[ "${#cycle_nodes[@]}" -gt 0 ]]; then
    IFS=$'\n' cycle_nodes=($(printf '%s\n' "${cycle_nodes[@]}" | sort))
    unset IFS
    cycle_nodes_json="$(printf '%s\n' "${cycle_nodes[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    add_hazard "active-dependency-cycle" "$(jq -cn --argjson cycle_nodes "${cycle_nodes_json}" '{cycle_nodes: $cycle_nodes}')"
  fi
fi

hazards_json='[]'
if [[ "${#hazards[@]}" -gt 0 ]]; then
  hazards_json="$(printf '%s\n' "${hazards[@]}" | jq -sc 'sort_by(.code, (.details.issue_id // ""), (.details.issue_a // ""), (.details.issue_b // ""))')"
fi
hazard_count="$(jq -r 'length' <<< "${hazards_json}")"

report_json="$(jq -n \
  --arg issues_jsonl "${ISSUES_JSONL_PATH}" \
  --argjson issue_count "${issue_count}" \
  --argjson dependency_count "${dependency_count}" \
  --argjson hazards "${hazards_json}" \
  --argjson strict "${STRICT_MODE}" \
  '{
    checker_version: "v1",
    input: {
      issues_jsonl: $issues_jsonl,
      issue_count: $issue_count,
      dependency_count: $dependency_count
    },
    hazards: $hazards,
    summary: {
      hazard_count: ($hazards | length),
      strict_mode: ($strict == 1)
    }
  }')"

if [[ -n "${OUTPUT_PATH}" ]]; then
  mkdir -p "$(dirname "${OUTPUT_PATH}")"
  printf '%s\n' "${report_json}" > "${OUTPUT_PATH}"
fi

printf '%s\n' "${report_json}"

if [[ "${STRICT_MODE}" -eq 1 && "${hazard_count}" -gt 0 ]]; then
  exit 2
fi
