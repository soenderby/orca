#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
WORKTREE_DIR="${TMP_DIR}/worktree"

cleanup() {
  git -C "${ROOT}" worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

git -C "${ROOT}" worktree add --detach "${WORKTREE_DIR}" HEAD >/dev/null
cp "${ROOT}/status.sh" "${WORKTREE_DIR}/status.sh"

mkdir -p "${WORKTREE_DIR}/agent-logs/sessions/2026/03/11"
mkdir -p "${TMP_DIR}/bin"

SESSION_1="orca-agent-1-20260311T070000Z"
SESSION_2="orca-agent-2-20260311T070500Z"

cat > "${WORKTREE_DIR}/agent-logs/metrics.jsonl" <<JSON
{"timestamp":"2026-03-11T07:00:30Z","agent_name":"agent-1","session_id":"${SESSION_1}","result":"completed","issue_id":"orca-a1","durations_seconds":{"iteration_total":12},"tokens_used":123}
{"timestamp":"2026-03-11T07:05:30Z","agent_name":"agent-2","session_id":"${SESSION_2}","result":"completed","issue_id":"orca-a2","durations_seconds":{"iteration_total":8},"tokens_used":222}
JSON

for session_id in "${SESSION_1}" "${SESSION_2}"; do
  run_dir="${WORKTREE_DIR}/agent-logs/sessions/2026/03/11/${session_id}/runs/0001-20260311T070000000000000Z"
  mkdir -p "${run_dir}"
  agent_name="agent-1"
  if [[ "${session_id}" == "${SESSION_2}" ]]; then
    agent_name="agent-2"
  fi
  cat > "${WORKTREE_DIR}/agent-logs/sessions/2026/03/11/${session_id}/session.log" <<LOG
[2026-03-11T07:00:00Z] [${agent_name}] starting loop
LOG
done

cat > "${WORKTREE_DIR}/agent-logs/sessions/2026/03/11/${SESSION_1}/runs/0001-20260311T070000000000000Z/run.log" <<'LOG'
[2026-03-11T07:00:10Z] [agent-1] running agent command
LOG

cat > "${WORKTREE_DIR}/agent-logs/sessions/2026/03/11/${SESSION_2}/runs/0001-20260311T070000000000000Z/run.log" <<'LOG'
[2026-03-11T07:05:10Z] [agent-2] running agent command
[2026-03-11T07:05:20Z] [agent-2] agent command exited with 0 after 10s
LOG

cat > "${TMP_DIR}/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "ls" && "${2:-}" == "-F" && "${3:-}" == "#S" ]]; then
  printf '%s\n' "orca-agent-1" "orca-agent-2"
  exit 0
fi
if [[ "$1" == "ls" ]]; then
  printf '%s\n' "orca-agent-1: 1 windows (created Wed Mar 11 07:00:00 2026)"
  printf '%s\n' "orca-agent-2: 1 windows (created Wed Mar 11 07:05:00 2026)"
  exit 0
fi
exit 1
TMUX
chmod +x "${TMP_DIR}/bin/tmux"

quick_output="$(cd "${WORKTREE_DIR}" && PATH="${TMP_DIR}/bin:/usr/bin:/bin" bash ./status.sh --quick)"
if ! printf '%s\n' "${quick_output}" | grep -F "active runs (scoped): 1/2" >/dev/null; then
  echo "expected active running session count in quick status" >&2
  exit 1
fi
if ! printf '%s\n' "${quick_output}" | grep -F "session=${SESSION_1}" | grep -F "state=running" >/dev/null; then
  echo "expected running state for first session" >&2
  exit 1
fi

session_id_output="$(cd "${WORKTREE_DIR}" && PATH="${TMP_DIR}/bin:/usr/bin:/bin" bash ./status.sh --quick --session-id "${SESSION_1}")"
if ! printf '%s\n' "${session_id_output}" | grep -F "active runs (scoped): 1/1" >/dev/null; then
  echo "expected scoped active run count for exact session id" >&2
  exit 1
fi
if ! printf '%s\n' "${session_id_output}" | grep -F "latest activity:" | grep -F "agent=agent-1" >/dev/null; then
  echo "expected latest activity to be scoped to selected session id" >&2
  exit 1
fi

session_prefix_output="$(cd "${WORKTREE_DIR}" && PATH="${TMP_DIR}/bin:/usr/bin:/bin" bash ./status.sh --quick --session-prefix "orca-agent-2-")"
if ! printf '%s\n' "${session_prefix_output}" | grep -F "active runs (scoped): 0/1" >/dev/null; then
  echo "expected scoped active run count for session prefix filter" >&2
  exit 1
fi
if ! printf '%s\n' "${session_prefix_output}" | grep -F "latest activity:" | grep -F "agent=agent-2" >/dev/null; then
  echo "expected latest activity to be scoped to selected session prefix" >&2
  exit 1
fi

json_output="$(cd "${WORKTREE_DIR}" && PATH="${TMP_DIR}/bin:/usr/bin:/bin" bash ./status.sh --quick --json --session-id "${SESSION_1}")"
if [[ "$(printf '%s\n' "${json_output}" | jq -r '.schema_version')" != "orca.status.v1" ]]; then
  echo "expected schema_version in quick json output" >&2
  exit 1
fi
if [[ "$(printf '%s\n' "${json_output}" | jq -r '.session_scope.id')" != "${SESSION_1}" ]]; then
  echo "expected session scope id in quick json output" >&2
  exit 1
fi
if [[ "$(printf '%s\n' "${json_output}" | jq -r '.signals.active_running_count')" != "1" ]]; then
  echo "expected scoped active running count in quick json output" >&2
  exit 1
fi

echo "status session scope and run-progress check passed"
