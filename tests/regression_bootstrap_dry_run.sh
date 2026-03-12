#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
OUTPUT="${TMP_DIR}/bootstrap.out"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

bash "${ROOT}/orca.sh" bootstrap --help >/dev/null

if ! (cd "${ROOT}" && bash ./bootstrap.sh --yes --dry-run >"${OUTPUT}" 2>&1); then
  echo "bootstrap dry-run should succeed in a configured repo" >&2
  cat "${OUTPUT}" >&2
  exit 1
fi

grep -F "[bootstrap] dry-run mode enabled" "${OUTPUT}" >/dev/null
grep -F "[bootstrap] step 8/8: Check Codex availability/auth (fail-hard)" "${OUTPUT}" >/dev/null
grep -F "[bootstrap] bootstrap dry-run complete" "${OUTPUT}" >/dev/null

echo "bootstrap dry-run regression passed"
