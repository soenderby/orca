#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
FAKE_QUEUE_WRITE="${TMP_DIR}/fake-queue-write.sh"
CAPTURE="${TMP_DIR}/captured-args.txt"
FAKE_REAL_BR="${TMP_DIR}/fake-real-br.sh"
FAKE_LOCK="${TMP_DIR}/fake-lock.sh"
FAKE_GIT="${TMP_DIR}/git"
GUARD_BR="${TMP_DIR}/br"
FAKE_REPO="${TMP_DIR}/fake-repo"
REAL_BR_CAPTURE="${TMP_DIR}/real-br-calls.txt"
REAL_QUEUE_READ_CAPTURE="${TMP_DIR}/queue-read-calls.txt"
FAKE_QUEUE_READ="${TMP_DIR}/fake-queue-read.sh"

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

cat > "${FAKE_REAL_BR}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
capture="${ORCA_REAL_BR_CAPTURE:?ORCA_REAL_BR_CAPTURE required}"
printf '%s\n' "$*" >> "${capture}"
if [[ "${1:-}" == "update" ]]; then
  exit 0
fi
if [[ "${1:-}" == "sync" ]]; then
  exit 0
fi
if [[ "${1:-}" == "ready" ]]; then
  echo "[]"
  exit 0
fi
exit 0
EOF
chmod +x "${FAKE_REAL_BR}"

cat > "${FAKE_QUEUE_READ}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
capture="${ORCA_QUEUE_READ_CAPTURE:?ORCA_QUEUE_READ_CAPTURE required}"
printf '%s\n' "$*" >> "${capture}"
echo "[]"
EOF
chmod +x "${FAKE_QUEUE_READ}"

ln -s "${ROOT}/br-guard.sh" "${GUARD_BR}"

if ORCA_BR_REAL_BIN="${FAKE_REAL_BR}" ORCA_BR_GUARD_POLICY_PATH="${ROOT}/lib/br-command-policy.sh" ORCA_REAL_BR_CAPTURE="${REAL_BR_CAPTURE}" "${GUARD_BR}" update orca-123 --claim --actor agent-1 --json >/dev/null 2>&1; then
  echo "expected br guard to block direct update mutation" >&2
  exit 1
fi

ORCA_BR_REAL_BIN="${FAKE_REAL_BR}" ORCA_BR_GUARD_POLICY_PATH="${ROOT}/lib/br-command-policy.sh" ORCA_REAL_BR_CAPTURE="${REAL_BR_CAPTURE}" "${GUARD_BR}" ready --json >/dev/null
assert_contains "${REAL_BR_CAPTURE}" "ready --json"

: > "${REAL_BR_CAPTURE}"
: > "${REAL_QUEUE_READ_CAPTURE}"
ORCA_BR_REAL_BIN="${FAKE_REAL_BR}" \
ORCA_BR_GUARD_POLICY_PATH="${ROOT}/lib/br-command-policy.sh" \
ORCA_REAL_BR_CAPTURE="${REAL_BR_CAPTURE}" \
ORCA_QUEUE_READ_MAIN_PATH="${FAKE_QUEUE_READ}" \
ORCA_QUEUE_READ_CAPTURE="${REAL_QUEUE_READ_CAPTURE}" \
"${GUARD_BR}" ready --json >/dev/null
assert_contains "${REAL_QUEUE_READ_CAPTURE}" "br ready --json"
if [[ -s "${REAL_BR_CAPTURE}" ]]; then
  echo "expected br guard ready call to route via queue-read helper (real br should not be called directly)" >&2
  cat "${REAL_BR_CAPTURE}" >&2
  exit 1
fi

cat > "${FAKE_LOCK}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--" ]]; then
    shift
    break
  fi
  shift
done
"$@"
EOF
chmod +x "${FAKE_LOCK}"

cat > "${FAKE_GIT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-C" ]]; then
  repo="${2:-}"
  shift 2
  case "${1:-}" in
    rev-parse)
      if [[ "${2:-}" == "--is-inside-work-tree" ]]; then
        [[ -d "${repo}" ]] || exit 1
        echo "true"
        exit 0
      fi
      ;;
    branch)
      if [[ "${2:-}" == "--show-current" ]]; then
        if [[ -n "${ORCA_FAKE_GIT_BRANCH_OVERRIDE_REPO:-}" && "${repo}" == "${ORCA_FAKE_GIT_BRANCH_OVERRIDE_REPO}" ]]; then
          echo "${ORCA_FAKE_GIT_BRANCH_OVERRIDE_NAME:-feature/test}"
          exit 0
        fi
        echo "main"
        exit 0
      fi
      ;;
    diff)
      if [[ "${2:-}" == "--quiet" || ( "${2:-}" == "--cached" && "${3:-}" == "--quiet" ) ]]; then
        exit 0
      fi
      ;;
    fetch|checkout|pull|add)
      exit 0
      ;;
  esac
fi

if [[ "${1:-}" == "add" ]]; then
  exit 0
fi

if [[ "${1:-}" == "diff" && "${2:-}" == "--cached" && "${3:-}" == "--quiet" ]]; then
  exit 0
fi

exit 0
EOF
chmod +x "${FAKE_GIT}"

mkdir -p "${FAKE_REPO}/.beads"

assert_fails \
  "queue-read-main rejects mutation commands" \
  bash "${ROOT}/queue-read-main.sh" -- br update orca-123 --claim --json

PATH="${TMP_DIR}:${PATH}" \
ORCA_BR_REAL_BIN="${FAKE_REAL_BR}" \
ORCA_REAL_BR_CAPTURE="${REAL_BR_CAPTURE}" \
bash "${ROOT}/queue-write-main.sh" \
  --repo "${FAKE_REPO}" \
  --lock-helper "${FAKE_LOCK}" \
  --actor "agent-1" \
  -- \
  br update orca-123 --claim --actor agent-1 --json >/dev/null

assert_contains "${REAL_BR_CAPTURE}" "sync --import-only"
assert_contains "${REAL_BR_CAPTURE}" "update orca-123 --claim --actor agent-1 --json"
assert_contains "${REAL_BR_CAPTURE}" "sync --flush-only"

FALLBACK_WORKTREE="${TMP_DIR}/fallback-worktree"
mkdir -p "${FALLBACK_WORKTREE}"

: > "${REAL_BR_CAPTURE}"
queue_read_stderr="${TMP_DIR}/queue-read-fallback.stderr"
PATH="${TMP_DIR}:${PATH}" \
ORCA_BR_REAL_BIN="${FAKE_REAL_BR}" \
ORCA_REAL_BR_CAPTURE="${REAL_BR_CAPTURE}" \
ORCA_FAKE_GIT_BRANCH_OVERRIDE_REPO="${FAKE_REPO}" \
ORCA_FAKE_GIT_BRANCH_OVERRIDE_NAME="feature/not-main" \
bash "${ROOT}/queue-read-main.sh" \
  --repo "${FAKE_REPO}" \
  --lock-helper "${FAKE_LOCK}" \
  --fallback worktree \
  --worktree "${FALLBACK_WORKTREE}" \
  -- \
  br ready --json >/dev/null 2>"${queue_read_stderr}"

assert_contains "${queue_read_stderr}" "primary queue read failed"
assert_contains "${queue_read_stderr}" "queue_read_source=worktree fallback=worktree"
assert_contains "${REAL_BR_CAPTURE}" "ready --json"

echo "queue mutation guardrails regression passed"
