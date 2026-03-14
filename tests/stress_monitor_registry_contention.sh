#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
REGISTRY_PATH="${TMP_DIR}/state/orca/observed-sessions.json"

WRITER_COUNT=6
READER_COUNT=4
WRITER_ITERATIONS=120
READER_ITERATIONS=180
ID_POOL_SIZE=18
PROCESS_TIMEOUT_SECONDS=75

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# shellcheck source=/dev/null
source "${ROOT}/lib/observed-registry.sh"

tmp_registry_file_count() {
  find "$(dirname "${REGISTRY_PATH}")" -maxdepth 1 -name '.observed-sessions.tmp.*' | wc -l | tr -d '[:space:]'
}

wait_for_pid_with_timeout() {
  local pid="$1"
  local timeout_seconds="$2"
  local elapsed=0

  while kill -0 "${pid}" >/dev/null 2>&1; do
    if [[ "${elapsed}" -ge "${timeout_seconds}" ]]; then
      kill "${pid}" >/dev/null 2>&1 || true
      wait "${pid}" >/dev/null 2>&1 || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "${pid}"
}

assert_registry_document_valid() {
  jq -e '
    .schema_version == "orca.observed.v1"
    and ((.updated_at | type) == "string")
    and ((.entries | type) == "array")
    and (([.entries[].id] | unique | length) == (.entries | length))
    and (([.entries[].tmux_target] | unique | length) == (.entries | length))
    and ([.entries[] | select(((.id // null) | type) != "string" or .id == "" or (.id | test("^[A-Za-z0-9._:-]+$") | not))] | length == 0)
    and ([.entries[] | select(((.tmux_target // null) | type) != "string" or .tmux_target == "")] | length == 0)
    and ([.entries[] | select(((.lifecycle // null) | type) != "null" and ((.lifecycle // null) | type) != "string")] | length == 0)
    and ([.entries[] | select(((.lifecycle // null) | type) == "string" and .lifecycle != "ephemeral" and .lifecycle != "persistent")] | length == 0)
  ' "${REGISTRY_PATH}" >/dev/null
}

assert_entries_array_valid() {
  local entries_json="$1"
  jq -e '
    type == "array"
    and (([.[].id] | unique | length) == length)
    and (([.[].tmux_target] | unique | length) == length)
    and ([.[] | select(((.id // null) | type) != "string" or .id == "" or (.id | test("^[A-Za-z0-9._:-]+$") | not))] | length == 0)
    and ([.[] | select(((.tmux_target // null) | type) != "string" or .tmux_target == "")] | length == 0)
    and ([.[] | select(((.lifecycle // null) | type) != "null" and ((.lifecycle // null) | type) != "string")] | length == 0)
    and ([.[] | select(((.lifecycle // null) | type) == "string" and .lifecycle != "ephemeral" and .lifecycle != "persistent")] | length == 0)
  ' <<<"${entries_json}" >/dev/null
}

writer_loop() {
  local writer_idx="$1"
  local iteration=0
  local id_num=0
  local id=""
  local tmux_target=""
  local lifecycle=""
  local list_json=""

  for iteration in $(seq 1 "${WRITER_ITERATIONS}"); do
    id_num=$(((writer_idx + iteration) % ID_POOL_SIZE))
    id="stress-${id_num}"
    tmux_target="stress-target-${id_num}"
    lifecycle="persistent"
    if (((iteration + writer_idx) % 2 == 0)); then
      lifecycle="ephemeral"
    fi

    if (((iteration + writer_idx) % 3 == 0)); then
      orca_observed_registry_remove "${id}" "${REGISTRY_PATH}" >/dev/null 2>&1 || true
    else
      orca_observed_registry_add "{\"id\":\"${id}\",\"mode\":\"observed\",\"lifecycle\":\"${lifecycle}\",\"tmux_target\":\"${tmux_target}\",\"source\":\"stress_writer_${writer_idx}\"}" "${REGISTRY_PATH}" >/dev/null 2>&1 || true
    fi

    if ((iteration % 4 == 0)); then
      if ! list_json="$(orca_observed_registry_list "${REGISTRY_PATH}")"; then
        echo "writer ${writer_idx}: list failed during contention at iteration ${iteration}" >&2
        return 1
      fi
      if ! assert_entries_array_valid "${list_json}"; then
        echo "writer ${writer_idx}: list invariants failed at iteration ${iteration}" >&2
        return 1
      fi
    fi
  done
}

reader_loop() {
  local reader_idx="$1"
  local iteration=0
  local list_json=""

  for iteration in $(seq 1 "${READER_ITERATIONS}"); do
    if ! assert_registry_document_valid; then
      echo "reader ${reader_idx}: raw registry JSON/schema validation failed at iteration ${iteration}" >&2
      return 1
    fi

    if ! list_json="$(orca_observed_registry_list "${REGISTRY_PATH}")"; then
      echo "reader ${reader_idx}: list failed during contention at iteration ${iteration}" >&2
      return 1
    fi
    if ! assert_entries_array_valid "${list_json}"; then
      echo "reader ${reader_idx}: list invariants failed at iteration ${iteration}" >&2
      return 1
    fi
  done
}

spawn_worker() {
  local label="$1"
  local worker="$2"
  local worker_idx="$3"
  local log_path="${TMP_DIR}/${label}.log"

  (
    set -euo pipefail
    "${worker}" "${worker_idx}"
  ) >"${log_path}" 2>&1 &

  WORKER_PIDS+=("$!")
  WORKER_LABELS+=("${label}")
  WORKER_LOGS+=("${log_path}")
}

orca_observed_registry_list "${REGISTRY_PATH}" >/dev/null

declare -a WORKER_PIDS=()
declare -a WORKER_LABELS=()
declare -a WORKER_LOGS=()

for writer_idx in $(seq 1 "${WRITER_COUNT}"); do
  spawn_worker "writer-${writer_idx}" "writer_loop" "${writer_idx}"
done

for reader_idx in $(seq 1 "${READER_COUNT}"); do
  spawn_worker "reader-${reader_idx}" "reader_loop" "${reader_idx}"
done

for idx in "${!WORKER_PIDS[@]}"; do
  pid="${WORKER_PIDS[$idx]}"
  label="${WORKER_LABELS[$idx]}"
  log_path="${WORKER_LOGS[$idx]}"

  set +e
  wait_for_pid_with_timeout "${pid}" "${PROCESS_TIMEOUT_SECONDS}"
  worker_rc=$?
  set -e

  if [[ "${worker_rc}" -ne 0 ]]; then
    if [[ "${worker_rc}" -eq 124 ]]; then
      echo "${label} timed out after ${PROCESS_TIMEOUT_SECONDS}s (possible deadlock)" >&2
    else
      echo "${label} failed with exit ${worker_rc}" >&2
    fi
    if [[ -s "${log_path}" ]]; then
      cat "${log_path}" >&2
    fi
    exit 1
  fi
done

final_entries="$(orca_observed_registry_list "${REGISTRY_PATH}")"
if ! assert_entries_array_valid "${final_entries}"; then
  echo "final registry entries violated invariants after contention run" >&2
  exit 1
fi

if ! assert_registry_document_valid; then
  echo "final raw registry document validation failed after contention run" >&2
  exit 1
fi

if [[ "$(tmp_registry_file_count)" -ne 0 ]]; then
  echo "expected no temporary registry files after contention stress run" >&2
  exit 1
fi

echo "monitor registry contention stress checks passed"
