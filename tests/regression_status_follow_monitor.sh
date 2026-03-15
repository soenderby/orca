#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
WORKTREE_DIR="${TMP_DIR}/worktree"
STUB_BIN_DIR="${TMP_DIR}/bin"
TMUX_MODE_FILE="${TMP_DIR}/tmux-mode"
OUT_FILE_DEFAULT="${TMP_DIR}/follow-default.jsonl"
OUT_FILE_REPLAY="${TMP_DIR}/follow-replay.jsonl"

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
RUN_ID_REPLAY="0002-20260312T140000000000000Z"
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
    bash ./status.sh --follow --session-id "${SESSION_ID}" --poll-interval 1 --max-events 2 > "${OUT_FILE_DEFAULT}"
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

if [[ "$(wc -l < "${OUT_FILE_DEFAULT}" | tr -d '[:space:]')" -ne 2 ]]; then
  echo "expected exactly 2 default follow events" >&2
  cat "${OUT_FILE_DEFAULT}" >&2
  exit 1
fi

if jq -e 'select(.event_type == "session_up" or .event_type == "run_started")' "${OUT_FILE_DEFAULT}" >/dev/null; then
  echo "default follow unexpectedly replayed startup baseline events" >&2
  exit 1
fi
if ! jq -e 'select(.event_type == "run_completed")' "${OUT_FILE_DEFAULT}" >/dev/null; then
  echo "missing run_completed event" >&2
  exit 1
fi
if ! jq -e 'select(.event_type == "session_down")' "${OUT_FILE_DEFAULT}" >/dev/null; then
  echo "missing session_down event" >&2
  exit 1
fi

expected_event_sequence="run_completed,session_down"
actual_event_sequence="$(jq -r '.event_type' "${OUT_FILE_DEFAULT}" | paste -sd ',' -)"
if [[ "${actual_event_sequence}" != "${expected_event_sequence}" ]]; then
  echo "unexpected follow event order; expected ${expected_event_sequence}, got ${actual_event_sequence}" >&2
  cat "${OUT_FILE_DEFAULT}" >&2
  exit 1
fi

expected_event_ids="run_completed:${SESSION_ID}:${RUN_ID},session_down:${SESSION_ID}"
actual_event_ids="$(jq -r '.event_id' "${OUT_FILE_DEFAULT}" | paste -sd ',' -)"
if [[ "${actual_event_ids}" != "${expected_event_ids}" ]]; then
  echo "unexpected follow event_id order; expected ${expected_event_ids}, got ${actual_event_ids}" >&2
  cat "${OUT_FILE_DEFAULT}" >&2
  exit 1
fi

if ! jq -e 'select(.event_type == "run_started") | .event_id' "${OUT_FILE_DEFAULT}" | sort | uniq -d | grep . >/dev/null 2>&1; then
  :
else
  echo "duplicate run_started event ids detected" >&2
  exit 1
fi

if [[ "$(jq -r '.schema_version' "${OUT_FILE_DEFAULT}" | sort -u)" != "orca.monitor.v2" ]]; then
  echo "unexpected follow schema_version" >&2
  exit 1
fi

if jq -e 'select(.event_type == "session_started" or .event_type == "loop_stopped")' "${OUT_FILE_DEFAULT}" >/dev/null; then
  echo "legacy follow event type detected" >&2
  exit 1
fi

if ! jq -e '
  . as $e
  | ($e | has("schema_version"))
  and ($e | has("observed_at"))
  and ($e | has("event_type"))
  and ($e | has("event_id"))
  and ($e | has("session_id"))
  and ($e | has("mode"))
  and ($e | has("tmux_target"))
' "${OUT_FILE_DEFAULT}" >/dev/null; then
  echo "follow event missing required top-level fields" >&2
  exit 1
fi

if ! jq -e '
  .event_type
  | test("^(session_up|session_down|run_[A-Za-z0-9_]+)$")
' "${OUT_FILE_DEFAULT}" >/dev/null; then
  echo "unexpected follow event_type outside v2 allowlist" >&2
  exit 1
fi

echo "active" > "${TMUX_MODE_FILE}"
RUN_DIR_REPLAY="${WORKTREE_DIR}/agent-logs/sessions/2026/03/12/${SESSION_ID}/runs/${RUN_ID_REPLAY}"
mkdir -p "${RUN_DIR_REPLAY}"
cat > "${RUN_DIR_REPLAY}/run.log" <<'LOG'
[2026-03-12T14:00:01Z] [agent-1] running agent command
LOG

(
  cd "${WORKTREE_DIR}"
  PATH="${STUB_BIN_DIR}:/usr/bin:/bin" ORCA_TEST_TMUX_MODE_FILE="${TMUX_MODE_FILE}" \
    bash ./status.sh --follow --replay-baseline --session-id "${SESSION_ID}" --poll-interval 1 --max-events 4 > "${OUT_FILE_REPLAY}"
) &
replay_pid=$!

sleep 2
echo "inactive" > "${TMUX_MODE_FILE}"
cat >> "${RUN_DIR_REPLAY}/run.log" <<'LOG'
[2026-03-12T14:00:10Z] [agent-1] agent command exited with 0 after 9s
LOG
cat > "${RUN_DIR_REPLAY}/summary.json" <<'JSON'
{"issue_id":"orca-follow-replay","result":"completed","issue_status":"closed","merged":true,"loop_action":"stop","loop_action_reason":"done","notes":"ok"}
JSON

wait "${replay_pid}"

if [[ "$(wc -l < "${OUT_FILE_REPLAY}" | tr -d '[:space:]')" -ne 4 ]]; then
  echo "expected exactly 4 replay follow events" >&2
  cat "${OUT_FILE_REPLAY}" >&2
  exit 1
fi

expected_replay_sequence="session_up,run_started,run_completed,session_down"
actual_replay_sequence="$(jq -r '.event_type' "${OUT_FILE_REPLAY}" | paste -sd ',' -)"
if [[ "${actual_replay_sequence}" != "${expected_replay_sequence}" ]]; then
  echo "unexpected replay event order; expected ${expected_replay_sequence}, got ${actual_replay_sequence}" >&2
  cat "${OUT_FILE_REPLAY}" >&2
  exit 1
fi

expected_replay_ids="session_up:${SESSION_ID},run_started:${SESSION_ID}:${RUN_ID_REPLAY},run_completed:${SESSION_ID}:${RUN_ID_REPLAY},session_down:${SESSION_ID}"
actual_replay_ids="$(jq -r '.event_id' "${OUT_FILE_REPLAY}" | paste -sd ',' -)"
if [[ "${actual_replay_ids}" != "${expected_replay_ids}" ]]; then
  echo "unexpected replay event_id order; expected ${expected_replay_ids}, got ${actual_replay_ids}" >&2
  cat "${OUT_FILE_REPLAY}" >&2
  exit 1
fi

echo "status follow monitor regression checks passed"
