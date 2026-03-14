#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
WORKTREE_DIR="${TMP_DIR}/worktree"
STUB_BIN_DIR="${TMP_DIR}/bin"
REGISTRY_PATH="${TMP_DIR}/state/orca/observed-sessions.json"
TMUX_SESSIONS_FILE="${TMP_DIR}/tmux-sessions"
TMUX_WINDOWS_FILE="${TMP_DIR}/tmux-windows"
TMUX_LOG="${TMP_DIR}/tmux.log"

SESSION_ACTIVE="orca-agent-1-20260314T120000Z"
SESSION_INACTIVE="orca-agent-2-20260314T130000Z"

cleanup() {
  git -C "${ROOT}" worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

git -C "${ROOT}" worktree add --detach "${WORKTREE_DIR}" HEAD >/dev/null

mkdir -p "${WORKTREE_DIR}/lib" "${WORKTREE_DIR}/agent-logs/sessions/2026/03/14" "${STUB_BIN_DIR}" "$(dirname "${REGISTRY_PATH}")"
cp "${ROOT}/orca.sh" "${WORKTREE_DIR}/orca.sh"
cp "${ROOT}/targets.sh" "${WORKTREE_DIR}/targets.sh"
cp "${ROOT}/jump.sh" "${WORKTREE_DIR}/jump.sh"
cp "${ROOT}/lib/observed-registry.sh" "${WORKTREE_DIR}/lib/observed-registry.sh"
cp "${ROOT}/lib/tmux-target.sh" "${WORKTREE_DIR}/lib/tmux-target.sh"

mkdir -p "${WORKTREE_DIR}/agent-logs/sessions/2026/03/14/${SESSION_ACTIVE}"
cat > "${WORKTREE_DIR}/agent-logs/sessions/2026/03/14/${SESSION_ACTIVE}/session.log" <<'LOG'
[2026-03-14T12:00:00Z] [agent-1] starting loop
LOG

mkdir -p "${WORKTREE_DIR}/agent-logs/sessions/2026/03/14/${SESSION_INACTIVE}"
cat > "${WORKTREE_DIR}/agent-logs/sessions/2026/03/14/${SESSION_INACTIVE}/session.log" <<'LOG'
[2026-03-14T13:00:00Z] [agent-2] starting loop
LOG

cat > "${REGISTRY_PATH}" <<'JSON'
{"schema_version":"orca.observed.v1","updated_at":"2026-03-14T12:00:00Z","entries":[{"id":"observed-active","mode":"observed","lifecycle":"persistent","tmux_target":"dev:main","source":"monitor_add"},{"id":"observed-dup","mode":"observed","lifecycle":"persistent","tmux_target":"orca-agent-1","source":"monitor_add"},{"id":"observed-inactive","mode":"observed","lifecycle":"ephemeral","tmux_target":"offline","source":"observe_start"}]}
JSON

cat > "${TMUX_SESSIONS_FILE}" <<'SESSIONS'
orca-agent-1
dev
rawonly
SESSIONS

cat > "${TMUX_WINDOWS_FILE}" <<'WINDOWS'
dev:main
WINDOWS

: > "${TMUX_LOG}"

cat > "${STUB_BIN_DIR}/tmux" <<'TMUX'
#!/usr/bin/env bash
set -euo pipefail

sessions_file="${ORCA_TEST_TMUX_SESSIONS:?missing ORCA_TEST_TMUX_SESSIONS}"
windows_file="${ORCA_TEST_TMUX_WINDOWS:?missing ORCA_TEST_TMUX_WINDOWS}"
log_file="${ORCA_TEST_TMUX_LOG:?missing ORCA_TEST_TMUX_LOG}"

session_exists() {
  grep -Fx -- "$1" "${sessions_file}" >/dev/null 2>&1
}

window_exists() {
  local session="$1"
  local window="$2"
  grep -Fx -- "${session}:${window}" "${windows_file}" >/dev/null 2>&1
}

target_exists() {
  local target="$1"
  if [[ "${target}" == *:* ]]; then
    local session="${target%%:*}"
    local window="${target#*:}"
    session_exists "${session}" && window_exists "${session}" "${window}"
    return
  fi
  session_exists "${target}"
}

if [[ "${1:-}" == "ls" && "${2:-}" == "-F" && "${3:-}" == "#S" ]]; then
  cat "${sessions_file}"
  exit 0
fi

if [[ "${1:-}" == "has-session" && "${2:-}" == "-t" && -n "${3:-}" ]]; then
  if session_exists "${3}"; then
    exit 0
  fi
  exit 1
fi

if [[ "${1:-}" == "list-windows" && "${2:-}" == "-F" && "${3:-}" == "#W" && "${4:-}" == "-t" && -n "${5:-}" ]]; then
  if ! session_exists "${5}"; then
    exit 1
  fi
  awk -F: -v s="${5}" '$1 == s { print $2 }' "${windows_file}"
  exit 0
fi

if [[ "${1:-}" == "attach-session" && "${2:-}" == "-t" && -n "${3:-}" ]]; then
  echo "attach-session -t ${3}" >> "${log_file}"
  if target_exists "${3}"; then
    exit 0
  fi
  exit 1
fi

if [[ "${1:-}" == "switch-client" && "${2:-}" == "-t" && -n "${3:-}" ]]; then
  echo "switch-client -t ${3}" >> "${log_file}"
  if target_exists "${3}"; then
    exit 0
  fi
  exit 1
fi

echo "$*" >> "${log_file}"
exit 1
TMUX
chmod +x "${STUB_BIN_DIR}/tmux"

run_orca() {
  (
    cd "${WORKTREE_DIR}"
    PATH="${STUB_BIN_DIR}:/usr/bin:/bin" \
      ORCA_OBSERVED_REGISTRY_PATH="${REGISTRY_PATH}" \
      ORCA_TEST_TMUX_SESSIONS="${TMUX_SESSIONS_FILE}" \
      ORCA_TEST_TMUX_WINDOWS="${TMUX_WINDOWS_FILE}" \
      ORCA_TEST_TMUX_LOG="${TMUX_LOG}" \
      TMUX="" \
      bash ./orca.sh "$@"
  )
}

run_orca_attached() {
  (
    cd "${WORKTREE_DIR}"
    PATH="${STUB_BIN_DIR}:/usr/bin:/bin" \
      ORCA_OBSERVED_REGISTRY_PATH="${REGISTRY_PATH}" \
      ORCA_TEST_TMUX_SESSIONS="${TMUX_SESSIONS_FILE}" \
      ORCA_TEST_TMUX_WINDOWS="${TMUX_WINDOWS_FILE}" \
      ORCA_TEST_TMUX_LOG="${TMUX_LOG}" \
      TMUX="stub-client,123,0" \
      bash ./orca.sh "$@"
  )
}

: > "${TMUX_LOG}"
run_orca jump "managed:${SESSION_ACTIVE}" >/dev/null
if ! grep -Fx "attach-session -t orca-agent-1" "${TMUX_LOG}" >/dev/null; then
  echo "expected detached jump to attach managed tmux target" >&2
  exit 1
fi

: > "${TMUX_LOG}"
run_orca_attached jump "managed:${SESSION_ACTIVE}" >/dev/null
if ! grep -Fx "switch-client -t orca-agent-1" "${TMUX_LOG}" >/dev/null; then
  echo "expected attached jump to switch tmux client" >&2
  exit 1
fi
if grep -F "attach-session" "${TMUX_LOG}" >/dev/null; then
  echo "attached jump must not run attach-session" >&2
  exit 1
fi

: > "${TMUX_LOG}"
run_orca jump "rawonly" >/dev/null
if ! grep -Fx "attach-session -t rawonly" "${TMUX_LOG}" >/dev/null; then
  echo "expected explicit tmux fallback for rawonly session" >&2
  exit 1
fi

: > "${TMUX_LOG}"
set +e
inactive_output="$(run_orca jump "managed:${SESSION_INACTIVE}" 2>&1)"
inactive_rc=$?
set -e
if [[ "${inactive_rc}" -ne 3 ]]; then
  echo "expected inactive managed target to exit 3, got ${inactive_rc}" >&2
  exit 1
fi
if ! grep -F "inactive" <<<"${inactive_output}" >/dev/null; then
  echo "expected inactive error message for managed target" >&2
  exit 1
fi
if grep -E "attach-session|switch-client" "${TMUX_LOG}" >/dev/null; then
  echo "inactive target must not attempt tmux client jump actions" >&2
  exit 1
fi

: > "${TMUX_LOG}"
set +e
ambiguous_output="$(run_orca jump "orca-agent-1" 2>&1)"
ambiguous_rc=$?
set -e
if [[ "${ambiguous_rc}" -ne 3 ]]; then
  echo "expected ambiguous tmux target to exit 3, got ${ambiguous_rc}" >&2
  exit 1
fi
if ! grep -F "ambiguous tmux target" <<<"${ambiguous_output}" >/dev/null; then
  echo "expected ambiguous tmux target error message" >&2
  exit 1
fi

set +e
missing_output="$(run_orca jump "missing-target" 2>&1)"
missing_rc=$?
set -e
if [[ "${missing_rc}" -ne 3 ]]; then
  echo "expected missing tmux target to exit 3, got ${missing_rc}" >&2
  exit 1
fi
if ! grep -F "not found or inactive" <<<"${missing_output}" >/dev/null; then
  echo "expected missing tmux target error message" >&2
  exit 1
fi

set +e
invalid_output="$(run_orca jump "bad/id" 2>&1)"
invalid_rc=$?
set -e
if [[ "${invalid_rc}" -ne 4 ]]; then
  echo "expected invalid target syntax to exit 4, got ${invalid_rc}" >&2
  exit 1
fi
if ! grep -F "neither a known logical id nor a valid tmux target" <<<"${invalid_output}" >/dev/null; then
  echo "expected invalid target syntax error message" >&2
  exit 1
fi

if grep -E "kill-session|new-session" "${TMUX_LOG}" >/dev/null; then
  echo "jump command must not create or kill tmux sessions" >&2
  exit 1
fi

echo "jump command regression checks passed"
