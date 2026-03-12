#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_PATH="${ORCA_BR_GUARD_POLICY_PATH:-${SCRIPT_DIR}/lib/br-command-policy.sh}"
GUARD_MODE="${ORCA_BR_GUARD_MODE:-enforce}"
ALLOW_UNSAFE_MUTATIONS="${ORCA_ALLOW_UNSAFE_BR_MUTATIONS:-0}"
HELPER_PATH="${ORCA_QUEUE_WRITE_MAIN_PATH:-queue-write-main.sh}"

if [[ ! -r "${POLICY_PATH}" ]]; then
  echo "[br-guard] policy file is not readable: ${POLICY_PATH}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${POLICY_PATH}"

resolve_real_br_binary() {
  local configured="${ORCA_BR_REAL_BIN:-}"
  local resolved=""

  if [[ -n "${configured}" ]]; then
    if [[ ! -x "${configured}" ]]; then
      echo "[br-guard] ORCA_BR_REAL_BIN is not executable: ${configured}" >&2
      exit 1
    fi
    printf '%s\n' "${configured}"
    return 0
  fi

  resolved="$(command -v br || true)"
  if [[ -z "${resolved}" ]]; then
    echo "[br-guard] unable to resolve underlying br binary" >&2
    exit 127
  fi

  if [[ "${resolved}" == "${BASH_SOURCE[0]}" ]]; then
    echo "[br-guard] recursion detected while resolving br binary; set ORCA_BR_REAL_BIN" >&2
    exit 127
  fi

  printf '%s\n' "${resolved}"
}

render_command() {
  local rendered="br"
  local part=""

  for part in "$@"; do
    rendered+=" $(printf '%q' "${part}")"
  done

  printf '%s\n' "${rendered}"
}

REAL_BR_BIN="$(resolve_real_br_binary)"

if [[ "${GUARD_MODE}" == "off" || "${ALLOW_UNSAFE_MUTATIONS}" == "1" ]]; then
  exec "${REAL_BR_BIN}" "$@"
fi

if [[ "${GUARD_MODE}" != "enforce" ]]; then
  echo "[br-guard] invalid ORCA_BR_GUARD_MODE: ${GUARD_MODE} (expected: enforce|off)" >&2
  exit 1
fi

classification="$(orca_br_classify_command "$@")"
if [[ "${classification}" == "mutation" ]]; then
  blocked_command="$(render_command "$@")"
  echo "[br-guard] blocked direct br mutation in run worktree context: ${blocked_command}" >&2
  echo "[br-guard] remediation: route queue mutations through ${HELPER_PATH} on ORCA_PRIMARY_REPO/main" >&2
  echo "[br-guard] escape hatch: set ORCA_ALLOW_UNSAFE_BR_MUTATIONS=1 (auditable; use only for recovery/debugging)" >&2
  exit 64
fi

exec "${REAL_BR_BIN}" "$@"

