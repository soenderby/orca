#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="${TMP_DIR}/repo"
TEST_BIN="${TMP_DIR}/bin"
HARNESS_DIR="${TMP_DIR}/harness"
SESSION_PREFIX="start-cap-regression-$$"
STATE_DIR="${TMP_DIR}/state"
STATE_TMUX_FILE="${STATE_DIR}/tmux_sessions"
REAL_GIT="$(command -v git)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${TEST_ROOT}/.beads" "${TEST_ROOT}/worktrees" "${TEST_BIN}" "${HARNESS_DIR}" "${STATE_DIR}"
touch "${STATE_TMUX_FILE}"
cat > "${TEST_ROOT}/.beads/issues.jsonl" <<'JSONL'
{"id":"orca-exclusive","title":"exclusive","status":"open","dependencies":[]}
{"id":"orca-normal-1","title":"n1","status":"open","dependencies":[]}
{"id":"orca-normal-2","title":"n2","status":"open","dependencies":[]}
JSONL
cat > "${TEST_ROOT}/ORCA_PROMPT.md" <<'EOF'
test prompt
EOF

for helper in with-lock.sh queue-write-main.sh merge-main.sh br-guard.sh; do
  cat > "${TEST_ROOT}/${helper}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${TEST_ROOT}/${helper}"
done

cat > "${TEST_ROOT}/queue-read-main.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--" ]]; then
    shift
    break
  fi
  shift
done

if [[ "${1:-}" == "br" && "${2:-}" == "ready" && "${3:-}" == "--json" ]]; then
  cat <<'JSON'
[
  { "id": "orca-exclusive", "priority": 1, "created_at": "2026-03-01T00:00:01Z" },
  { "id": "orca-normal-1", "priority": 2, "created_at": "2026-03-01T00:00:02Z" },
  { "id": "orca-normal-2", "priority": 3, "created_at": "2026-03-01T00:00:03Z" }
]
JSON
  exit 0
fi

echo "unexpected queue-read-main invocation: $*" >&2
exit 1
EOF
chmod +x "${TEST_ROOT}/queue-read-main.sh"

cat > "${TEST_BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--show-toplevel" ]]; then
  printf '%s\n' "${ORCA_TEST_ROOT}"
  exit 0
fi

if [[ "${1:-}" == "-C" ]]; then
  target="${2:-}"
  shift 2
  if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--is-inside-work-tree" ]]; then
    [[ -d "${target}" ]] || exit 1
    printf 'true\n'
    exit 0
  fi
  if [[ "${1:-}" == "status" && "${2:-}" == "--porcelain" ]]; then
    exit 0
  fi
fi

exec "${REAL_GIT}" "$@"
EOF
chmod +x "${TEST_BIN}/git"

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

cp "${ROOT}/start.sh" "${HARNESS_DIR}/start.sh"
chmod +x "${HARNESS_DIR}/start.sh"
cp "${ROOT}/dep-sanity.sh" "${HARNESS_DIR}/dep-sanity.sh"
chmod +x "${HARNESS_DIR}/dep-sanity.sh"

cat > "${HARNESS_DIR}/setup-worktrees.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

count="${1:-0}"
root="${ORCA_TEST_ROOT}"
mkdir -p "${root}/worktrees"
for i in $(seq 1 "${count}"); do
  mkdir -p "${root}/worktrees/agent-${i}"
done
EOF
chmod +x "${HARNESS_DIR}/setup-worktrees.sh"

cat > "${HARNESS_DIR}/plan.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

slots="0"
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slots)
      slots="${2:-0}"
      shift 2
      ;;
    --output)
      output="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$(dirname "${output}")"
cat > "${output}" <<'JSON'
{
  "planner_version": "v1",
  "input": { "slots": 2, "ready_count": 3 },
  "assignments": [
    { "slot": 1, "issue_id": "orca-exclusive", "priority": 1, "created_at": "2026-03-01T00:00:01Z", "labels": ["px:exclusive"] }
  ],
  "held": [
    { "issue_id": "orca-normal-1", "reason_code": "exclusive-already-selected" },
    { "issue_id": "orca-normal-2", "reason_code": "exclusive-already-selected" }
  ],
  "decisions": [
    { "issue_id": "orca-exclusive", "action": "assigned", "reason_code": "scheduled", "labels": ["px:exclusive"] },
    { "issue_id": "orca-normal-1", "action": "held", "reason_code": "exclusive-already-selected", "labels": [] },
    { "issue_id": "orca-normal-2", "action": "held", "reason_code": "exclusive-already-selected", "labels": [] }
  ]
}
JSON

jq -c '.' "${output}"
EOF
chmod +x "${HARNESS_DIR}/plan.sh"

output="$(
  ORCA_TEST_ROOT="${TEST_ROOT}" \
  ORCA_TEST_TMUX_FILE="${STATE_TMUX_FILE}" \
  REAL_GIT="${REAL_GIT}" \
  PATH="${TEST_BIN}:${PATH}" \
  SESSION_PREFIX="${SESSION_PREFIX}" \
  AGENT_COMMAND="true" \
  ORCA_ASSIGNMENT_MODE="assigned" \
  ORCA_PRIMARY_REPO="${TEST_ROOT}" \
  ORCA_WITH_LOCK_PATH="${TEST_ROOT}/with-lock.sh" \
  ORCA_QUEUE_READ_MAIN_PATH="${TEST_ROOT}/queue-read-main.sh" \
  ORCA_QUEUE_WRITE_MAIN_PATH="${TEST_ROOT}/queue-write-main.sh" \
  ORCA_MERGE_MAIN_PATH="${TEST_ROOT}/merge-main.sh" \
  ORCA_BR_GUARD_PATH="${TEST_ROOT}/br-guard.sh" \
  ORCA_DEP_SANITY_CHECK_PATH="${HARNESS_DIR}/dep-sanity.sh" \
  bash "${HARNESS_DIR}/start.sh" 2 --runs 1 2>&1
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
  ORCA_TEST_ROOT="${TEST_ROOT}" \
  ORCA_TEST_TMUX_FILE="${STATE_TMUX_FILE}" \
  REAL_GIT="${REAL_GIT}" \
  PATH="${TEST_BIN}:${PATH}" \
  SESSION_PREFIX="${SESSION_PREFIX}" \
  AGENT_COMMAND="true" \
  ORCA_ASSIGNMENT_MODE="assigned" \
  ORCA_PRIMARY_REPO="${TEST_ROOT}" \
  ORCA_WITH_LOCK_PATH="${TEST_ROOT}/with-lock.sh" \
  ORCA_QUEUE_READ_MAIN_PATH="${TEST_ROOT}/queue-read-main.sh" \
  ORCA_QUEUE_WRITE_MAIN_PATH="${TEST_ROOT}/queue-write-main.sh" \
  ORCA_MERGE_MAIN_PATH="${TEST_ROOT}/merge-main.sh" \
  ORCA_BR_GUARD_PATH="${TEST_ROOT}/br-guard.sh" \
  ORCA_DEP_SANITY_CHECK_PATH="${HARNESS_DIR}/dep-sanity.sh" \
  bash "${HARNESS_DIR}/start.sh" 1 --continuous 2>&1
)"
continuous_rc=$?
set -e

if [[ "${continuous_rc}" -eq 0 ]]; then
  echo "expected assigned mode + --continuous to be rejected" >&2
  exit 1
fi
printf '%s\n' "${continuous_output}" | grep -F -- "--continuous is not supported when ORCA_ASSIGNMENT_MODE=assigned" >/dev/null

echo "start assignment launch-cap regression passed"
