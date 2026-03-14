#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
WORKTREE_DIR="${TMP_DIR}/worktree"
STUB_BIN_DIR="${TMP_DIR}/bin"
REGISTRY_PATH="${TMP_DIR}/state/orca/observed-sessions.json"
TMUX_SESSIONS_FILE="${TMP_DIR}/tmux-sessions"
TMUX_WINDOWS_FILE="${TMP_DIR}/tmux-windows"

SESSION_1="orca-agent-1-20260314T120000Z"
SESSION_2="orca-agent-2-20260314T130000Z"

cleanup() {
  git -C "${ROOT}" worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

git -C "${ROOT}" worktree add --detach "${WORKTREE_DIR}" HEAD >/dev/null

mkdir -p "${WORKTREE_DIR}/lib" "${WORKTREE_DIR}/agent-logs/sessions/2026/03/14" "${STUB_BIN_DIR}" "$(dirname "${REGISTRY_PATH}")"
cp "${ROOT}/orca.sh" "${WORKTREE_DIR}/orca.sh"
cp "${ROOT}/targets.sh" "${WORKTREE_DIR}/targets.sh"
cp "${ROOT}/lib/observed-registry.sh" "${WORKTREE_DIR}/lib/observed-registry.sh"
cp "${ROOT}/lib/tmux-target.sh" "${WORKTREE_DIR}/lib/tmux-target.sh"
chmod +x "${WORKTREE_DIR}/orca.sh" "${WORKTREE_DIR}/targets.sh"

mkdir -p "${WORKTREE_DIR}/agent-logs/sessions/2026/03/14/${SESSION_1}"
cat > "${WORKTREE_DIR}/agent-logs/sessions/2026/03/14/${SESSION_1}/session.log" <<'LOG'
[2026-03-14T12:00:00Z] [agent-1] starting loop
LOG

mkdir -p "${WORKTREE_DIR}/agent-logs/sessions/2026/03/14/${SESSION_2}"
cat > "${WORKTREE_DIR}/agent-logs/sessions/2026/03/14/${SESSION_2}/session.log" <<'LOG'
[2026-03-14T13:00:00Z] [agent-2] starting loop
LOG

cat > "${REGISTRY_PATH}" <<'JSON'
{"schema_version":"orca.observed.v1","updated_at":"2026-03-14T12:00:00Z","entries":[{"id":"observed-a","mode":"observed","lifecycle":"persistent","tmux_target":"dev:main","source":"monitor_add"},{"id":"observed-b","mode":"observed","lifecycle":"ephemeral","tmux_target":"sandbox","source":"observe_start"}]}
JSON

cat > "${TMUX_SESSIONS_FILE}" <<'SESSIONS'
orca-agent-1
dev
SESSIONS

cat > "${TMUX_WINDOWS_FILE}" <<'WINDOWS'
dev:main
WINDOWS

cat > "${STUB_BIN_DIR}/tmux" <<'TMUX'
#!/usr/bin/env bash
set -euo pipefail

sessions_file="${ORCA_TEST_TMUX_SESSIONS:?missing ORCA_TEST_TMUX_SESSIONS}"
windows_file="${ORCA_TEST_TMUX_WINDOWS:?missing ORCA_TEST_TMUX_WINDOWS}"

has_session() {
  grep -Fx -- "$1" "${sessions_file}" >/dev/null 2>&1
}

list_windows() {
  local session="$1"
  awk -F: -v s="${session}" '$1 == s { print $2 }' "${windows_file}"
}

if [[ "${1:-}" == "ls" && "${2:-}" == "-F" && "${3:-}" == "#S" ]]; then
  cat "${sessions_file}"
  exit 0
fi

if [[ "${1:-}" == "has-session" && "${2:-}" == "-t" && -n "${3:-}" ]]; then
  if has_session "${3}"; then
    exit 0
  fi
  exit 1
fi

if [[ "${1:-}" == "list-windows" && "${2:-}" == "-F" && "${3:-}" == "#W" && "${4:-}" == "-t" && -n "${5:-}" ]]; then
  if ! has_session "${5}"; then
    exit 1
  fi
  list_windows "${5}"
  exit 0
fi

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
      bash ./orca.sh "$@"
  )
}

json_output="$(run_orca targets --json)"

if ! jq -e 'type == "array" and length == 4' >/dev/null <<< "${json_output}"; then
  echo "expected exactly four unified targets in json output" >&2
  exit 1
fi

if ! jq -e 'all(.[]; ((keys | sort) == ["active","id","mode","session_id","tmux_target"]))' >/dev/null <<< "${json_output}"; then
  echo "expected stable normalized target fields in json output" >&2
  exit 1
fi

if ! jq -e --arg sid "${SESSION_1}" 'any(.[]; .id == ("managed:" + $sid) and .mode == "managed" and .tmux_target == "orca-agent-1" and .active == true and .session_id == $sid)' >/dev/null <<< "${json_output}"; then
  echo "expected active managed target for session 1" >&2
  exit 1
fi

if ! jq -e --arg sid "${SESSION_2}" 'any(.[]; .id == ("managed:" + $sid) and .mode == "managed" and .tmux_target == "orca-agent-2" and .active == false and .session_id == $sid)' >/dev/null <<< "${json_output}"; then
  echo "expected inactive managed target for session 2 with inferred tmux target" >&2
  exit 1
fi

if ! jq -e 'any(.[]; .id == "observed:observed-a" and .mode == "observed" and .tmux_target == "dev:main" and .active == true and .session_id == "observed-a")' >/dev/null <<< "${json_output}"; then
  echo "expected active observed target for observed-a" >&2
  exit 1
fi

if ! jq -e 'any(.[]; .id == "observed:observed-b" and .mode == "observed" and .tmux_target == "sandbox" and .active == false and .session_id == "observed-b")' >/dev/null <<< "${json_output}"; then
  echo "expected inactive observed target for observed-b" >&2
  exit 1
fi

if ! jq -e '[.[] | [.mode, .id]] == ([.[] | [.mode, .id]] | sort)' >/dev/null <<< "${json_output}"; then
  echo "expected deterministic sorted order by mode/id in json output" >&2
  exit 1
fi

plain_output="$(run_orca targets)"
if ! grep -F $'ID\tMODE\tTMUX_TARGET\tACTIVE\tSESSION_ID' <<< "${plain_output}" >/dev/null; then
  echo "expected table header in plain output" >&2
  exit 1
fi
if ! grep -F $'observed:observed-a\tobserved\tdev:main\ttrue\tobserved-a' <<< "${plain_output}" >/dev/null; then
  echo "expected observed-a row in plain output" >&2
  exit 1
fi

filtered_prefix_json="$(run_orca targets --json --session-prefix observed-)"
if ! jq -e 'length == 2 and all(.[]; .mode == "observed")' >/dev/null <<< "${filtered_prefix_json}"; then
  echo "expected --session-prefix filtering to scope observed session ids" >&2
  exit 1
fi

filtered_id_json="$(run_orca targets --json --session-id "${SESSION_1}")"
if ! jq -e --arg sid "${SESSION_1}" 'length == 1 and .[0].id == ("managed:" + $sid)' >/dev/null <<< "${filtered_id_json}"; then
  echo "expected --session-id filtering to return exact managed target" >&2
  exit 1
fi

echo "targets inventory regression checks passed"
