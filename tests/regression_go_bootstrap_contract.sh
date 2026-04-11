#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
if [[ -z "${ORCA_BIN:-}" ]]; then
  if [[ -x "${ROOT}/orca" ]]; then
    ORCA_BIN="${ROOT}/orca"
  else
    ORCA_BIN="${ROOT}/orca-go"
  fi
fi
if [[ "${ORCA_BIN}" != /* ]]; then
  ORCA_BIN="$(cd "$(dirname "${ORCA_BIN}")" && pwd)/$(basename "${ORCA_BIN}")"
fi

if [[ ! -x "${ORCA_BIN}" ]]; then
  echo "orca binary not found or not executable: ${ORCA_BIN}" >&2
  echo "build it first: go build -o orca ./cmd/orca/" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
FAKE_BIN="${TMP_DIR}/fake-bin"
OUTPUT_DRY="${TMP_DIR}/bootstrap-dry.out"
OUTPUT_AUTH="${TMP_DIR}/bootstrap-auth.out"
HARNESS_DIR="${TMP_DIR}/harness"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${FAKE_BIN}" "${HARNESS_DIR}"

cat > "${FAKE_BIN}/br" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "config" && "${2:-}" == "get" && "${3:-}" == "id.prefix" ]]; then
  exit 1
fi
if [[ "${1:-}" == "config" && "${2:-}" == "set" && "${3:-}" == "id.prefix" ]]; then
  exit 0
fi
if [[ "${1:-}" == "doctor" ]]; then
  exit 0
fi
if [[ "${1:-}" == "--version" ]]; then
  echo "br-test"
  exit 0
fi
exit 0
EOF
chmod +x "${FAKE_BIN}/br"

cat > "${FAKE_BIN}/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
  echo "ok"
  exit 0
fi
if [[ "${1:-}" == "--version" ]]; then
  echo "codex-test"
  exit 0
fi
exit 0
EOF
chmod +x "${FAKE_BIN}/codex"

(
  cd "${ROOT}" &&
  PATH="${FAKE_BIN}:$(dirname "$(command -v git)"):/usr/bin:/bin" \
  "${ORCA_BIN}" bootstrap --yes --dry-run >"${OUTPUT_DRY}" 2>&1
)

grep -F "[bootstrap] dry-run mode enabled" "${OUTPUT_DRY}" >/dev/null
grep -F "[bootstrap] step 8/8: Check Codex availability/auth (fail-hard)" "${OUTPUT_DRY}" >/dev/null
grep -F "[bootstrap] bootstrap dry-run complete" "${OUTPUT_DRY}" >/dev/null

cat > "${FAKE_BIN}/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  echo "codex 0.0.0-test"
  exit 0
fi
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
  echo "Error: not authenticated" >&2
  exit 1
fi
if [[ "${1:-}" == "login" ]]; then
  exit 0
fi
exit 0
EOF
chmod +x "${FAKE_BIN}/codex"

(
  cd "${HARNESS_DIR}"
  git init -q
)

set +e
(
  cd "${HARNESS_DIR}" &&
  PATH="${FAKE_BIN}:$(dirname "$(command -v git)"):/usr/bin:/bin" \
  ORCA_HOME="${ROOT}" \
  "${ORCA_BIN}" bootstrap --yes --dry-run >"${OUTPUT_AUTH}" 2>&1
)
auth_rc=$?
set -e

if [[ "${auth_rc}" -eq 0 ]]; then
  echo "bootstrap should fail-hard when codex login status fails" >&2
  cat "${OUTPUT_AUTH}" >&2
  exit 1
fi

grep -F "[bootstrap] step 8/8: Check Codex availability/auth (fail-hard)" "${OUTPUT_AUTH}" >/dev/null
grep -F "Error: not authenticated" "${OUTPUT_AUTH}" >/dev/null
grep -F "[bootstrap] error: codex authentication is required before Orca can run. Remediation: 1) codex login 2) codex login status 3)" "${OUTPUT_AUTH}" >/dev/null

echo "go bootstrap contract regression passed"
