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

if [[ ! -x "${ORCA_BIN_CANDIDATE}" ]]; then
  echo "[with-lock] error: orca binary not found: ${ORCA_BIN_CANDIDATE}" >&2
  echo "[with-lock] build it first: go build -o ${SCRIPT_DIR}/orca ./cmd/orca" >&2
  exit 1
fi

exec "${ORCA_BIN_CANDIDATE}" with-lock "$@"
