#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
WORKTREE_DIR="${TMP_DIR}/worktree"
STUB_BIN_DIR="${TMP_DIR}/bin"
TMUX_MODE_FILE="${TMP_DIR}/tmux-mode"
OUT_FILE="${TMP_DIR}/follow.jsonl"

cleanup() {
  git -C "${ROOT}" worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

git -C "${ROOT}" worktree add --detach "${WORKTREE_DIR}" HEAD >/dev/null
cp "${ROOT}/status.sh" "${WORKTREE_DIR}/status.sh"
chmod +x "${WORKTREE_DIR}/status.sh"
mkdir -p "${STUB_BIN_DIR}" "${WORKTREE_DIR}/agent-logs/sessions/2026/03/12"

SESSION_ID="orca-agent-1-20260312T130000Z"
RUN_ID="0001-20260312T130000000000000Z"
RUN_DIR="${WORKTREE_DIR}/agent-logs/sessions/2026/03/12/${SESSION_ID}/runs/${RUN_ID}"
mkdir -p "${RUN_DIR}"

echo "active" > "${TMUX_MODE_FILE}"

cat > "${WORKTREE_DIR}/agent-logs/sessions/2026/03/12/${SESSION_ID}/session.log" <<'LOG'
[2026-03-12T13:00:00Z] [agent-1] starting loop
LOG

cat > "${RUN_DIR}/run.log" <<'LOG'
[2026-03-12T13:00:01Z] [agent-1] running agent command
LOG

cat > "${STUB_BIN_DIR}/tmux" <<'TMUX'
#!/usr/bin/env bash
set -euo pipefail
mode_file="${ORCA_TEST_TMUX_MODE_FILE:?missing mode file}"
mode="$(cat "${mode_file}")"
if [[ "$1" == "ls" && "${2:-}" == "-F" && "${3:-}" == "#S" ]]; then
  if [[ "${mode}" == "active" ]]; then
    printf '%s\n' "orca-agent-1"
    exit 0
  fi
  exit 1
fi
if [[ "$1" == "ls" ]]; then
  if [[ "${mode}" == "active" ]]; then
    printf '%s\n' "orca-agent-1: 1 windows (created Thu Mar 12 13:00:00 2026)"
    exit 0
  fi
  exit 1
fi
exit 1
TMUX
chmod +x "${STUB_BIN_DIR}/tmux"

(
  cd "${WORKTREE_DIR}"
  PATH="${STUB_BIN_DIR}:/usr/bin:/bin" ORCA_TEST_TMUX_MODE_FILE="${TMUX_MODE_FILE}" \
    bash ./status.sh --follow --session-id "${SESSION_ID}" --poll-interval 1 --max-events 4 > "${OUT_FILE}"
) &
follow_pid=$!

sleep 2

echo "inactive" > "${TMUX_MODE_FILE}"
cat >> "${RUN_DIR}/run.log" <<'LOG'
[2026-03-12T13:00:10Z] [agent-1] agent command exited with 0 after 9s
LOG
cat > "${RUN_DIR}/summary.json" <<'JSON'
{"issue_id":"orca-follow","result":"completed","issue_status":"closed","merged":true,"loop_action":"stop","loop_action_reason":"done","notes":"ok"}
JSON

wait "${follow_pid}"

if [[ "$(wc -l < "${OUT_FILE}" | tr -d '[:space:]')" -lt 4 ]]; then
  echo "expected at least 4 follow events" >&2
  cat "${OUT_FILE}" >&2
  exit 1
fi

if ! jq -e 'select(.event_type == "session_started")' "${OUT_FILE}" >/dev/null; then
  echo "missing session_started event" >&2
  exit 1
fi
if ! jq -e 'select(.event_type == "run_started")' "${OUT_FILE}" >/dev/null; then
  echo "missing run_started event" >&2
  exit 1
fi
if ! jq -e 'select(.event_type == "run_completed")' "${OUT_FILE}" >/dev/null; then
  echo "missing run_completed event" >&2
  exit 1
fi
if ! jq -e 'select(.event_type == "loop_stopped")' "${OUT_FILE}" >/dev/null; then
  echo "missing loop_stopped event" >&2
  exit 1
fi
if ! jq -e 'select(.event_type == "run_started") | .event_id' "${OUT_FILE}" | sort | uniq -d | grep . >/dev/null 2>&1; then
  :
else
  echo "duplicate run_started event ids detected" >&2
  exit 1
fi

if [[ "$(jq -r '.schema_version' "${OUT_FILE}" | sort -u)" != "orca.monitor.v1" ]]; then
  echo "unexpected follow schema_version" >&2
  exit 1
fi

echo "status follow monitor regression checks passed"
