#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
ORCA_BIN="${ORCA_BIN:-${ROOT}/orca-go}"

if [[ ! -x "${ORCA_BIN}" ]]; then
  echo "orca binary not found or not executable: ${ORCA_BIN}" >&2
  echo "build it first: go build -o orca-go ./cmd/orca/" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
TEST_ROOT="${TMP_DIR}/repo"
TEST_BIN="${TMP_DIR}/bin"
STATE_DIR="${TMP_DIR}/state"
STATE_TMUX_FILE="${STATE_DIR}/tmux_sessions"
SESSION_PREFIX="go-start-cap-regression-$$"
REMOTE_REPO="${TMP_DIR}/remote.git"
SEED_REPO="${TMP_DIR}/seed"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${TEST_BIN}" "${STATE_DIR}"
touch "${STATE_TMUX_FILE}"

git init --bare -q "${REMOTE_REPO}"

git init -q "${SEED_REPO}"
git -C "${SEED_REPO}" config user.email test@example.com
git -C "${SEED_REPO}" config user.name test
cat > "${SEED_REPO}/README.md" <<'EOF'
# seed
EOF
git -C "${SEED_REPO}" add README.md
git -C "${SEED_REPO}" commit -q -m init
git -C "${SEED_REPO}" branch -M main
git -C "${SEED_REPO}" remote add origin "${REMOTE_REPO}"
git -C "${SEED_REPO}" push -q -u origin main

git clone -q --branch main "${REMOTE_REPO}" "${TEST_ROOT}"

mkdir -p "${TEST_ROOT}/.beads"
cat > "${TEST_ROOT}/.beads/issues.jsonl" <<'JSONL'
{"id":"orca-exclusive","title":"exclusive","status":"open","dependencies":[],"labels":["px:exclusive"]}
{"id":"orca-normal-1","title":"n1","status":"open","dependencies":[],"labels":[]}
{"id":"orca-normal-2","title":"n2","status":"open","dependencies":[],"labels":[]}
JSONL

cat > "${TEST_ROOT}/ORCA_PROMPT.md" <<'EOF'
test prompt
EOF

cat > "${TEST_BIN}/br" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  --version)
    echo "br-test"
    exit 0
    ;;
  doctor)
    echo "ok"
    exit 0
    ;;
  sync)
    exit 0
    ;;
  ready)
    if [[ "${2:-}" == "--json" ]]; then
      cat <<'JSON'
[
  { "id": "orca-exclusive", "priority": 1, "created_at": "2026-03-01T00:00:01Z" },
  { "id": "orca-normal-1", "priority": 2, "created_at": "2026-03-01T00:00:02Z" },
  { "id": "orca-normal-2", "priority": 3, "created_at": "2026-03-01T00:00:03Z" }
]
JSON
      exit 0
    fi
    ;;
esac

echo "unexpected br invocation: $*" >&2
exit 1
EOF
chmod +x "${TEST_BIN}/br"

cat > "${TEST_BIN}/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_file="${ORCA_TEST_TMUX_FILE}"
touch "${state_file}"

case "${1:-}" in
  has-session)
    session=""
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t)
          session="${2:-}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    if grep -Fx -- "${session}" "${state_file}" >/dev/null 2>&1; then
      exit 0
    fi
    exit 1
    ;;
  new-session)
    session=""
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -s)
          session="${2:-}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    if [[ -n "${session}" ]]; then
      if ! grep -Fx -- "${session}" "${state_file}" >/dev/null 2>&1; then
        printf '%s\n' "${session}" >> "${state_file}"
      fi
    fi
    exit 0
    ;;
  ls)
    while IFS= read -r session; do
      [[ -z "${session}" ]] && continue
      echo "${session}: 1 windows (created Thu Mar 12 00:00:00 2026)"
    done < "${state_file}"
    exit 0
    ;;
esac

echo "unexpected tmux invocation: $*" >&2
exit 1
EOF
chmod +x "${TEST_BIN}/tmux"

cat > "${TEST_BIN}/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat
EOF
chmod +x "${TEST_BIN}/jq"

cat > "${TEST_BIN}/flock" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "${TEST_BIN}/flock"

output="$(
  ORCA_TEST_TMUX_FILE="${STATE_TMUX_FILE}" \
  PATH="${TEST_BIN}:${PATH}" \
  SESSION_PREFIX="${SESSION_PREFIX}" \
  AGENT_COMMAND="true" \
  ORCA_ASSIGNMENT_MODE="assigned" \
  ORCA_PRIMARY_REPO="${TEST_ROOT}" \
  ORCA_HOME="${ROOT}" \
  "${ORCA_BIN}" start 2 --runs 1 2>&1
)"

printf '%s\n' "${output}" | grep -F "[start] dependency sanity: artifact=" >/dev/null
printf '%s\n' "${output}" | grep -F "[start] assignment plan: artifact=" >/dev/null
printf '%s\n' "${output}" | grep -F "requested_slots=2 assigned=1 held=2" >/dev/null
printf '%s\n' "${output}" | grep -F "assignment held: issue=orca-normal-1 reason=exclusive-already-selected" >/dev/null
printf '%s\n' "${output}" | grep -F "assignment decision: issue=orca-exclusive action=assigned reason=scheduled" >/dev/null
printf '%s\n' "${output}" | grep -F "assigned fewer sessions than requested_slots=2; held_reason_counts=exclusive-already-selected=2" >/dev/null
printf '%s\n' "${output}" | grep -F "launch summary: requested=2 running=0 ready=3 launched=1" >/dev/null

launched_count="$(wc -l < "${STATE_TMUX_FILE}" | tr -d '[:space:]')"
if [[ "${launched_count}" -ne 1 ]]; then
  echo "expected exactly 1 launched session, got ${launched_count}" >&2
  exit 1
fi

set +e
continuous_output="$(
  ORCA_TEST_TMUX_FILE="${STATE_TMUX_FILE}" \
  PATH="${TEST_BIN}:${PATH}" \
  SESSION_PREFIX="${SESSION_PREFIX}" \
  AGENT_COMMAND="true" \
  ORCA_ASSIGNMENT_MODE="assigned" \
  ORCA_PRIMARY_REPO="${TEST_ROOT}" \
  ORCA_HOME="${ROOT}" \
  "${ORCA_BIN}" start 1 --continuous 2>&1
)"
continuous_rc=$?
set -e

if [[ "${continuous_rc}" -eq 0 ]]; then
  echo "expected assigned mode + --continuous to be rejected" >&2
  exit 1
fi
printf '%s\n' "${continuous_output}" | grep -F -- "--continuous is not supported when ORCA_ASSIGNMENT_MODE=assigned" >/dev/null

echo "go start assignment launch-cap regression passed"
