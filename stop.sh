#!/usr/bin/env bash
set -euo pipefail

SESSION_PREFIX="${SESSION_PREFIX:-bb-agent}"
DOLT_CONTAINER_NAME="${DOLT_CONTAINER_NAME:-bookbinder-dolt}"

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

if command -v docker >/dev/null 2>&1; then
  dolt_running="$(docker inspect -f '{{.State.Running}}' "${DOLT_CONTAINER_NAME}" 2>/dev/null || true)"
  if [[ "${dolt_running}" == "true" ]]; then
    echo "[stop] stopping Dolt server container ${DOLT_CONTAINER_NAME}"
    docker stop "${DOLT_CONTAINER_NAME}" >/dev/null
  else
    echo "[stop] Dolt server container ${DOLT_CONTAINER_NAME} is not running"
  fi
else
  echo "[stop] docker not found; skipped Dolt server stop"
fi

echo "[stop] done"
