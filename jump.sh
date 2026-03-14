#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"

# shellcheck source=/dev/null
source "${ROOT}/lib/tmux-target.sh"

EXIT_SUCCESS=0
EXIT_FAILURE=3
EXIT_INVALID=4

usage() {
  cat <<'USAGE'
Usage:
  ./orca.sh jump <target>
  ./jump.sh <target>

Target resolution order:
  1. Match logical target id from `orca targets --json` (`managed:*` / `observed:*`).
  2. Fallback to explicit tmux target (`session` or `session:window`).

Behavior:
  - Inside tmux client (`TMUX` set): uses `tmux switch-client -t <target>`
  - Outside tmux client: uses `tmux attach-session -t <target>`

Exit codes:
  0  success
  3  operational failure
  4  invalid usage/config
USAGE
}

invalid() {
  echo "jump: $*" >&2
  exit "${EXIT_INVALID}"
}

fail() {
  echo "jump: $*" >&2
  exit "${EXIT_FAILURE}"
}

read_inventory_json() {
  local inventory_json=""

  if ! inventory_json="$(bash "${ROOT}/targets.sh" --json)"; then
    fail "failed to load target inventory"
  fi

  if ! jq -e 'type == "array"' >/dev/null <<<"${inventory_json}"; then
    fail "target inventory returned invalid json"
  fi

  printf '%s\n' "${inventory_json}"
}

match_count() {
  jq -r 'length' <<<"$1"
}

match_ids_csv() {
  jq -r '[.[].id // empty] | unique | join(", ")' <<<"$1"
}

resolve_target_json() {
  local requested="$1"
  local inventory_json="$2"
  local id_matches=""
  local tmux_matches=""
  local id_count=0
  local tmux_count=0
  local ids_csv=""
  local target_exists=0
  local first_match=""

  id_matches="$(
    jq -c \
      --arg requested "${requested}" \
      '[.[] | select((.id // "") == $requested)]' \
      <<<"${inventory_json}"
  )"
  id_count="$(match_count "${id_matches}")"

  if [[ "${id_count}" -gt 1 ]]; then
    ids_csv="$(match_ids_csv "${id_matches}")"
    fail "ambiguous logical target id '${requested}' matches: ${ids_csv}"
  fi

  if [[ "${id_count}" -eq 1 ]]; then
    first_match="$(jq -c '.[0]' <<<"${id_matches}")"
    if [[ "$(jq -r '(.tmux_target // "")' <<<"${first_match}")" == "" ]]; then
      fail "target '${requested}' has no tmux target mapping"
    fi
    if [[ "$(jq -r 'if (.active == true) then "true" else "false" end' <<<"${first_match}")" != "true" ]]; then
      fail "target '${requested}' is inactive"
    fi
    jq -c '. + {resolution: "logical_id"}' <<<"${first_match}"
    return 0
  fi

  if ! orca_tmux_target_validate "${requested}" >/dev/null 2>&1; then
    invalid "target '${requested}' is neither a known logical id nor a valid tmux target"
  fi

  tmux_matches="$(
    jq -c \
      --arg requested "${requested}" \
      '[.[] | select((.tmux_target // "") == $requested)]' \
      <<<"${inventory_json}"
  )"
  tmux_count="$(match_count "${tmux_matches}")"

  if [[ "${tmux_count}" -gt 1 ]]; then
    ids_csv="$(match_ids_csv "${tmux_matches}")"
    fail "ambiguous tmux target '${requested}' matches inventory ids: ${ids_csv}; use logical id"
  fi

  if [[ "${tmux_count}" -eq 1 ]]; then
    first_match="$(jq -c '.[0]' <<<"${tmux_matches}")"
    if [[ "$(jq -r 'if (.active == true) then "true" else "false" end' <<<"${first_match}")" != "true" ]]; then
      fail "target '${requested}' is inactive"
    fi
    jq -c '. + {resolution: "inventory_tmux_target"}' <<<"${first_match}"
    return 0
  fi

  if orca_tmux_target_exists "${requested}"; then
    target_exists=1
  fi

  if [[ "${target_exists}" -ne 1 ]]; then
    fail "tmux target not found or inactive: ${requested}"
  fi

  jq -nc \
    --arg requested "${requested}" \
    '{
      id: null,
      mode: "explicit",
      tmux_target: $requested,
      active: true,
      session_id: null,
      resolution: "explicit_tmux_target"
    }'
}

if [[ $# -eq 0 ]]; then
  invalid "target is required"
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit "${EXIT_SUCCESS}"
fi

REQUESTED_TARGET="$1"
shift
if [[ $# -gt 0 ]]; then
  invalid "unexpected arguments: $*"
fi

if ! command -v jq >/dev/null 2>&1; then
  invalid "jq is required"
fi

if ! command -v tmux >/dev/null 2>&1; then
  fail "tmux is required"
fi

INVENTORY_JSON="$(read_inventory_json)"
RESOLVED_JSON="$(resolve_target_json "${REQUESTED_TARGET}" "${INVENTORY_JSON}")"
TMUX_TARGET="$(jq -r '.tmux_target // empty' <<<"${RESOLVED_JSON}")"

if [[ -z "${TMUX_TARGET}" ]]; then
  fail "resolved target missing tmux target"
fi

if [[ -n "${TMUX:-}" ]]; then
  tmux switch-client -t "${TMUX_TARGET}" || fail "failed to switch tmux client to target: ${TMUX_TARGET}"
else
  tmux attach-session -t "${TMUX_TARGET}" || fail "failed to attach tmux client to target: ${TMUX_TARGET}"
fi
