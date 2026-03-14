#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
WORKTREE_DIR="${TMP_DIR}/worktree"
STUB_BIN_DIR="${TMP_DIR}/bin"
NO_TMUX_BIN_DIR="${TMP_DIR}/no-tmux-bin"
REGISTRY_PATH="${TMP_DIR}/state/orca/observed-sessions.json"
TMUX_SESSIONS_FILE="${TMP_DIR}/tmux-sessions"
MANAGED_STREAM_FILE="${TMP_DIR}/managed-stream.jsonl"
OUT_FILE="${TMP_DIR}/monitor-follow.jsonl"
FILTER_OUT_FILE="${TMP_DIR}/monitor-follow-filtered.jsonl"

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

  set +e
  wait "${pid}"
  wait_rc=$?
  set -e
  return "${wait_rc}"
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

managed_event='{"schema_version":"orca.monitor.v2","observed_at":"2026-03-14T12:00:00Z","event_type":"run_started","event_id":"run_started:managed-1:run-0001","session_id":"managed-1","mode":"managed","tmux_target":"orca-agent-1","run":{"run_id":"run-0001","state":"running","result":null,"issue_status":null,"summary_path":null},"passthrough_marker":"keep-me"}'
printf '%s\n' "${managed_event}" > "${MANAGED_STREAM_FILE}"

cat > "${REGISTRY_PATH}" <<'JSON'
{"schema_version":"orca.observed.v1","updated_at":"2026-03-14T12:00:00Z","entries":[{"id":"observed-1","mode":"observed","lifecycle":"persistent","tmux_target":"obs","created_at":"2026-03-14T12:00:00Z","source":"monitor_add"}]}
JSON

printf '%s\n' "obs" "other" > "${TMUX_SESSIONS_FILE}"

(
  cd "${WORKTREE_DIR}"
  PATH="${STUB_BIN_DIR}:/usr/bin:/bin" \
    ORCA_OBSERVED_REGISTRY_PATH="${REGISTRY_PATH}" \
    ORCA_TEST_TMUX_SESSIONS="${TMUX_SESSIONS_FILE}" \
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

echo "monitor follow merged-stream regression checks passed"
