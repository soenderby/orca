#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
ORCA_BIN="${ORCA_BIN:-${ROOT}/orca-go}"

if [[ ! -x "${ORCA_BIN}" ]]; then
  echo "building go binary: ${ORCA_BIN}" >&2
  (cd "${ROOT}" && go build -o "${ORCA_BIN}" ./cmd/orca)
fi

scripts=(
  tests/regression_go_loop_cli_parity.sh
  tests/regression_go_start_assignment_launch_cap.sh
  tests/regression_go_start_validation_modes.sh
  tests/regression_go_status_json_contract.sh
  tests/regression_go_doctor_json_contract.sh
  tests/regression_go_bootstrap_contract.sh
  tests/regression_go_remaining_commands.sh
)

for s in "${scripts[@]}"; do
  echo "=== RUN ${s} ==="
  ORCA_BIN="${ORCA_BIN}" "${ROOT}/${s}"
  echo "=== PASS ${s} ==="
  echo
 done

echo "go full regression suite passed"
