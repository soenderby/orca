#!/usr/bin/env bash

_orca_tmux_target_component_is_valid() {
  local component="$1"
  [[ "${component}" =~ ^[A-Za-z0-9._-]+$ ]]
}

_orca_tmux_target_parse_components() {
  local target="${1:-}"
  local session=""
  local window=""

  if [[ -z "${target}" ]]; then
    echo "[tmux-target] target is required" >&2
    return 1
  fi

  if [[ "${target}" == *:* ]]; then
    if [[ "${target}" == *:*:* ]]; then
      echo "[tmux-target] pane-level targets are not supported: ${target}" >&2
      return 1
    fi

    session="${target%%:*}"
    window="${target#*:}"

    if [[ -z "${session}" || -z "${window}" ]]; then
      echo "[tmux-target] target must be session or session:window: ${target}" >&2
      return 1
    fi

    if ! _orca_tmux_target_component_is_valid "${session}"; then
      echo "[tmux-target] invalid session name: ${session}" >&2
      return 1
    fi

    if ! _orca_tmux_target_component_is_valid "${window}"; then
      echo "[tmux-target] invalid window name: ${window}" >&2
      return 1
    fi

    printf '%s\t%s\t%s\n' "session_window" "${session}" "${window}"
    return 0
  fi

  if ! _orca_tmux_target_component_is_valid "${target}"; then
    echo "[tmux-target] invalid session name: ${target}" >&2
    return 1
  fi

  printf '%s\t%s\t%s\n' "session" "${target}" ""
}

orca_tmux_target_parse() {
  local target="${1:-}"
  local parsed=""
  local kind=""
  local session=""
  local window=""

  parsed="$(_orca_tmux_target_parse_components "${target}")"
  IFS=$'\t' read -r kind session window <<<"${parsed}"

  jq -cn \
    --arg target "${target}" \
    --arg kind "${kind}" \
    --arg session "${session}" \
    --arg window "${window}" \
    '{target:$target, kind:$kind, session:$session, window:(if $window == "" then null else $window end)}'
}

orca_tmux_target_validate() {
  local target="${1:-}"

  _orca_tmux_target_parse_components "${target}" >/dev/null
}

orca_tmux_target_exists() {
  local target="${1:-}"
  local parsed=""
  local kind=""
  local session=""
  local window=""

  parsed="$(_orca_tmux_target_parse_components "${target}")"
  IFS=$'\t' read -r kind session window <<<"${parsed}"

  if [[ "${kind}" == "session" ]]; then
    tmux has-session -t "${session}" >/dev/null 2>&1
    return $?
  fi

  if ! tmux has-session -t "${session}" >/dev/null 2>&1; then
    return 1
  fi

  tmux list-windows -F '#W' -t "${session}" 2>/dev/null | grep -Fx -- "${window}" >/dev/null
}

orca_tmux_target_probe() {
  local target="${1:-}"
  local parsed_json=""

  parsed_json="$(orca_tmux_target_parse "${target}")"

  if orca_tmux_target_exists "${target}"; then
    jq -ce '. + {exists: true}' <<<"${parsed_json}"
  else
    jq -ce '. + {exists: false}' <<<"${parsed_json}"
  fi
}
