#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  start.sh [count] [--runs N | --continuous] [--drain | --watch] [--no-work-retries N] [--reasoning-level LEVEL]

Options:
  count         Number of worker sessions/worktrees to launch (default: 2)
  --runs N      Maximum completed issue runs per agent loop (upper bound; may stop earlier)
  --continuous  Keep each loop unbounded (agent can request stop) (default)
  --drain       Stop loop on sustained queue exhaustion (`no_work`) (default)
  --watch       Keep loop running on `no_work` (poll/watch mode)
  --no-work-retries N
                Consecutive `no_work` retries before drain-stop in `--drain` mode (default: 1)
  --reasoning-level LEVEL
                Set `model_reasoning_effort` for default codex agent command
USAGE
}

COUNT=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_PREFIX="${SESSION_PREFIX:-orca-agent}"
AGENT_MODEL="${AGENT_MODEL:-gpt-5.3-codex}"
AGENT_REASONING_LEVEL="${AGENT_REASONING_LEVEL:-}"
AGENT_COMMAND_WAS_SET=0
if [[ -n "${AGENT_COMMAND+x}" ]]; then
  AGENT_COMMAND_WAS_SET=1
fi
AGENT_COMMAND="${AGENT_COMMAND:-codex exec --dangerously-bypass-approvals-and-sandbox --model ${AGENT_MODEL}}"
MAX_RUNS="${MAX_RUNS:-0}"
RUN_SLEEP_SECONDS="${RUN_SLEEP_SECONDS:-2}"
ORCA_TIMING_METRICS="${ORCA_TIMING_METRICS:-1}"
ORCA_COMPACT_SUMMARY="${ORCA_COMPACT_SUMMARY:-1}"
ORCA_LOCK_SCOPE="${ORCA_LOCK_SCOPE:-merge}"
ORCA_LOCK_TIMEOUT_SECONDS="${ORCA_LOCK_TIMEOUT_SECONDS:-120}"
ORCA_NO_WORK_DRAIN_MODE="${ORCA_NO_WORK_DRAIN_MODE:-drain}"
ORCA_NO_WORK_RETRY_LIMIT="${ORCA_NO_WORK_RETRY_LIMIT:-1}"
ORCA_MODE_ID="${ORCA_MODE_ID:-}"
ORCA_WORK_APPROACH_FILE="${ORCA_WORK_APPROACH_FILE:-}"
ORCA_FORCE_COUNT="${ORCA_FORCE_COUNT:-0}"
ORCA_ASSIGNMENT_MODE="${ORCA_ASSIGNMENT_MODE:-assigned}"
ORCA_BR_GUARD_MODE="${ORCA_BR_GUARD_MODE:-enforce}"
ORCA_ALLOW_UNSAFE_BR_MUTATIONS="${ORCA_ALLOW_UNSAFE_BR_MUTATIONS:-0}"
ORCA_BR_GUARD_PATH="${ORCA_BR_GUARD_PATH:-}"
ORCA_PRIMARY_REPO="${ORCA_PRIMARY_REPO:-}"
ORCA_WITH_LOCK_PATH="${ORCA_WITH_LOCK_PATH:-}"
ORCA_QUEUE_READ_MAIN_PATH="${ORCA_QUEUE_READ_MAIN_PATH:-}"
ORCA_QUEUE_WRITE_MAIN_PATH="${ORCA_QUEUE_WRITE_MAIN_PATH:-}"
ORCA_MERGE_MAIN_PATH="${ORCA_MERGE_MAIN_PATH:-}"
ORCA_DEP_SANITY_MODE="${ORCA_DEP_SANITY_MODE:-enforce}"
ORCA_DEP_SANITY_CHECK_PATH="${ORCA_DEP_SANITY_CHECK_PATH:-}"
ORCA_BASE_REF="${ORCA_BASE_REF:-}"

session_date_path() {
  local session_id="$1"
  local stamp

  if [[ "${session_id}" =~ ([0-9]{8})T[0-9]{6}Z ]]; then
    stamp="${BASH_REMATCH[1]}"
    printf '%s/%s/%s\n' "${stamp:0:4}" "${stamp:4:2}" "${stamp:6:2}"
    return 0
  fi

  date -u +%Y/%m/%d
}

ensure_br_workspace() {
  local doctor_output

  if [[ ! -d "${ROOT}/.beads" ]]; then
    echo "[start] missing .beads workspace in repo root: ${ROOT}/.beads" >&2
    echo "[start] run: br init && br config set id.prefix orca" >&2
    exit 1
  fi

  if doctor_output="$(br doctor 2>&1)"; then
    return 0
  fi

  echo "[start] br workspace check failed (br doctor)" >&2
  if [[ -n "${doctor_output}" ]]; then
    printf '%s\n' "${doctor_output}" | head -n 20 >&2
  fi
  echo "[start] fix the workspace above, then rerun start" >&2
  exit 1
}

check_prerequisites() {
  local missing=()
  local cmd
  local agent_command_bin

  for cmd in git tmux br jq flock; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if command -v br >/dev/null 2>&1; then
    if ! br --version >/dev/null 2>&1; then
      missing+=("br (installed but not executable)")
    fi
  fi

  agent_command_bin="${AGENT_COMMAND%% *}"
  if [[ -n "${agent_command_bin}" ]] && ! command -v "${agent_command_bin}" >/dev/null 2>&1; then
    missing+=("${agent_command_bin} (from AGENT_COMMAND)")
  fi

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "[start] missing prerequisites: ${missing[*]}" >&2
    exit 1
  fi
}

validate_explicit_base_ref() {
  local repo_path="$1"

  if [[ -z "${ORCA_BASE_REF}" ]]; then
    return 0
  fi

  if git -C "${repo_path}" rev-parse --verify --quiet "${ORCA_BASE_REF}^{commit}" >/dev/null 2>&1; then
    return 0
  fi

  echo "[start] ORCA_BASE_REF does not resolve to a commit: ${ORCA_BASE_REF}" >&2
  echo "[start] set ORCA_BASE_REF to a valid ref (for example: main, origin/main, or a commit SHA)" >&2
  return 1
}

worktree_is_clean() {
  local worktree="$1"
  [[ -z "$(git -C "${worktree}" status --porcelain --untracked-files=normal 2>/dev/null)" ]]
}

validate_worktree_readiness_for_start() {
  local index="$1"
  local session="${SESSION_PREFIX}-${index}"
  local worktree="${ROOT}/worktrees/agent-${index}"
  local branch_name
  local status_lines
  local line

  if tmux has-session -t "${session}" 2>/dev/null; then
    return 0
  fi

  if ! git -C "${worktree}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "[start] expected git worktree is missing or invalid: ${worktree}" >&2
    return 1
  fi

  if worktree_is_clean "${worktree}"; then
    return 0
  fi

  branch_name="$(git -C "${worktree}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  echo "[start] worktree is not clean and cannot safely create run branches: ${worktree}" >&2
  echo "[start] checked branch: ${branch_name:-unknown}" >&2
  echo "[start] fix: commit/stash/discard changes in this worktree, then rerun start" >&2
  status_lines="$(git -C "${worktree}" status --short 2>/dev/null || true)"
  if [[ -n "${status_lines}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      echo "[start]   ${line}" >&2
    done <<< "${status_lines}"
  fi

  return 1
}

validate_all_worktrees_before_launch() {
  local i
  local failed=0

  for i in $(seq 1 "${COUNT}"); do
    if ! validate_worktree_readiness_for_start "${i}"; then
      failed=1
    fi
  done

  if [[ "${failed}" -eq 1 ]]; then
    echo "[start] refusing to launch sessions until all non-running agent worktrees are clean" >&2
    exit 1
  fi
}

ready_issue_count() {
  local ready_json
  local ready_count

  if ! ready_json="$("${ORCA_QUEUE_READ_MAIN_PATH}" \
    --repo "${ORCA_PRIMARY_REPO}" \
    --lock-helper "${ORCA_WITH_LOCK_PATH}" \
    --scope "${ORCA_LOCK_SCOPE}" \
    --timeout "${ORCA_LOCK_TIMEOUT_SECONDS}" \
    --fallback error \
    --worktree "${ROOT}" \
    -- \
    br ready --json 2>/dev/null)"; then
    echo "[start] failed to query ready issues via queue-read-main helper" >&2
    return 1
  fi

  if ! ready_count="$(jq -re 'if type == "array" then length else error("ready output must be an array") end' <<< "${ready_json}" 2>/dev/null)"; then
    echo "[start] unable to parse ready issue count from queue-read-main helper output" >&2
    return 1
  fi

  printf '%s\n' "${ready_count}"
}

build_assignment_plan() {
  local slots="$1"
  local plan_dir
  local plan_path
  local plan_json

  plan_dir="${ROOT}/agent-logs/plans/$(date -u +%Y/%m/%d)"
  plan_path="${plan_dir}/start-plan-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"

  if ! plan_json="$("${SCRIPT_DIR}/plan.sh" \
    --slots "${slots}" \
    --output "${plan_path}" \
    --queue-read-helper "${ORCA_QUEUE_READ_MAIN_PATH}" \
    --primary-repo "${ORCA_PRIMARY_REPO}" \
    --lock-helper "${ORCA_WITH_LOCK_PATH}" \
    --scope "${ORCA_LOCK_SCOPE}" \
    --timeout "${ORCA_LOCK_TIMEOUT_SECONDS}")"; then
    echo "[start] planner failed for assigned mode (slots=${slots})" >&2
    return 1
  fi

  if ! jq -e '.assignments | type == "array"' >/dev/null 2>&1 <<< "${plan_json}"; then
    echo "[start] planner output missing assignments array" >&2
    return 1
  fi

  printf '%s\t%s\n' "${plan_path}" "${plan_json}"
}

run_dependency_sanity_check() {
  local report_dir
  local report_path
  local report_json
  local hazard_count

  if [[ "${ORCA_DEP_SANITY_MODE}" == "off" ]]; then
    echo "[start] dependency sanity check: skipped (mode=off)"
    return 0
  fi

  report_dir="${ROOT}/agent-logs/plans/$(date -u +%Y/%m/%d)"
  report_path="${report_dir}/dep-sanity-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"

  if ! report_json="$("${ORCA_DEP_SANITY_CHECK_PATH}" --output "${report_path}")"; then
    echo "[start] dependency sanity check failed to run (${ORCA_DEP_SANITY_CHECK_PATH})" >&2
    return 1
  fi

  if ! hazard_count="$(jq -re '.summary.hazard_count' <<< "${report_json}" 2>/dev/null)"; then
    echo "[start] dependency sanity check produced invalid output" >&2
    return 1
  fi

  echo "[start] dependency sanity: artifact=${report_path} hazards=${hazard_count} mode=${ORCA_DEP_SANITY_MODE}"
  if [[ "${hazard_count}" -gt 0 ]]; then
    while IFS= read -r hazard_line; do
      [[ -z "${hazard_line}" ]] && continue
      echo "[start] dependency hazard: ${hazard_line}" >&2
    done < <(jq -r '.hazards[] | "code=\(.code) details=\(.details | tojson)"' <<< "${report_json}")

    if [[ "${ORCA_DEP_SANITY_MODE}" == "enforce" ]]; then
      echo "[start] refusing to launch: dependency graph hazards detected (set ORCA_DEP_SANITY_MODE=warn to proceed intentionally)" >&2
      return 1
    fi
  fi

  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs)
      if [[ $# -lt 2 ]]; then
        echo "[start] --runs requires a numeric argument" >&2
        exit 1
      fi
      MAX_RUNS="$2"
      shift 2
      ;;
    --continuous)
      MAX_RUNS=0
      shift
      ;;
    --drain)
      ORCA_NO_WORK_DRAIN_MODE="drain"
      shift
      ;;
    --watch)
      ORCA_NO_WORK_DRAIN_MODE="watch"
      shift
      ;;
    --no-work-retries)
      if [[ $# -lt 2 ]]; then
        echo "[start] --no-work-retries requires a non-negative integer argument" >&2
        exit 1
      fi
      ORCA_NO_WORK_RETRY_LIMIT="$2"
      shift 2
      ;;
    --reasoning-level)
      if [[ $# -lt 2 ]]; then
        echo "[start] --reasoning-level requires an argument" >&2
        exit 1
      fi
      AGENT_REASONING_LEVEL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "${COUNT}" ]]; then
        COUNT="$1"
        shift
      else
        echo "[start] unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

COUNT="${COUNT:-2}"

check_prerequisites

ROOT="$(git rev-parse --show-toplevel)"
PROMPT_TEMPLATE="${PROMPT_TEMPLATE:-${ROOT}/AGENT_PROMPT.md}"
ORCA_PRIMARY_REPO="${ORCA_PRIMARY_REPO:-${ROOT}}"
ORCA_WITH_LOCK_PATH="${ORCA_WITH_LOCK_PATH:-${ROOT}/with-lock.sh}"
ORCA_QUEUE_READ_MAIN_PATH="${ORCA_QUEUE_READ_MAIN_PATH:-${ROOT}/queue-read-main.sh}"
ORCA_QUEUE_WRITE_MAIN_PATH="${ORCA_QUEUE_WRITE_MAIN_PATH:-${ROOT}/queue-write-main.sh}"
ORCA_MERGE_MAIN_PATH="${ORCA_MERGE_MAIN_PATH:-${ROOT}/merge-main.sh}"
ORCA_BR_GUARD_PATH="${ORCA_BR_GUARD_PATH:-${ROOT}/br-guard.sh}"
ORCA_DEP_SANITY_CHECK_PATH="${ORCA_DEP_SANITY_CHECK_PATH:-${ROOT}/dep-sanity.sh}"

if ! [[ "${COUNT}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[start] count must be a positive integer: ${COUNT}" >&2
  exit 1
fi

if ! [[ "${MAX_RUNS}" =~ ^[0-9]+$ ]]; then
  echo "[start] runs must be a non-negative integer: ${MAX_RUNS}" >&2
  exit 1
fi

if ! [[ "${RUN_SLEEP_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "[start] RUN_SLEEP_SECONDS must be a non-negative integer: ${RUN_SLEEP_SECONDS}" >&2
  exit 1
fi

if ! [[ "${ORCA_TIMING_METRICS}" =~ ^[01]$ ]]; then
  echo "[start] ORCA_TIMING_METRICS must be 0 or 1: ${ORCA_TIMING_METRICS}" >&2
  exit 1
fi

if ! [[ "${ORCA_COMPACT_SUMMARY}" =~ ^[01]$ ]]; then
  echo "[start] ORCA_COMPACT_SUMMARY must be 0 or 1: ${ORCA_COMPACT_SUMMARY}" >&2
  exit 1
fi

if ! [[ "${ORCA_LOCK_SCOPE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[start] ORCA_LOCK_SCOPE must contain only letters, digits, dot, underscore, or dash: ${ORCA_LOCK_SCOPE}" >&2
  exit 1
fi

if ! [[ "${ORCA_LOCK_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[start] ORCA_LOCK_TIMEOUT_SECONDS must be a positive integer: ${ORCA_LOCK_TIMEOUT_SECONDS}" >&2
  exit 1
fi

if [[ "${ORCA_NO_WORK_DRAIN_MODE}" != "drain" && "${ORCA_NO_WORK_DRAIN_MODE}" != "watch" ]]; then
  echo "[start] ORCA_NO_WORK_DRAIN_MODE must be 'drain' or 'watch': ${ORCA_NO_WORK_DRAIN_MODE}" >&2
  exit 1
fi

if ! [[ "${ORCA_NO_WORK_RETRY_LIMIT}" =~ ^[0-9]+$ ]]; then
  echo "[start] ORCA_NO_WORK_RETRY_LIMIT must be a non-negative integer: ${ORCA_NO_WORK_RETRY_LIMIT}" >&2
  exit 1
fi

if ! [[ "${ORCA_FORCE_COUNT}" =~ ^[01]$ ]]; then
  echo "[start] ORCA_FORCE_COUNT must be 0 or 1: ${ORCA_FORCE_COUNT}" >&2
  exit 1
fi

if [[ "${ORCA_BR_GUARD_MODE}" != "enforce" && "${ORCA_BR_GUARD_MODE}" != "off" ]]; then
  echo "[start] ORCA_BR_GUARD_MODE must be 'enforce' or 'off': ${ORCA_BR_GUARD_MODE}" >&2
  exit 1
fi

if ! [[ "${ORCA_ALLOW_UNSAFE_BR_MUTATIONS}" =~ ^[01]$ ]]; then
  echo "[start] ORCA_ALLOW_UNSAFE_BR_MUTATIONS must be 0 or 1: ${ORCA_ALLOW_UNSAFE_BR_MUTATIONS}" >&2
  exit 1
fi

if [[ "${ORCA_ASSIGNMENT_MODE}" != "assigned" && "${ORCA_ASSIGNMENT_MODE}" != "self-select" ]]; then
  echo "[start] ORCA_ASSIGNMENT_MODE must be 'assigned' or 'self-select': ${ORCA_ASSIGNMENT_MODE}" >&2
  exit 1
fi

if [[ "${ORCA_DEP_SANITY_MODE}" != "enforce" && "${ORCA_DEP_SANITY_MODE}" != "warn" && "${ORCA_DEP_SANITY_MODE}" != "off" ]]; then
  echo "[start] ORCA_DEP_SANITY_MODE must be 'enforce', 'warn', or 'off': ${ORCA_DEP_SANITY_MODE}" >&2
  exit 1
fi

if [[ -n "${ORCA_MODE_ID}" && ! "${ORCA_MODE_ID}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[start] ORCA_MODE_ID must contain only letters, digits, dot, underscore, or dash: ${ORCA_MODE_ID}" >&2
  exit 1
fi

if [[ -n "${AGENT_REASONING_LEVEL}" && ! "${AGENT_REASONING_LEVEL}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[start] reasoning level must contain only letters, digits, dot, underscore, or dash: ${AGENT_REASONING_LEVEL}" >&2
  exit 1
fi

if [[ -n "${AGENT_REASONING_LEVEL}" ]]; then
  if [[ "${AGENT_COMMAND_WAS_SET}" -eq 1 ]]; then
    echo "[start] AGENT_COMMAND override detected; --reasoning-level will not modify AGENT_COMMAND" >&2
  else
    AGENT_COMMAND="${AGENT_COMMAND} -c model_reasoning_effort=${AGENT_REASONING_LEVEL}"
  fi
fi

if [[ ! -f "${PROMPT_TEMPLATE}" ]]; then
  echo "[start] missing prompt template: ${PROMPT_TEMPLATE}" >&2
  exit 1
fi

if ! git -C "${ORCA_PRIMARY_REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[start] ORCA_PRIMARY_REPO does not look like a git worktree: ${ORCA_PRIMARY_REPO}" >&2
  exit 1
fi

if [[ ! -x "${ORCA_WITH_LOCK_PATH}" ]]; then
  echo "[start] ORCA_WITH_LOCK_PATH must be executable: ${ORCA_WITH_LOCK_PATH}" >&2
  exit 1
fi

if [[ ! -x "${ORCA_QUEUE_READ_MAIN_PATH}" ]]; then
  echo "[start] ORCA_QUEUE_READ_MAIN_PATH must be executable: ${ORCA_QUEUE_READ_MAIN_PATH}" >&2
  exit 1
fi

if [[ ! -x "${ORCA_QUEUE_WRITE_MAIN_PATH}" ]]; then
  echo "[start] ORCA_QUEUE_WRITE_MAIN_PATH must be executable: ${ORCA_QUEUE_WRITE_MAIN_PATH}" >&2
  exit 1
fi

if [[ ! -x "${ORCA_MERGE_MAIN_PATH}" ]]; then
  echo "[start] ORCA_MERGE_MAIN_PATH must be executable: ${ORCA_MERGE_MAIN_PATH}" >&2
  exit 1
fi

if [[ ! -x "${ORCA_BR_GUARD_PATH}" ]]; then
  echo "[start] ORCA_BR_GUARD_PATH must be executable: ${ORCA_BR_GUARD_PATH}" >&2
  exit 1
fi

if [[ "${ORCA_DEP_SANITY_MODE}" != "off" && ! -x "${ORCA_DEP_SANITY_CHECK_PATH}" ]]; then
  echo "[start] ORCA_DEP_SANITY_CHECK_PATH must be executable when sanity check is enabled: ${ORCA_DEP_SANITY_CHECK_PATH}" >&2
  exit 1
fi

if ! validate_explicit_base_ref "${ROOT}"; then
  exit 1
fi

ensure_br_workspace

if [[ "${MAX_RUNS}" -eq 0 ]]; then
  mode_message="continuous (agent stop + no_work mode=${ORCA_NO_WORK_DRAIN_MODE}, retries=${ORCA_NO_WORK_RETRY_LIMIT})"
else
  mode_message="max ${MAX_RUNS} runs per agent (upper bound; no_work mode=${ORCA_NO_WORK_DRAIN_MODE}, retries=${ORCA_NO_WORK_RETRY_LIMIT})"
fi

echo "[start] run mode: ${mode_message}"

"${SCRIPT_DIR}/setup-worktrees.sh" "${COUNT}"
validate_all_worktrees_before_launch
run_dependency_sanity_check

running_sessions=0
launch_candidates=0
for i in $(seq 1 "${COUNT}"); do
  session="${SESSION_PREFIX}-${i}"
  if tmux has-session -t "${session}" 2>/dev/null; then
    ((running_sessions += 1))
  else
    ((launch_candidates += 1))
  fi
done

ready_count="$(ready_issue_count)"
if [[ "${ORCA_ASSIGNMENT_MODE}" == "assigned" ]]; then
  launch_limit="${ready_count}"
  if [[ "${launch_limit}" -gt "${launch_candidates}" ]]; then
    launch_limit="${launch_candidates}"
  fi
elif [[ "${ORCA_FORCE_COUNT}" -eq 1 ]]; then
  launch_limit="${launch_candidates}"
else
  launch_limit="${ready_count}"
  if [[ "${launch_limit}" -gt "${launch_candidates}" ]]; then
    launch_limit="${launch_candidates}"
  fi
fi

echo "[start] launch planning: requested=${COUNT} running=${running_sessions} ready=${ready_count} launchable=${launch_candidates} launching=${launch_limit} force_count=${ORCA_FORCE_COUNT} assignment_mode=${ORCA_ASSIGNMENT_MODE}"

ready_ids=()
if [[ "${ORCA_ASSIGNMENT_MODE}" == "assigned" && "${launch_limit}" -gt 0 ]]; then
  requested_assignment_slots="${launch_limit}"
  assignment_plan_bundle="$(build_assignment_plan "${launch_limit}")"
  assignment_plan_path="${assignment_plan_bundle%%$'\t'*}"
  assignment_plan_json="${assignment_plan_bundle#*$'\t'}"
  mapfile -t ready_ids < <(jq -re '.assignments[].issue_id' <<< "${assignment_plan_json}")
  plan_held_count="$(jq -re '.held | length' <<< "${assignment_plan_json}")"
  launch_limit="${#ready_ids[@]}"
  echo "[start] assignment plan: artifact=${assignment_plan_path} requested_slots=${requested_assignment_slots} assigned=${launch_limit} held=${plan_held_count}"
  while IFS= read -r assignment_line; do
    [[ -z "${assignment_line}" ]] && continue
    echo "[start] assignment plan: ${assignment_line}"
  done < <(jq -r '.assignments[] | "slot=\(.slot) issue=\(.issue_id) priority=\(.priority // "null")"' <<< "${assignment_plan_json}")
  while IFS= read -r held_line; do
    [[ -z "${held_line}" ]] && continue
    echo "[start] assignment held: ${held_line}"
  done < <(jq -r '.held[] | "issue=\(.issue_id) reason=\(.reason_code)\(if has("conflict_key") then " conflict_key=\(.conflict_key)" else "" end)"' <<< "${assignment_plan_json}")
  while IFS= read -r decision_line; do
    [[ -z "${decision_line}" ]] && continue
    echo "[start] assignment decision: ${decision_line}"
  done < <(jq -r '.decisions[] | "issue=\(.issue_id) action=\(.action) reason=\(.reason_code)\(if has("conflict_key") then " conflict_key=\(.conflict_key)" else "" end)"' <<< "${assignment_plan_json}")
  if [[ "${launch_limit}" -lt "${requested_assignment_slots}" ]]; then
    plan_held_summary="$(jq -r '[.held[].reason_code] | group_by(.) | map("\(.[0])=\(length)") | join(",")' <<< "${assignment_plan_json}")"
    if [[ -z "${plan_held_summary}" ]]; then
      plan_held_summary="none"
    fi
    echo "[start] assignment plan: assigned fewer sessions than requested_slots=${requested_assignment_slots}; held_reason_counts=${plan_held_summary}"
  fi
fi

launched_count=0
for i in $(seq 1 "${COUNT}"); do
  session="${SESSION_PREFIX}-${i}"
  session_id="${session}-$(date -u +%Y%m%dT%H%M%SZ)"
  worktree="${ROOT}/worktrees/agent-${i}"
  assigned_issue_id=""

  if tmux has-session -t "${session}" 2>/dev/null; then
    echo "[start] session ${session} already running"
    continue
  fi

  if [[ "${launched_count}" -ge "${launch_limit}" ]]; then
    echo "[start] skipping ${session}: launch cap reached"
    continue
  fi

  if [[ "${ORCA_ASSIGNMENT_MODE}" == "assigned" ]]; then
    ready_index="${launched_count}"
    if [[ "${ready_index}" -lt "${#ready_ids[@]}" ]]; then
      assigned_issue_id="${ready_ids[ready_index]}"
    fi
    if [[ -z "${assigned_issue_id}" ]]; then
      echo "[start] skipping ${session}: no assigned issue available under assignment mode" >&2
      continue
    fi
  fi

  echo "[start] launching ${session} in ${worktree}"
  tmux_cmd="$(printf "cd %q && AGENT_NAME=%q AGENT_SESSION_ID=%q WORKTREE=%q AGENT_MODEL=%q AGENT_REASONING_LEVEL=%q AGENT_COMMAND=%q PROMPT_TEMPLATE=%q MAX_RUNS=%q RUN_SLEEP_SECONDS=%q ORCA_TIMING_METRICS=%q ORCA_COMPACT_SUMMARY=%q ORCA_ASSIGNMENT_MODE=%q ORCA_ASSIGNED_ISSUE_ID=%q ORCA_PRIMARY_REPO=%q ORCA_WITH_LOCK_PATH=%q ORCA_LOCK_SCOPE=%q ORCA_LOCK_TIMEOUT_SECONDS=%q ORCA_NO_WORK_DRAIN_MODE=%q ORCA_NO_WORK_RETRY_LIMIT=%q ORCA_MODE_ID=%q ORCA_WORK_APPROACH_FILE=%q ORCA_QUEUE_READ_MAIN_PATH=%q ORCA_QUEUE_WRITE_MAIN_PATH=%q ORCA_MERGE_MAIN_PATH=%q ORCA_BR_GUARD_MODE=%q ORCA_ALLOW_UNSAFE_BR_MUTATIONS=%q ORCA_BR_GUARD_PATH=%q ORCA_BASE_REF=%q %q" \
    "${ROOT}" \
    "agent-${i}" \
    "${session_id}" \
    "${worktree}" \
    "${AGENT_MODEL}" \
    "${AGENT_REASONING_LEVEL}" \
    "${AGENT_COMMAND}" \
    "${PROMPT_TEMPLATE}" \
    "${MAX_RUNS}" \
    "${RUN_SLEEP_SECONDS}" \
    "${ORCA_TIMING_METRICS}" \
    "${ORCA_COMPACT_SUMMARY}" \
    "${ORCA_ASSIGNMENT_MODE}" \
    "${assigned_issue_id}" \
    "${ORCA_PRIMARY_REPO}" \
    "${ORCA_WITH_LOCK_PATH}" \
    "${ORCA_LOCK_SCOPE}" \
    "${ORCA_LOCK_TIMEOUT_SECONDS}" \
    "${ORCA_NO_WORK_DRAIN_MODE}" \
    "${ORCA_NO_WORK_RETRY_LIMIT}" \
    "${ORCA_MODE_ID}" \
    "${ORCA_WORK_APPROACH_FILE}" \
    "${ORCA_QUEUE_READ_MAIN_PATH}" \
    "${ORCA_QUEUE_WRITE_MAIN_PATH}" \
    "${ORCA_MERGE_MAIN_PATH}" \
    "${ORCA_BR_GUARD_MODE}" \
    "${ORCA_ALLOW_UNSAFE_BR_MUTATIONS}" \
    "${ORCA_BR_GUARD_PATH}" \
    "${ORCA_BASE_REF}" \
    "${SCRIPT_DIR}/agent-loop.sh")"
  tmux new-session -d -s "${session}" "${tmux_cmd}"
  ((launched_count += 1))

  sleep 1
  if ! tmux has-session -t "${session}" 2>/dev/null; then
    session_log="${ROOT}/agent-logs/sessions/$(session_date_path "${session_id}")/${session_id}/session.log"
    echo "[start] warning: ${session} exited during startup" >&2
    if [[ -f "${session_log}" ]]; then
      echo "[start] recent startup log (${session_log}):" >&2
      tail -n 20 "${session_log}" >&2 || true
    else
      echo "[start] no session log found yet; inspect agent-logs/sessions/" >&2
    fi
  fi
done

echo "[start] launch summary: requested=${COUNT} running=${running_sessions} ready=${ready_count} launched=${launched_count}"

echo "[start] running sessions:"
tmux ls | grep "^${SESSION_PREFIX}-" || true
