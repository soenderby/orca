#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCA_BIN_CANDIDATE="${ORCA_BIN:-${ORCA_GO_BIN:-}}"
if [[ -z "${ORCA_BIN_CANDIDATE}" ]]; then
  if [[ -x "${SCRIPT_DIR}/orca" ]]; then
    ORCA_BIN_CANDIDATE="${SCRIPT_DIR}/orca"
  else
    ORCA_BIN_CANDIDATE="${SCRIPT_DIR}/orca-go"
  fi
fi
if [[ -x "${ORCA_BIN_CANDIDATE}" ]]; then
  exec "${ORCA_BIN_CANDIDATE}" stop "$@"
fi

SESSION_PREFIX="${SESSION_PREFIX:-orca-agent}"

sessions="$(tmux ls -F '#S' 2>/dev/null | grep "^${SESSION_PREFIX}-" || true)"

if [[ -z "${sessions}" ]]; then
  echo "[stop] no sessions with prefix ${SESSION_PREFIX}"
else
  while IFS= read -r s; do
    [[ -z "${s}" ]] && continue
    echo "[stop] killing ${s}"
    tmux kill-session -t "${s}"
  done <<< "${sessions}"
fi

echo "[stop] done"
