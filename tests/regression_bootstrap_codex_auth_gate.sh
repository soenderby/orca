#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
HARNESS_DIR="${TMP_DIR}/harness"
FAKE_BIN="${TMP_DIR}/fake-bin"
OUTPUT="${TMP_DIR}/bootstrap-auth-gate.out"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${HARNESS_DIR}" "${FAKE_BIN}"
cp "${ROOT}/bootstrap.sh" "${HARNESS_DIR}/bootstrap.sh"
cp "${ROOT}/orca.sh" "${HARNESS_DIR}/orca.sh"

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

echo "unexpected codex invocation: $*" >&2
exit 2
EOF
chmod +x "${FAKE_BIN}/codex"

(cd "${HARNESS_DIR}" && git init -q)

if (
  cd "${HARNESS_DIR}" && \
  PATH="${FAKE_BIN}:${PATH}" bash ./bootstrap.sh --yes --dry-run >"${OUTPUT}" 2>&1
); then
  echo "bootstrap should fail-hard when codex login status fails" >&2
  cat "${OUTPUT}" >&2
  exit 1
fi

grep -F "[bootstrap] step 8/8: Check Codex availability/auth (fail-hard)" "${OUTPUT}" >/dev/null
grep -F "Error: not authenticated" "${OUTPUT}" >/dev/null
grep -F "[bootstrap] error: codex authentication is required before Orca can run. Remediation: 1) codex login 2) codex login status 3)" "${OUTPUT}" >/dev/null

echo "bootstrap codex auth gate regression passed"
