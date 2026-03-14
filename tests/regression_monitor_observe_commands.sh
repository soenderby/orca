#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
STUB_BIN_DIR="${TMP_DIR}/bin"
STATE_DIR="${TMP_DIR}/state"
REGISTRY_PATH="${STATE_DIR}/orca/observed-sessions.json"
TMUX_SESSIONS_FILE="${TMP_DIR}/tmux-sessions"
TMUX_WINDOWS_FILE="${TMP_DIR}/tmux-windows"
TMUX_LOG="${TMP_DIR}/tmux.log"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${STUB_BIN_DIR}" "$(dirname "${REGISTRY_PATH}")"
printf '%s\n' "existing" > "${TMUX_SESSIONS_FILE}"
printf '%s\n' "existing:ops" > "${TMUX_WINDOWS_FILE}"
: > "${TMUX_LOG}"

cat > "${STUB_BIN_DIR}/tmux" <<'TMUX'
#!/usr/bin/env bash
set -euo pipefail

sessions_file="${ORCA_TEST_TMUX_SESSIONS:?missing ORCA_TEST_TMUX_SESSIONS}"
windows_file="${ORCA_TEST_TMUX_WINDOWS:?missing ORCA_TEST_TMUX_WINDOWS}"
log_file="${ORCA_TEST_TMUX_LOG:?missing ORCA_TEST_TMUX_LOG}"
printf '%s\n' "$*" >>"${log_file}"

has_session() {
  grep -Fx -- "$1" "${sessions_file}" >/dev/null 2>&1
}

add_session() {
  if ! has_session "$1"; then
    printf '%s\n' "$1" >>"${sessions_file}"
  fi
}

remove_session() {
  grep -Fxv -- "$1" "${sessions_file}" >"${sessions_file}.tmp" || true
  mv -f "${sessions_file}.tmp" "${sessions_file}"
  grep -Fv -- "$1:" "${windows_file}" >"${windows_file}.tmp" || true
  mv -f "${windows_file}.tmp" "${windows_file}"
}

add_window() {
  local session="$1"
  local window="$2"
  if ! grep -Fx -- "${session}:${window}" "${windows_file}" >/dev/null 2>&1; then
    printf '%s\n' "${session}:${window}" >>"${windows_file}"
  fi
}

list_windows() {
  local session="$1"
  awk -F: -v s="${session}" '$1 == s { print $2 }' "${windows_file}"
}

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

if [[ "${1:-}" == "new-session" ]]; then
  session=""
  window=""
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d)
        ;;
      -s)
        session="${2:-}"
        shift
        ;;
      -n)
        window="${2:-}"
        shift
        ;;
      -c)
        shift
        ;;
      *)
        break
        ;;
    esac
    shift
  done
  [[ -n "${session}" ]] || exit 1
  if has_session "${session}"; then
    exit 1
  fi
  add_session "${session}"
  if [[ -n "${window}" ]]; then
    add_window "${session}" "${window}"
  fi
  exit 0
fi

if [[ "${1:-}" == "kill-session" && "${2:-}" == "-t" && -n "${3:-}" ]]; then
  if has_session "${3}"; then
    remove_session "${3}"
    exit 0
  fi
  exit 1
fi

exit 1
TMUX
chmod +x "${STUB_BIN_DIR}/tmux"

run_orca() {
  (
    cd "${ROOT}"
    PATH="${STUB_BIN_DIR}:/usr/bin:/bin" \
      ORCA_OBSERVED_REGISTRY_PATH="${REGISTRY_PATH}" \
      ORCA_TEST_TMUX_SESSIONS="${TMUX_SESSIONS_FILE}" \
      ORCA_TEST_TMUX_WINDOWS="${TMUX_WINDOWS_FILE}" \
      ORCA_TEST_TMUX_LOG="${TMUX_LOG}" \
      bash ./orca.sh "$@"
  )
}

add_output="$(run_orca monitor add --id observed-a --lifecycle persistent --tmux-target existing:ops --cwd "${ROOT}")"
if [[ "$(jq -r '.id' <<<"${add_output}")" != "observed-a" ]]; then
  echo "expected monitor add to register observed-a" >&2
  exit 1
fi

set +e
run_orca monitor add --id "bad/id" --lifecycle persistent --tmux-target existing:ops >/dev/null 2>&1
bad_id_rc=$?
set -e
if [[ "${bad_id_rc}" -ne 4 ]]; then
  echo "expected invalid id to return exit 4, got ${bad_id_rc}" >&2
  exit 1
fi

list_json="$(run_orca monitor list --json)"
if [[ "$(jq -r 'length' <<<"${list_json}")" -ne 1 ]]; then
  echo "expected one registry entry after monitor add" >&2
  exit 1
fi

run_orca monitor remove --id observed-a >/dev/null
if jq -e '.[] | select(.id == "observed-a")' <<<"$(run_orca monitor list --json)" >/dev/null; then
  echo "expected observed-a to be removed from registry" >&2
  exit 1
fi
if grep -F "kill-session" "${TMUX_LOG}" >/dev/null 2>&1; then
  echo "monitor commands must not kill tmux sessions" >&2
  exit 1
fi

log_lines_before_invalid_cwd="$(wc -l < "${TMUX_LOG}" | tr -d '[:space:]')"
set +e
run_orca observe start --id observed-b --lifecycle ephemeral --tmux-target fresh:main --cwd "${TMP_DIR}/missing" -- bash -lc "echo hi" >/dev/null 2>&1
invalid_cwd_rc=$?
set -e
if [[ "${invalid_cwd_rc}" -ne 4 ]]; then
  echo "expected invalid cwd to return exit 4, got ${invalid_cwd_rc}" >&2
  exit 1
fi
log_lines_after_invalid_cwd="$(wc -l < "${TMUX_LOG}" | tr -d '[:space:]')"
if [[ "${log_lines_before_invalid_cwd}" -ne "${log_lines_after_invalid_cwd}" ]]; then
  echo "observe start with invalid cwd should not invoke tmux" >&2
  exit 1
fi

observe_output="$(run_orca observe start --id observed-b --lifecycle ephemeral --tmux-target fresh:main --cwd "${ROOT}" -- bash -lc "echo hi")"
if [[ "$(jq -r '.source' <<<"${observe_output}")" != "observe_start" ]]; then
  echo "expected observe start source metadata" >&2
  exit 1
fi
if ! grep -Fx "new-session -d -s fresh -n main -c ${ROOT} bash -lc echo hi" "${TMUX_LOG}" >/dev/null; then
  echo "expected tmux new-session invocation for fresh:main" >&2
  exit 1
fi

run_orca monitor add --id duplicate-id --lifecycle persistent --tmux-target existing:ops >/dev/null
set +e
run_orca observe start --id duplicate-id --lifecycle persistent --tmux-target rollback:ops --cwd "${ROOT}" -- sleep 1 >/dev/null 2>&1
rollback_rc=$?
set -e
if [[ "${rollback_rc}" -ne 3 ]]; then
  echo "expected duplicate registry observe start to fail with exit 3, got ${rollback_rc}" >&2
  exit 1
fi
if ! grep -Fx "kill-session -t rollback" "${TMUX_LOG}" >/dev/null; then
  echo "expected observe rollback to attempt tmux kill-session" >&2
  exit 1
fi
if grep -Fx "rollback" "${TMUX_SESSIONS_FILE}" >/dev/null; then
  echo "expected rollback session to be removed after failed observe start" >&2
  exit 1
fi

printf '%s\n' '{"schema_version":"orca.observed.v1","updated_at":"2026-03-14T00:00:00Z","entries":[' > "${REGISTRY_PATH}"
set +e
malformed_list_output="$(run_orca monitor list --json 2>&1)"
malformed_list_rc=$?
set -e
if [[ "${malformed_list_rc}" -ne 3 ]]; then
  echo "expected malformed registry document to fail monitor list with exit 3, got ${malformed_list_rc}" >&2
  exit 1
fi
if ! grep -F "invalid observed registry document" <<<"${malformed_list_output}" >/dev/null; then
  echo "expected clear malformed registry load error in monitor list output" >&2
  exit 1
fi

cat > "${REGISTRY_PATH}" <<'JSON'
{"schema_version":"orca.observed.v1","updated_at":"2026-03-14T00:00:00Z","entries":[{"id":"observed-invalid","mode":"observed","lifecycle":"forever","tmux_target":"existing:ops","source":"monitor_add"}]}
JSON
set +e
invalid_entry_list_output="$(run_orca monitor list --json 2>&1)"
invalid_entry_list_rc=$?
set -e
if [[ "${invalid_entry_list_rc}" -ne 3 ]]; then
  echo "expected semantically invalid registry entry to fail monitor list with exit 3, got ${invalid_entry_list_rc}" >&2
  exit 1
fi
if ! grep -F "every entry.lifecycle must be one of: ephemeral, persistent" <<<"${invalid_entry_list_output}" >/dev/null; then
  echo "expected lifecycle validation error for semantically invalid persisted entries" >&2
  exit 1
fi

set +e
observe_invalid_registry_output="$(run_orca observe start --id observed-c --lifecycle persistent --tmux-target strictload:main --cwd "${ROOT}" -- sleep 1 2>&1)"
observe_invalid_registry_rc=$?
set -e
if [[ "${observe_invalid_registry_rc}" -ne 3 ]]; then
  echo "expected observe start to fail with exit 3 on invalid persisted registry entries, got ${observe_invalid_registry_rc}" >&2
  exit 1
fi
if ! grep -F "invalid observed registry document" <<<"${observe_invalid_registry_output}" >/dev/null; then
  echo "expected observe start to surface registry validation failure details" >&2
  exit 1
fi
if ! grep -Fx "kill-session -t strictload" "${TMUX_LOG}" >/dev/null; then
  echo "expected observe start rollback to kill strictload session on registry load failure" >&2
  exit 1
fi
if grep -Fx "strictload" "${TMUX_SESSIONS_FILE}" >/dev/null; then
  echo "expected strictload session to be removed after observe rollback on registry load failure" >&2
  exit 1
fi

echo "monitor/observe command regression checks passed"
