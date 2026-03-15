#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
WORKTREE_DIR="${TMP_DIR}/worktree"
STUB_BIN_DIR="${TMP_DIR}/bin"
NO_TMUX_BIN_DIR="${TMP_DIR}/no-tmux-bin"
REGISTRY_PATH="${TMP_DIR}/state/orca/observed-sessions.json"
TMUX_SESSIONS_FILE="${TMP_DIR}/tmux-sessions"
TMUX_HEALTH_MODE_FILE="${TMP_DIR}/tmux-health-mode"
MANAGED_STREAM_FILE="${TMP_DIR}/managed-stream.jsonl"
MANAGED_FLAP_STREAM_FILE="${TMP_DIR}/managed-flap-stream.jsonl"
OUT_FILE="${TMP_DIR}/monitor-follow.jsonl"
MANAGED_FLAP_OUT_FILE="${TMP_DIR}/monitor-follow-managed-flap.jsonl"
FILTER_OUT_FILE="${TMP_DIR}/monitor-follow-filtered.jsonl"
RUNTIME_FAIL_OUT_FILE="${TMP_DIR}/monitor-follow-runtime-fail.jsonl"

cleanup() {
  git -C "${ROOT}" worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

wait_for_pid() {
  local pid="$1"
  local timeout_seconds="$2"
  local elapsed=0
  local wait_rc=0

  while kill -0 "${pid}" >/dev/null 2>&1; do
    if [[ "${elapsed}" -ge "${timeout_seconds}" ]]; then
      kill "${pid}" >/dev/null 2>&1 || true
      wait "${pid}" >/dev/null 2>&1 || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if wait "${pid}"; then
    wait_rc=0
  else
    wait_rc=$?
  fi
  return "${wait_rc}"
}

count_managed_follow_children() {
  local status_script_path="$1"
  local count=0
  local pgrep_rc=0

  set +e
  count="$(pgrep -f -c "^[b]ash ${status_script_path} --follow" 2>/dev/null)"
  pgrep_rc=$?
  set -e

  if [[ "${pgrep_rc}" -eq 1 ]]; then
    echo "0"
    return 0
  fi
  if [[ "${pgrep_rc}" -ne 0 ]]; then
    echo "0"
    return 0
  fi

  echo "${count}"
}

git -C "${ROOT}" worktree add --detach "${WORKTREE_DIR}" HEAD >/dev/null
mkdir -p "${STUB_BIN_DIR}" "${NO_TMUX_BIN_DIR}" "$(dirname "${REGISTRY_PATH}")"
cp "${ROOT}/orca.sh" "${WORKTREE_DIR}/orca.sh"
cp "${ROOT}/monitor.sh" "${WORKTREE_DIR}/monitor.sh"
chmod +x "${WORKTREE_DIR}/orca.sh" "${WORKTREE_DIR}/monitor.sh"

cat > "${WORKTREE_DIR}/status.sh" <<'STATUS_STUB'
#!/usr/bin/env bash
set -euo pipefail

while [[ $# -gt 0 ]]; do
  case "$1" in
    --follow)
      ;;
    --poll-interval|--max-events|--session-id|--session-prefix)
      shift
      ;;
    *)
      echo "status stub: unexpected argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "${ORCA_TEST_STATUS_EMIT:-0}" == "1" ]]; then
  stream_file="${ORCA_TEST_STATUS_STREAM_FILE:-}"
  if [[ -n "${stream_file}" && -f "${stream_file}" ]]; then
    cat "${stream_file}"
  fi
fi

while true; do
  sleep 1
done
STATUS_STUB
chmod +x "${WORKTREE_DIR}/status.sh"

cat > "${STUB_BIN_DIR}/tmux" <<'TMUX_STUB'
#!/usr/bin/env bash
set -euo pipefail

sessions_file="${ORCA_TEST_TMUX_SESSIONS:?missing ORCA_TEST_TMUX_SESSIONS}"
health_mode_file="${ORCA_TEST_TMUX_HEALTH_MODE_FILE:-}"

if [[ "${1:-}" == "start-server" ]]; then
  mode="ok"
  if [[ -n "${health_mode_file}" && -f "${health_mode_file}" ]]; then
    mode="$(cat "${health_mode_file}")"
  fi
  if [[ "${mode}" == "fail" ]]; then
    echo "failed to connect to tmux server" >&2
    exit 1
  fi
  exit 0
fi

if [[ "${1:-}" == "has-session" && "${2:-}" == "-t" && -n "${3:-}" ]]; then
  if grep -Fx -- "${3}" "${sessions_file}" >/dev/null 2>&1; then
    exit 0
  fi
  exit 1
fi

if [[ "${1:-}" == "list-windows" && "${2:-}" == "-F" && "${3:-}" == "#W" && "${4:-}" == "-t" && -n "${5:-}" ]]; then
  if grep -Fx -- "${5}" "${sessions_file}" >/dev/null 2>&1; then
    printf '%s\n' "main"
    exit 0
  fi
  exit 1
fi

exit 1
TMUX_STUB
chmod +x "${STUB_BIN_DIR}/tmux"

managed_flap_up_one='{"schema_version":"orca.monitor.v2","observed_at":"2026-03-14T11:59:58Z","event_type":"session_up","event_id":"session_up:managed-flap","session_id":"managed-flap","mode":"managed","tmux_target":"orca-agent-flap","session":{"session_id":"managed-flap","tmux_target":"orca-agent-flap","active":true}}'
managed_flap_down='{"schema_version":"orca.monitor.v2","observed_at":"2026-03-14T11:59:59Z","event_type":"session_down","event_id":"session_down:managed-flap","session_id":"managed-flap","mode":"managed","tmux_target":"orca-agent-flap","session":{"session_id":"managed-flap","tmux_target":"orca-agent-flap","active":false}}'
managed_flap_up_two='{"schema_version":"orca.monitor.v2","observed_at":"2026-03-14T12:00:00Z","event_type":"session_up","event_id":"session_up:managed-flap","session_id":"managed-flap","mode":"managed","tmux_target":"orca-agent-flap","session":{"session_id":"managed-flap","tmux_target":"orca-agent-flap","active":true}}'
printf '%s\n%s\n%s\n' "${managed_flap_up_one}" "${managed_flap_down}" "${managed_flap_up_two}" > "${MANAGED_FLAP_STREAM_FILE}"

cat > "${REGISTRY_PATH}" <<'JSON'
{"schema_version":"orca.observed.v1","updated_at":"2026-03-14T11:59:58Z","entries":[]}
JSON

printf '%s\n' "obs" "other" > "${TMUX_SESSIONS_FILE}"
echo "ok" > "${TMUX_HEALTH_MODE_FILE}"

(
  cd "${WORKTREE_DIR}"
  PATH="${STUB_BIN_DIR}:/usr/bin:/bin" \
    ORCA_OBSERVED_REGISTRY_PATH="${REGISTRY_PATH}" \
    ORCA_TEST_TMUX_SESSIONS="${TMUX_SESSIONS_FILE}" \
    ORCA_TEST_TMUX_HEALTH_MODE_FILE="${TMUX_HEALTH_MODE_FILE}" \
    ORCA_TEST_STATUS_EMIT=1 \
    ORCA_TEST_STATUS_STREAM_FILE="${MANAGED_FLAP_STREAM_FILE}" \
    bash ./orca.sh monitor --follow --poll-interval 1 --max-events 3 > "${MANAGED_FLAP_OUT_FILE}"
) &
managed_flap_pid=$!

if ! wait_for_pid "${managed_flap_pid}" 20; then
  echo "monitor --follow did not complete managed flap scenario" >&2
  exit 1
fi

if [[ "$(jq -r '.event_type' "${MANAGED_FLAP_OUT_FILE}" | paste -sd ',' -)" != "session_up,session_down,session_up" ]]; then
  echo "expected managed flap ordering session_up,session_down,session_up" >&2
  cat "${MANAGED_FLAP_OUT_FILE}" >&2
  exit 1
fi

if [[ "$(jq -r 'select(.mode == "managed" and .session_id == "managed-flap" and .event_type == "session_up") | .event_type' "${MANAGED_FLAP_OUT_FILE}" | wc -l | tr -d '[:space:]')" -ne 2 ]]; then
  echo "expected two managed session_up events for flap sequence" >&2
  cat "${MANAGED_FLAP_OUT_FILE}" >&2
  exit 1
fi

managed_event='{"schema_version":"orca.monitor.v2","observed_at":"2026-03-14T12:00:00Z","event_type":"run_started","event_id":"run_started:managed-1:run-0001","session_id":"managed-1","mode":"managed","tmux_target":"orca-agent-1","run":{"run_id":"run-0001","state":"running","result":null,"issue_status":null,"summary_path":null},"passthrough_marker":"keep-me"}'
printf '%s\n%s\n' "${managed_event}" "${managed_event}" > "${MANAGED_STREAM_FILE}"

cat > "${REGISTRY_PATH}" <<'JSON'
{"schema_version":"orca.observed.v1","updated_at":"2026-03-14T12:00:00Z","entries":[{"id":"observed-1","mode":"observed","lifecycle":"persistent","tmux_target":"obs","created_at":"2026-03-14T12:00:00Z","source":"monitor_add"}]}
JSON

printf '%s\n' "obs" "other" > "${TMUX_SESSIONS_FILE}"
echo "ok" > "${TMUX_HEALTH_MODE_FILE}"

(
  cd "${WORKTREE_DIR}"
  PATH="${STUB_BIN_DIR}:/usr/bin:/bin" \
    ORCA_OBSERVED_REGISTRY_PATH="${REGISTRY_PATH}" \
    ORCA_TEST_TMUX_SESSIONS="${TMUX_SESSIONS_FILE}" \
    ORCA_TEST_TMUX_HEALTH_MODE_FILE="${TMUX_HEALTH_MODE_FILE}" \
    ORCA_TEST_STATUS_EMIT=1 \
    ORCA_TEST_STATUS_STREAM_FILE="${MANAGED_STREAM_FILE}" \
    bash ./orca.sh monitor --follow --poll-interval 1 --max-events 3 > "${OUT_FILE}"
) &
follow_pid=$!

sleep 2
printf '%s\n' "other" > "${TMUX_SESSIONS_FILE}"

if ! wait_for_pid "${follow_pid}" 20; then
  echo "monitor --follow did not complete merged stream scenario" >&2
  exit 1
fi

if ! grep -Fx -- "${managed_event}" "${OUT_FILE}" >/dev/null; then
  echo "expected managed event passthrough without schema drift" >&2
  cat "${OUT_FILE}" >&2
  exit 1
fi

if [[ "$(wc -l < "${OUT_FILE}" | tr -d '[:space:]')" -ne 3 ]]; then
  echo "expected exactly three merged follow events" >&2
  cat "${OUT_FILE}" >&2
  exit 1
fi

expected_merged_sequence="observed:session_up:observed-1,managed:run_started:managed-1,observed:session_down:observed-1"
actual_merged_sequence="$(jq -r '[.mode, .event_type, .session_id] | join(":")' "${OUT_FILE}" | paste -sd ',' -)"
if [[ "${actual_merged_sequence}" != "${expected_merged_sequence}" ]]; then
  echo "unexpected merged follow ordering; expected ${expected_merged_sequence}, got ${actual_merged_sequence}" >&2
  cat "${OUT_FILE}" >&2
  exit 1
fi

managed_line_number="$(grep -n -F -- "${managed_event}" "${OUT_FILE}" | cut -d: -f1 | head -n 1)"
if [[ "${managed_line_number}" != "2" ]]; then
  echo "expected managed passthrough event to remain on line 2 in merged output" >&2
  cat "${OUT_FILE}" >&2
  exit 1
fi

if [[ "$(jq -r 'select(.mode == "managed" and .event_id == "run_started:managed-1:run-0001") | .event_id' "${OUT_FILE}" | wc -l | tr -d '[:space:]')" -ne 1 ]]; then
  echo "expected managed event_id run_started:managed-1:run-0001 exactly once" >&2
  cat "${OUT_FILE}" >&2
  exit 1
fi

if ! jq -e '
  select(.mode == "observed" and .event_type == "session_up" and .session_id == "observed-1")
  | .event_id == "session_up:observed-1"
' "${OUT_FILE}" >/dev/null; then
  echo "missing observed session_up transition event" >&2
  cat "${OUT_FILE}" >&2
  exit 1
fi

if ! jq -e '
  select(.mode == "observed" and .event_type == "session_down" and .session_id == "observed-1")
  | .event_id == "session_down:observed-1"
' "${OUT_FILE}" >/dev/null; then
  echo "missing observed session_down transition event" >&2
  cat "${OUT_FILE}" >&2
  exit 1
fi

if [[ "$(jq -r 'select(.mode == "observed" and .event_type == "session_up" and .session_id == "observed-1") | .event_id' "${OUT_FILE}" | wc -l | tr -d '[:space:]')" -ne 1 ]]; then
  echo "expected exactly one observed session_up event for observed-1" >&2
  cat "${OUT_FILE}" >&2
  exit 1
fi

if [[ "$(jq -r 'select(.mode == "observed" and .event_type == "session_down" and .session_id == "observed-1") | .event_id' "${OUT_FILE}" | wc -l | tr -d '[:space:]')" -ne 1 ]]; then
  echo "expected exactly one observed session_down event for observed-1" >&2
  cat "${OUT_FILE}" >&2
  exit 1
fi

cat > "${REGISTRY_PATH}" <<'JSON'
{"schema_version":"orca.observed.v1","updated_at":"2026-03-14T12:05:00Z","entries":[{"id":"observed-1","mode":"observed","lifecycle":"persistent","tmux_target":"obs","created_at":"2026-03-14T12:05:00Z","source":"monitor_add"},{"id":"ignored-1","mode":"observed","lifecycle":"ephemeral","tmux_target":"other","created_at":"2026-03-14T12:05:00Z","source":"monitor_add"}]}
JSON
printf '%s\n' "obs" "other" > "${TMUX_SESSIONS_FILE}"

(
  cd "${WORKTREE_DIR}"
  PATH="${STUB_BIN_DIR}:/usr/bin:/bin" \
    ORCA_OBSERVED_REGISTRY_PATH="${REGISTRY_PATH}" \
    ORCA_TEST_TMUX_SESSIONS="${TMUX_SESSIONS_FILE}" \
    ORCA_TEST_TMUX_HEALTH_MODE_FILE="${TMUX_HEALTH_MODE_FILE}" \
    ORCA_TEST_STATUS_EMIT=0 \
    bash ./orca.sh monitor --follow --poll-interval 1 --max-events 1 --session-id observed-1 > "${FILTER_OUT_FILE}"
) &
filter_pid=$!

if ! wait_for_pid "${filter_pid}" 20; then
  echo "monitor --follow did not complete session filter scenario" >&2
  exit 1
fi

if [[ "$(wc -l < "${FILTER_OUT_FILE}" | tr -d '[:space:]')" -ne 1 ]]; then
  echo "expected exactly one filtered follow event" >&2
  cat "${FILTER_OUT_FILE}" >&2
  exit 1
fi

if ! jq -e '
  select(.mode == "observed")
  | .event_type == "session_up" and .session_id == "observed-1"
' "${FILTER_OUT_FILE}" >/dev/null; then
  echo "filtered follow output did not scope to observed-1" >&2
  cat "${FILTER_OUT_FILE}" >&2
  exit 1
fi

if jq -e 'select(.session_id == "ignored-1")' "${FILTER_OUT_FILE}" >/dev/null; then
  echo "session filter leaked events for ignored-1" >&2
  cat "${FILTER_OUT_FILE}" >&2
  exit 1
fi

cat > "${REGISTRY_PATH}" <<'JSON'
{"schema_version":"orca.observed.v1","updated_at":"2026-03-14T12:06:00Z","entries":[{"id":"observed-runtime","mode":"observed","lifecycle":"persistent","tmux_target":"obs","created_at":"2026-03-14T12:06:00Z","source":"monitor_add"}]}
JSON
printf '%s\n' "obs" "other" > "${TMUX_SESSIONS_FILE}"
echo "ok" > "${TMUX_HEALTH_MODE_FILE}"

(
  cd "${WORKTREE_DIR}"
  PATH="${STUB_BIN_DIR}:/usr/bin:/bin" \
    ORCA_OBSERVED_REGISTRY_PATH="${REGISTRY_PATH}" \
    ORCA_TEST_TMUX_SESSIONS="${TMUX_SESSIONS_FILE}" \
    ORCA_TEST_TMUX_HEALTH_MODE_FILE="${TMUX_HEALTH_MODE_FILE}" \
    ORCA_TEST_STATUS_EMIT=0 \
    bash ./orca.sh monitor --follow --poll-interval 1 --max-events 0 > "${RUNTIME_FAIL_OUT_FILE}"
) &
runtime_fail_pid=$!

sleep 2
runtime_managed_children="$(count_managed_follow_children "${WORKTREE_DIR}/status.sh")"
if [[ "${runtime_managed_children}" -lt 1 ]]; then
  echo "expected managed status follow child to start before runtime failure" >&2
  exit 1
fi

echo "fail" > "${TMUX_HEALTH_MODE_FILE}"

set +e
wait_for_pid "${runtime_fail_pid}" 20
runtime_fail_rc=$?
set -e
if [[ "${runtime_fail_rc}" -ne 3 ]]; then
  echo "expected runtime tmux probe failure to exit 3, got ${runtime_fail_rc}" >&2
  cat "${RUNTIME_FAIL_OUT_FILE}" >&2
  exit 1
fi

runtime_cleanup_attempt=0
runtime_managed_children="$(count_managed_follow_children "${WORKTREE_DIR}/status.sh")"
while [[ "${runtime_managed_children}" -gt 0 && "${runtime_cleanup_attempt}" -lt 20 ]]; do
  sleep 0.1
  runtime_cleanup_attempt=$((runtime_cleanup_attempt + 1))
  runtime_managed_children="$(count_managed_follow_children "${WORKTREE_DIR}/status.sh")"
done
if [[ "${runtime_managed_children}" -ne 0 ]]; then
  echo "expected runtime tmux probe failure to clean up managed status follow child" >&2
  ps -eo pid=,args= | grep -F -- "${WORKTREE_DIR}/status.sh" >&2 || true
  exit 1
fi

if jq -e 'select(.mode == "observed" and .event_type == "session_down")' "${RUNTIME_FAIL_OUT_FILE}" >/dev/null; then
  echo "runtime tmux probe failure must not emit observed session_down transitions" >&2
  cat "${RUNTIME_FAIL_OUT_FILE}" >&2
  exit 1
fi

ln -s "$(command -v git)" "${NO_TMUX_BIN_DIR}/git"
ln -s "$(command -v jq)" "${NO_TMUX_BIN_DIR}/jq"
ln -s "$(command -v dirname)" "${NO_TMUX_BIN_DIR}/dirname"
ln -s "$(command -v bash)" "${NO_TMUX_BIN_DIR}/bash"

set +e
(
  cd "${WORKTREE_DIR}"
  PATH="${NO_TMUX_BIN_DIR}" \
    ORCA_OBSERVED_REGISTRY_PATH="${REGISTRY_PATH}" \
    /bin/bash ./orca.sh monitor --follow --max-events 1 >/dev/null 2>&1
)
no_tmux_rc=$?
set -e
if [[ "${no_tmux_rc}" -ne 3 ]]; then
  echo "expected monitor --follow without tmux to exit 3, got ${no_tmux_rc}" >&2
  exit 1
fi

echo "fail" > "${TMUX_HEALTH_MODE_FILE}"
set +e
(
  cd "${WORKTREE_DIR}"
  PATH="${STUB_BIN_DIR}:/usr/bin:/bin" \
    ORCA_OBSERVED_REGISTRY_PATH="${REGISTRY_PATH}" \
    ORCA_TEST_TMUX_SESSIONS="${TMUX_SESSIONS_FILE}" \
    ORCA_TEST_TMUX_HEALTH_MODE_FILE="${TMUX_HEALTH_MODE_FILE}" \
    bash ./orca.sh monitor --follow --max-events 1 >/dev/null 2>&1
)
unusable_tmux_rc=$?
set -e
if [[ "${unusable_tmux_rc}" -ne 3 ]]; then
  echo "expected monitor --follow with unusable tmux probe to exit 3, got ${unusable_tmux_rc}" >&2
  exit 1
fi

echo "monitor follow merged-stream regression checks passed"
