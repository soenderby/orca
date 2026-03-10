#!/usr/bin/env bash
set -euo pipefail

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
