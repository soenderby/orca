#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
FAKE_QUEUE_WRITE="${TMP_DIR}/fake-queue-write.sh"
CAPTURE="${TMP_DIR}/captured-args.txt"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

assert_fails() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "expected failure: ${description}" >&2
    exit 1
  fi
}

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -F -- "${needle}" "${file}" >/dev/null; then
    echo "expected '${needle}' in ${file}" >&2
    cat "${file}" >&2 || true
    exit 1
  fi
}

assert_fails \
  "queue-write-main requires explicit actor" \
  bash "${ROOT}/queue-write-main.sh" -- br update orca-123 --claim --actor agent-1 --json

assert_fails \
  "queue-write-main requires inner br --actor" \
  bash "${ROOT}/queue-write-main.sh" --actor agent-1 -- br update orca-123 --claim --json

assert_fails \
  "queue-write-main rejects comments --message payload form" \
  bash "${ROOT}/queue-write-main.sh" --actor agent-1 -- br comments add orca-123 --actor agent-1 --message "hello" --json

cat > "${FAKE_QUEUE_WRITE}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
capture_path="${CAPTURE_PATH:?CAPTURE_PATH required}"
: > "${capture_path}"
for arg in "$@"; do
  printf '%s\n' "${arg}" >> "${capture_path}"
done
EOF
chmod +x "${FAKE_QUEUE_WRITE}"

printf 'line one\nline two\n' | CAPTURE_PATH="${CAPTURE}" \
  bash "${ROOT}/queue-mutate.sh" \
  --actor agent-1 \
  --queue-write-helper "${FAKE_QUEUE_WRITE}" \
  comment orca-123 --stdin >/dev/null

assert_contains "${CAPTURE}" "--actor"
assert_contains "${CAPTURE}" "agent-1"
assert_contains "${CAPTURE}" "--file"
assert_contains "${CAPTURE}" "--author"

echo "queue mutation guardrails regression passed"
