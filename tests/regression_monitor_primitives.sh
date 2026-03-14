#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
REGISTRY_PATH="${TMP_DIR}/state/orca/observed-sessions.json"
STUB_BIN_DIR="${TMP_DIR}/bin"
TMUX_LOG="${TMP_DIR}/tmux.log"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# shellcheck source=/dev/null
source "${ROOT}/lib/observed-registry.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/tmux-target.sh"

registry_inode() {
  stat -c '%i' "${REGISTRY_PATH}"
}

tmp_registry_file_count() {
  find "$(dirname "${REGISTRY_PATH}")" -maxdepth 1 -name '.observed-sessions.tmp.*' | wc -l | tr -d '[:space:]'
}

list_output="$(orca_observed_registry_list "${REGISTRY_PATH}")"
if [[ "$(jq -r 'length' <<<"${list_output}")" -ne 0 ]]; then
  echo "expected empty registry on first list" >&2
  exit 1
fi
inode_after_first_list="$(registry_inode)"

added_one="$(orca_observed_registry_add '{"id":"agent-a","mode":"observed","lifecycle":"persistent","tmux_target":"work","source":"monitor_add"}' "${REGISTRY_PATH}")"
if [[ "$(jq -r '.id' <<<"${added_one}")" != "agent-a" ]]; then
  echo "expected added entry for agent-a" >&2
  exit 1
fi
inode_after_first_add="$(registry_inode)"
if [[ -z "${inode_after_first_add}" || -z "${inode_after_first_list}" ]]; then
  echo "expected registry file inode metadata to be available" >&2
  exit 1
fi

orca_observed_registry_add '{"id":"agent-b","mode":"observed","lifecycle":"ephemeral","tmux_target":"work:ops","source":"observe_start"}' "${REGISTRY_PATH}" >/dev/null

if orca_observed_registry_add '{"id":"agent-a","mode":"observed","lifecycle":"persistent","tmux_target":"work:dupe"}' "${REGISTRY_PATH}" >/dev/null 2>&1; then
  echo "expected duplicate id add to fail" >&2
  exit 1
fi

if orca_observed_registry_add '{"id":"agent-c","mode":"observed","lifecycle":"persistent","tmux_target":"work:ops"}' "${REGISTRY_PATH}" >/dev/null 2>&1; then
  echo "expected duplicate tmux_target add to fail" >&2
  exit 1
fi

registry_after_adds="$(orca_observed_registry_list "${REGISTRY_PATH}")"
if [[ "$(jq -r 'length' <<<"${registry_after_adds}")" -ne 2 ]]; then
  echo "expected two registry entries after successful adds" >&2
  exit 1
fi

if [[ "$(jq -r 'map(.id) | sort | join(",")' <<<"${registry_after_adds}")" != "agent-a,agent-b" ]]; then
  echo "unexpected registry ids after adds" >&2
  exit 1
fi

removed="$(orca_observed_registry_remove "agent-a" "${REGISTRY_PATH}")"
if [[ "$(jq -r '.id' <<<"${removed}")" != "agent-a" ]]; then
  echo "expected removed entry for agent-a" >&2
  exit 1
fi
inode_after_first_remove="$(registry_inode)"
if [[ -z "${inode_after_first_remove}" ]]; then
  echo "expected registry file inode metadata after remove" >&2
  exit 1
fi

if orca_observed_registry_remove "missing" "${REGISTRY_PATH}" >/dev/null 2>&1; then
  echo "expected removing missing id to fail" >&2
  exit 1
fi

registry_after_remove="$(orca_observed_registry_list "${REGISTRY_PATH}")"
if [[ "$(jq -r 'length' <<<"${registry_after_remove}")" -ne 1 ]]; then
  echo "expected one registry entry after remove" >&2
  exit 1
fi

if [[ "$(jq -r '.[0].id' <<<"${registry_after_remove}")" != "agent-b" ]]; then
  echo "expected agent-b to remain after removal" >&2
  exit 1
fi

if [[ "$(jq -r '.schema_version' "${REGISTRY_PATH}")" != "orca.observed.v1" ]]; then
  echo "unexpected schema_version in registry file" >&2
  exit 1
fi

mkdir -p "${STUB_BIN_DIR}"
cat > "${STUB_BIN_DIR}/tmux" <<'TMUX'
#!/usr/bin/env bash
set -euo pipefail
log_path="${ORCA_TEST_TMUX_LOG:?missing ORCA_TEST_TMUX_LOG}"
printf '%s\n' "$*" >>"${log_path}"

if [[ "$1" == "has-session" && "$2" == "-t" ]]; then
  if [[ "$3" == "work" ]]; then
    exit 0
  fi
  exit 1
fi

if [[ "$1" == "list-windows" && "$2" == "-F" && "$3" == "#W" && "$4" == "-t" ]]; then
  if [[ "$5" == "work" ]]; then
    printf '%s\n' "ops"
    printf '%s\n' "build"
    exit 0
  fi
  exit 1
fi

exit 1
TMUX
chmod +x "${STUB_BIN_DIR}/tmux"

parse_session="$(orca_tmux_target_parse "work")"
if [[ "$(jq -r '.kind' <<<"${parse_session}")" != "session" ]]; then
  echo "expected session kind for single-component target" >&2
  exit 1
fi

parse_window="$(orca_tmux_target_parse "work:ops")"
if [[ "$(jq -r '.kind' <<<"${parse_window}")" != "session_window" ]]; then
  echo "expected session_window kind for session:window target" >&2
  exit 1
fi

for invalid_target in "" "work:" ":ops" "work:ops:1" "work/ops" "work:bad/name"; do
  if orca_tmux_target_validate "${invalid_target}" >/dev/null 2>&1; then
    echo "expected invalid target to fail validation: ${invalid_target}" >&2
    exit 1
  fi
done

(
  export PATH="${STUB_BIN_DIR}:/usr/bin:/bin"
  export ORCA_TEST_TMUX_LOG="${TMUX_LOG}"

  if ! orca_tmux_target_exists "work"; then
    echo "expected existing session target to pass probe" >&2
    exit 1
  fi

  if ! orca_tmux_target_exists "work:ops"; then
    echo "expected existing session:window target to pass probe" >&2
    exit 1
  fi

  if orca_tmux_target_exists "work:missing"; then
    echo "expected missing window target to fail probe" >&2
    exit 1
  fi

  if orca_tmux_target_exists "missing"; then
    echo "expected missing session target to fail probe" >&2
    exit 1
  fi

  probe_json="$(orca_tmux_target_probe "work:ops")"
  if [[ "$(jq -r '.exists' <<<"${probe_json}")" != "true" ]]; then
    echo "expected probe output exists=true for work:ops" >&2
    exit 1
  fi
)

if ! grep -Fx "has-session -t work" "${TMUX_LOG}" >/dev/null; then
  echo "expected has-session check for work" >&2
  exit 1
fi

if ! grep -Fx "list-windows -F #W -t work" "${TMUX_LOG}" >/dev/null; then
  echo "expected list-windows check for work" >&2
  exit 1
fi

orca_observed_registry_remove "agent-b" "${REGISTRY_PATH}" >/dev/null
inode_after_remove="$(registry_inode)"
if [[ -z "${inode_after_remove}" ]]; then
  echo "expected registry file inode metadata after final remove" >&2
  exit 1
fi

if [[ "$(tmp_registry_file_count)" -ne 0 ]]; then
  echo "expected no temporary registry files after atomic writes" >&2
  exit 1
fi

(
  for i in $(seq 1 40); do
    orca_observed_registry_add "{\"id\":\"atomic-${i}\",\"mode\":\"observed\",\"lifecycle\":\"ephemeral\",\"tmux_target\":\"atomic-${i}\"}" "${REGISTRY_PATH}" >/dev/null
    orca_observed_registry_remove "atomic-${i}" "${REGISTRY_PATH}" >/dev/null
  done
) &
writer_pid=$!

for _ in $(seq 1 120); do
  if ! jq -e '.schema_version == "orca.observed.v1" and (.entries | type == "array")' "${REGISTRY_PATH}" >/dev/null 2>&1; then
    echo "expected registry reads to remain parseable during concurrent writes (atomicity regression)" >&2
    wait "${writer_pid}" >/dev/null 2>&1 || true
    exit 1
  fi
done

wait "${writer_pid}"

echo "monitor primitive helper regression checks passed"
