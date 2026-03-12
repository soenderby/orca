#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
WORKTREE_DIR="${TMP_DIR}/worktree"
TMUX_MODE_FILE="${TMP_DIR}/tmux-mode"
STUB_BIN_DIR="${TMP_DIR}/bin"

cleanup() {
  git -C "${ROOT}" worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

git -C "${ROOT}" worktree add --detach "${WORKTREE_DIR}" HEAD >/dev/null
cp "${ROOT}/wait.sh" "${WORKTREE_DIR}/wait.sh"
chmod +x "${WORKTREE_DIR}/wait.sh"
mkdir -p "${STUB_BIN_DIR}"

cat > "${STUB_BIN_DIR}/tmux" <<'TMUX'
#!/usr/bin/env bash
set -euo pipefail
mode_file="${ORCA_TEST_TMUX_MODE_FILE:?missing mode file}"
mode="$(cat "${mode_file}")"

if [[ "$1" == "ls" && "${2:-}" == "-F" && "${3:-}" == "#S" ]]; then
  if [[ "${mode}" == "one" ]]; then
    printf '%s\n' "orca-agent-1"
    exit 0
  fi
  exit 1
fi

if [[ "$1" == "ls" ]]; then
  if [[ "${mode}" == "one" ]]; then
    printf '%s\n' "orca-agent-1: 1 windows (created Thu Mar 12 10:00:00 2026)"
    exit 0
  fi
  exit 1
fi

exit 1
TMUX
chmod +x "${STUB_BIN_DIR}/tmux"

reset_artifacts() {
  rm -rf "${WORKTREE_DIR}/agent-logs"
  mkdir -p "${WORKTREE_DIR}/agent-logs/sessions/2026/03/12"
}

run_wait_json() {
  local out_file="$1"
  shift
  (
    cd "${WORKTREE_DIR}" && \
    PATH="${STUB_BIN_DIR}:/usr/bin:/bin" \
    ORCA_TEST_TMUX_MODE_FILE="${TMUX_MODE_FILE}" \
    bash ./wait.sh --json "$@"
  ) >"${out_file}"
}

assert_json_field() {
  local file="$1"
  local query="$2"
  local expected="$3"
  local actual
  actual="$(jq -r "${query}" "${file}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "json assertion failed: query=${query} expected=${expected} actual=${actual}" >&2
    exit 1
  fi
}

# Case 1: success in historical mode when historical session has successful terminal summary.
reset_artifacts
echo "none" > "${TMUX_MODE_FILE}"
SESSION_OK="orca-agent-1-20260312T100000Z"
RUN_OK="${WORKTREE_DIR}/agent-logs/sessions/2026/03/12/${SESSION_OK}/runs/0001-20260312T100000000000000Z"
mkdir -p "${RUN_OK}"
cat > "${WORKTREE_DIR}/agent-logs/sessions/2026/03/12/${SESSION_OK}/session.log" <<'LOG'
[2026-03-12T10:00:00Z] [agent-1] starting loop
LOG
cat > "${RUN_OK}/summary.json" <<'JSON'
{"issue_id":"orca-1","result":"completed","issue_status":"closed","merged":true,"loop_action":"continue","loop_action_reason":"","notes":"ok"}
JSON

OUT1="${TMP_DIR}/out1.json"
if ! run_wait_json "${OUT1}" --all-history --timeout 1 --poll-interval 1; then
  echo "wait success case returned non-zero exit" >&2
  exit 1
fi
assert_json_field "${OUT1}" '.status' 'success'
assert_json_field "${OUT1}" '.reason' 'all_scoped_sessions_finished'
assert_json_field "${OUT1}" '.scope.description' 'all sessions (history)'
assert_json_field "${OUT1}" '.counts.succeeded' '1'

# Case 2: failure when scoped session reports blocked/failed terminal summary.
reset_artifacts
echo "none" > "${TMUX_MODE_FILE}"
SESSION_FAIL="orca-agent-1-20260312T101000Z"
RUN_FAIL="${WORKTREE_DIR}/agent-logs/sessions/2026/03/12/${SESSION_FAIL}/runs/0001-20260312T101000000000000Z"
mkdir -p "${RUN_FAIL}"
cat > "${WORKTREE_DIR}/agent-logs/sessions/2026/03/12/${SESSION_FAIL}/session.log" <<'LOG'
[2026-03-12T10:10:00Z] [agent-1] starting loop
LOG
cat > "${RUN_FAIL}/summary.json" <<'JSON'
{"issue_id":"orca-2","result":"failed","issue_status":"in_progress","merged":false,"loop_action":"continue","loop_action_reason":"","notes":"failed"}
JSON

OUT2="${TMP_DIR}/out2.json"
set +e
run_wait_json "${OUT2}" --all-history --timeout 1 --poll-interval 1
status2=$?
set -e
if [[ "${status2}" -ne 3 ]]; then
  echo "expected wait failure exit code 3, got ${status2}" >&2
  exit 1
fi
assert_json_field "${OUT2}" '.status' 'failure'
assert_json_field "${OUT2}" '.reason' 'scoped_failure_detected'
assert_json_field "${OUT2}" '.counts.failed' '1'

# Case 3: default unscoped mode ignores historical sessions and returns no_scoped_sessions.
reset_artifacts
echo "none" > "${TMUX_MODE_FILE}"
SESSION_OLD_FAIL="orca-agent-1-20260312T100500Z"
SESSION_OLD_OK="orca-agent-1-20260312T100600Z"
RUN_OLD_FAIL="${WORKTREE_DIR}/agent-logs/sessions/2026/03/12/${SESSION_OLD_FAIL}/runs/0001-20260312T100500000000000Z"
RUN_OLD_OK="${WORKTREE_DIR}/agent-logs/sessions/2026/03/12/${SESSION_OLD_OK}/runs/0001-20260312T100600000000000Z"
mkdir -p "${RUN_OLD_FAIL}" "${RUN_OLD_OK}"
cat > "${WORKTREE_DIR}/agent-logs/sessions/2026/03/12/${SESSION_OLD_FAIL}/session.log" <<'LOG'
[2026-03-12T10:05:00Z] [agent-1] starting loop
LOG
cat > "${WORKTREE_DIR}/agent-logs/sessions/2026/03/12/${SESSION_OLD_OK}/session.log" <<'LOG'
[2026-03-12T10:06:00Z] [agent-1] starting loop
LOG
cat > "${RUN_OLD_FAIL}/summary.json" <<'JSON'
{"issue_id":"orca-old","result":"failed","issue_status":"in_progress","merged":false,"loop_action":"continue","loop_action_reason":"","notes":"old failed run"}
JSON
cat > "${RUN_OLD_OK}/summary.json" <<'JSON'
{"issue_id":"orca-new","result":"completed","issue_status":"closed","merged":true,"loop_action":"continue","loop_action_reason":"","notes":"old successful run"}
JSON

OUT3="${TMP_DIR}/out3.json"
if ! run_wait_json "${OUT3}" --timeout 1 --poll-interval 1; then
  echo "wait default-unscoped no-scoped case returned non-zero exit" >&2
  exit 1
fi
assert_json_field "${OUT3}" '.status' 'success'
assert_json_field "${OUT3}" '.reason' 'no_scoped_sessions'
assert_json_field "${OUT3}" '.scope.description' 'active sessions at invocation'
assert_json_field "${OUT3}" '.counts.scoped_sessions' '0'

# Case 4: timeout when active scoped session never reaches terminal state.
reset_artifacts
echo "one" > "${TMUX_MODE_FILE}"
OUT4="${TMP_DIR}/out4.json"
set +e
run_wait_json "${OUT4}" --timeout 1 --poll-interval 1
status4=$?
set -e
if [[ "${status4}" -ne 2 ]]; then
  echo "expected wait timeout exit code 2, got ${status4}" >&2
  exit 1
fi
assert_json_field "${OUT4}" '.status' 'timeout'
assert_json_field "${OUT4}" '.reason' 'timeout'
assert_json_field "${OUT4}" '.counts.running' '1'

# Case 5: no scoped sessions is immediate success with explicit reason.
reset_artifacts
echo "none" > "${TMUX_MODE_FILE}"
OUT5="${TMP_DIR}/out5.json"
if ! run_wait_json "${OUT5}" --timeout 1 --poll-interval 1 --session-id "missing-session"; then
  echo "wait no-scoped case returned non-zero exit" >&2
  exit 1
fi
assert_json_field "${OUT5}" '.status' 'success'
assert_json_field "${OUT5}" '.reason' 'no_scoped_sessions'
assert_json_field "${OUT5}" '.counts.scoped_sessions' '0'

# Case 6: session-id scope isolates selected session from failures outside scope.
reset_artifacts
echo "none" > "${TMUX_MODE_FILE}"
SESSION_A="orca-agent-1-20260312T102000Z"
SESSION_B="orca-agent-2-20260312T102500Z"
RUN_A="${WORKTREE_DIR}/agent-logs/sessions/2026/03/12/${SESSION_A}/runs/0001-20260312T102000000000000Z"
RUN_B="${WORKTREE_DIR}/agent-logs/sessions/2026/03/12/${SESSION_B}/runs/0001-20260312T102500000000000Z"
mkdir -p "${RUN_A}" "${RUN_B}"
cat > "${WORKTREE_DIR}/agent-logs/sessions/2026/03/12/${SESSION_A}/session.log" <<'LOG'
[2026-03-12T10:20:00Z] [agent-1] starting loop
LOG
cat > "${WORKTREE_DIR}/agent-logs/sessions/2026/03/12/${SESSION_B}/session.log" <<'LOG'
[2026-03-12T10:25:00Z] [agent-2] starting loop
LOG
cat > "${RUN_A}/summary.json" <<'JSON'
{"issue_id":"orca-3","result":"completed","issue_status":"closed","merged":true,"loop_action":"continue","loop_action_reason":"","notes":"ok"}
JSON
cat > "${RUN_B}/summary.json" <<'JSON'
{"issue_id":"orca-4","result":"failed","issue_status":"in_progress","merged":false,"loop_action":"continue","loop_action_reason":"","notes":"bad"}
JSON

OUT6="${TMP_DIR}/out6.json"
if ! run_wait_json "${OUT6}" --timeout 1 --poll-interval 1 --session-id "${SESSION_A}"; then
  echo "wait scoped-session case returned non-zero exit" >&2
  exit 1
fi
assert_json_field "${OUT6}" '.status' 'success'
assert_json_field "${OUT6}" '.counts.scoped_sessions' '1'
assert_json_field "${OUT6}" '.sessions[0].session_id' "${SESSION_A}"

echo "wait command regression checks passed"
