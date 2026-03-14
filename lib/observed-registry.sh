#!/usr/bin/env bash

orca_observed_registry_default_path() {
  local state_home="${XDG_STATE_HOME:-${HOME}/.local/state}"
  printf '%s\n' "${state_home}/orca/observed-sessions.json"
}

orca_observed_registry_path() {
  local requested_path="${1:-}"

  if [[ -n "${requested_path}" ]]; then
    printf '%s\n' "${requested_path}"
    return 0
  fi

  if [[ -n "${ORCA_OBSERVED_REGISTRY_PATH:-}" ]]; then
    printf '%s\n' "${ORCA_OBSERVED_REGISTRY_PATH}"
    return 0
  fi

  orca_observed_registry_default_path
}

orca_observed_registry_lock_path() {
  local registry_path="${1:-}"
  local dir=""

  if [[ -z "${registry_path}" ]]; then
    registry_path="$(orca_observed_registry_path)"
  fi

  dir="$(dirname "${registry_path}")"
  printf '%s\n' "${dir}/observed-sessions.lock"
}

_orca_observed_registry_now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

_orca_observed_registry_empty_document() {
  local now=""
  now="$(_orca_observed_registry_now_utc)"

  jq -cn --arg now "${now}" '{schema_version:"orca.observed.v1", updated_at:$now, entries:[]}'
}

_orca_observed_registry_write_atomic() {
  local registry_path="$1"
  local payload="$2"
  local dir=""
  local tmp_path=""

  dir="$(dirname "${registry_path}")"
  mkdir -p "${dir}"
  tmp_path="$(mktemp "${dir}/.observed-sessions.tmp.XXXXXX")"

  if ! printf '%s\n' "${payload}" >"${tmp_path}"; then
    rm -f "${tmp_path}"
    return 1
  fi

  if ! mv -f "${tmp_path}" "${registry_path}"; then
    rm -f "${tmp_path}"
    return 1
  fi
}

_orca_observed_registry_ensure_file() {
  local registry_path="$1"
  local payload=""

  if [[ -f "${registry_path}" ]]; then
    return 0
  fi

  payload="$(_orca_observed_registry_empty_document)"
  _orca_observed_registry_write_atomic "${registry_path}" "${payload}"
}

_orca_observed_registry_read_document() {
  local registry_path="$1"

  _orca_observed_registry_ensure_file "${registry_path}"
  cat "${registry_path}"
}

_orca_observed_registry_validate_document() {
  local payload="$1"

  jq -ce '
    if type != "object" then
      error("registry must be a JSON object")
    elif (.schema_version // "") != "orca.observed.v1" then
      error("registry.schema_version must equal orca.observed.v1")
    elif ((.updated_at // null) | type) != "string" then
      error("registry.updated_at must be a string")
    elif ((.entries // null) | type) != "array" then
      error("registry.entries must be an array")
    elif ([.entries[] | select(((.id // null) | type) != "string" or .id == "") ] | length) > 0 then
      error("every entry.id must be a non-empty string")
    elif ([.entries[] | select(((.tmux_target // null) | type) != "string" or .tmux_target == "") ] | length) > 0 then
      error("every entry.tmux_target must be a non-empty string")
    elif (([.entries[].id] | unique | length) != ([.entries[].id] | length)) then
      error("registry contains duplicate id values")
    elif (([.entries[].tmux_target] | unique | length) != ([.entries[].tmux_target] | length)) then
      error("registry contains duplicate tmux_target values")
    else . end
  ' <<<"${payload}"
}

_orca_observed_registry_validate_entry() {
  local entry_json="$1"

  jq -ce '
    if type != "object" then
      error("entry must be a JSON object")
    elif ((.id // null) | type) != "string" or .id == "" then
      error("entry.id must be a non-empty string")
    elif ((.tmux_target // null) | type) != "string" or .tmux_target == "" then
      error("entry.tmux_target must be a non-empty string")
    else . end
  ' <<<"${entry_json}"
}

_orca_observed_registry_with_lock() {
  local registry_path="$1"
  local lock_path=""
  local lock_dir=""

  shift
  lock_path="$(orca_observed_registry_lock_path "${registry_path}")"
  lock_dir="$(dirname "${lock_path}")"

  mkdir -p "$(dirname "${registry_path}")" "${lock_dir}"

  (
    flock -x 9
    "$@"
  ) 9>"${lock_path}"
}

_orca_observed_registry_list_locked() {
  local registry_path="$1"
  local document=""
  local normalized=""

  document="$(_orca_observed_registry_read_document "${registry_path}")"
  normalized="$(_orca_observed_registry_validate_document "${document}")"
  jq -ce '.entries' <<<"${normalized}"
}

orca_observed_registry_list() {
  local registry_path=""

  registry_path="$(orca_observed_registry_path "${1:-}")"
  _orca_observed_registry_with_lock "${registry_path}" _orca_observed_registry_list_locked "${registry_path}"
}

_orca_observed_registry_add_locked() {
  local registry_path="$1"
  local entry_json="$2"
  local document=""
  local normalized=""
  local normalized_entry=""
  local entry_id=""
  local entry_tmux_target=""
  local now=""
  local updated_document=""

  document="$(_orca_observed_registry_read_document "${registry_path}")"
  normalized="$(_orca_observed_registry_validate_document "${document}")"
  normalized_entry="$(_orca_observed_registry_validate_entry "${entry_json}")"

  entry_id="$(jq -r '.id' <<<"${normalized_entry}")"
  entry_tmux_target="$(jq -r '.tmux_target' <<<"${normalized_entry}")"

  if jq -e --arg id "${entry_id}" '.entries[] | select(.id == $id)' <<<"${normalized}" >/dev/null; then
    echo "[observed-registry] duplicate id: ${entry_id}" >&2
    return 1
  fi

  if jq -e --arg tmux_target "${entry_tmux_target}" '.entries[] | select(.tmux_target == $tmux_target)' <<<"${normalized}" >/dev/null; then
    echo "[observed-registry] duplicate tmux_target: ${entry_tmux_target}" >&2
    return 1
  fi

  now="$(_orca_observed_registry_now_utc)"
  updated_document="$(jq -ce \
    --arg now "${now}" \
    --argjson entry "${normalized_entry}" \
    '.updated_at = $now | .entries += [$entry]' <<<"${normalized}")"

  _orca_observed_registry_write_atomic "${registry_path}" "${updated_document}"
  printf '%s\n' "${normalized_entry}"
}

orca_observed_registry_add() {
  local entry_json="${1:-}"
  local registry_path=""

  if [[ -z "${entry_json}" ]]; then
    echo "[observed-registry] entry JSON argument is required" >&2
    return 1
  fi

  registry_path="$(orca_observed_registry_path "${2:-}")"
  _orca_observed_registry_with_lock "${registry_path}" _orca_observed_registry_add_locked "${registry_path}" "${entry_json}"
}

_orca_observed_registry_remove_locked() {
  local registry_path="$1"
  local remove_id="$2"
  local document=""
  local normalized=""
  local removed_entry=""
  local now=""
  local updated_document=""

  document="$(_orca_observed_registry_read_document "${registry_path}")"
  normalized="$(_orca_observed_registry_validate_document "${document}")"

  removed_entry="$(jq -ce --arg id "${remove_id}" '.entries[] | select(.id == $id)' <<<"${normalized}" | head -n 1)"
  if [[ -z "${removed_entry}" ]]; then
    echo "[observed-registry] id not found: ${remove_id}" >&2
    return 1
  fi

  now="$(_orca_observed_registry_now_utc)"
  updated_document="$(jq -ce --arg id "${remove_id}" --arg now "${now}" '.updated_at = $now | .entries = [.entries[] | select(.id != $id)]' <<<"${normalized}")"

  _orca_observed_registry_write_atomic "${registry_path}" "${updated_document}"
  printf '%s\n' "${removed_entry}"
}

orca_observed_registry_remove() {
  local remove_id="${1:-}"
  local registry_path=""

  if [[ -z "${remove_id}" ]]; then
    echo "[observed-registry] id argument is required" >&2
    return 1
  fi

  registry_path="$(orca_observed_registry_path "${2:-}")"
  _orca_observed_registry_with_lock "${registry_path}" _orca_observed_registry_remove_locked "${registry_path}" "${remove_id}"
}
