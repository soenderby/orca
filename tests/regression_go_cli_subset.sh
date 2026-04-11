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

# --- planner parity ---
READY_JSON="${TMP_DIR}/ready.json"
ISSUES_JSONL="${TMP_DIR}/issues.jsonl"
PLAN_JSON="${TMP_DIR}/plan.json"

cat > "${READY_JSON}" <<'JSON'
[
  { "id": "orca-t", "priority": 1, "created_at": "2026-03-01T00:00:00Z" },
  { "id": "orca-e", "priority": 3, "created_at": "2026-03-01T00:00:05Z" },
  { "id": "orca-c", "priority": 1, "created_at": "2026-03-01T00:00:03Z" },
  { "id": "orca-a", "priority": 1, "created_at": "2026-03-01T00:00:01Z" },
  { "id": "orca-d", "priority": 2, "created_at": "2026-03-01T00:00:04Z" },
  { "id": "orca-f", "priority": 4, "created_at": "2026-03-01T00:00:06Z" },
  { "id": "orca-b", "priority": 1, "created_at": "2026-03-01T00:00:02Z" }
]
JSON

cat > "${ISSUES_JSONL}" <<'JSONL'
{"id":"orca-t","title":"tracker","status":"open","priority":1,"labels":["meta:tracker"]}
{"id":"orca-a","title":"a","status":"open","priority":1,"labels":[]}
{"id":"orca-b","title":"b","status":"open","priority":1,"labels":["ck:queue"]}
{"id":"orca-c","title":"c","status":"open","priority":1,"labels":["ck:queue"]}
{"id":"orca-d","title":"d","status":"open","priority":2,"labels":["px:exclusive"]}
{"id":"orca-e","title":"e","status":"open","priority":3,"labels":[]}
{"id":"orca-f","title":"f","status":"open","priority":4,"labels":[]}
JSONL

"${ORCA_BIN}" plan --slots 3 --ready-json "${READY_JSON}" --issues-jsonl "${ISSUES_JSONL}" > "${PLAN_JSON}"

jq -e '
  .planner_version == "v1"
  and .input.slots == 3
  and .input.ready_count == 7
  and (.assignments | map(.issue_id) == ["orca-a", "orca-b", "orca-e"])
  and (.held | map(select(.issue_id == "orca-t" and .reason_code == "tracker-issue")) | length == 1)
  and (.held | map(select(.issue_id == "orca-c" and .reason_code == "contention-key-conflict")) | length == 1)
  and (.held | map(select(.issue_id == "orca-c" and .conflict_key == "queue")) | length == 1)
  and (.held | map(select(.issue_id == "orca-d" and .reason_code == "exclusive-conflict")) | length == 1)
  and (.held | map(select(.issue_id == "orca-f" and .reason_code == "not-enough-slots")) | length == 1)
' "${PLAN_JSON}" >/dev/null

# --- dep-sanity parity ---
DEP_ISSUES="${TMP_DIR}/dep-issues.jsonl"
DEP_REPORT="${TMP_DIR}/dep-report.json"

cat > "${DEP_ISSUES}" <<'JSONL'
{"id":"orca-a","title":"a","status":"open","dependencies":[{"issue_id":"orca-a","depends_on_id":"orca-a","type":"blocks"}]}
{"id":"orca-b","title":"b","status":"open","dependencies":[{"issue_id":"orca-b","depends_on_id":"orca-c","type":"blocks"}]}
{"id":"orca-c","title":"c","status":"in_progress","dependencies":[{"issue_id":"orca-c","depends_on_id":"orca-b","type":"blocks"}]}
{"id":"orca-d","title":"d","status":"open","dependencies":[{"issue_id":"orca-d","depends_on_id":"orca-e","type":"parent-child"},{"issue_id":"orca-d","depends_on_id":"orca-e","type":"blocks"}]}
{"id":"orca-e","title":"e","status":"open","dependencies":[]}
{"id":"orca-f","title":"f","status":"closed","dependencies":[{"issue_id":"orca-f","depends_on_id":"orca-f","type":"blocks"}]}
JSONL

if "${ORCA_BIN}" dep-sanity --issues-jsonl "${DEP_ISSUES}" --output "${DEP_REPORT}" --strict >/dev/null 2>&1; then
  echo "expected dep-sanity --strict to fail when hazards are present" >&2
  exit 1
fi

jq -e '
  .checker_version == "v1"
  and .summary.hazard_count == 4
  and ([.hazards[].code] | index("self-dependency-active") != null)
  and ([.hazards[].code] | index("mutual-blocks-active") != null)
  and ([.hazards[].code] | index("active-dependency-cycle") != null)
  and ([.hazards[].code] | index("mixed-parent-child-blocks") != null)
' "${DEP_REPORT}" >/dev/null

# --- delegated queue guardrail subset ---
FAKE_REAL_BR="${TMP_DIR}/fake-real-br.sh"
FAKE_GIT="${TMP_DIR}/git"
FAKE_REPO="${TMP_DIR}/fake-repo"
REAL_BR_CAPTURE="${TMP_DIR}/real-br-calls.txt"

cat > "${FAKE_REAL_BR}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
capture="${ORCA_REAL_BR_CAPTURE:?ORCA_REAL_BR_CAPTURE required}"
printf '%s\n' "$*" >> "${capture}"
if [[ "${1:-}" == "update" || "${1:-}" == "sync" || "${1:-}" == "ready" ]]; then
  [[ "${1:-}" == "ready" ]] && echo "[]"
  exit 0
fi
exit 0
EOF
chmod +x "${FAKE_REAL_BR}"

cat > "${FAKE_GIT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo=""
if [[ "${1:-}" == "-C" ]]; then
  repo="${2:-}"
  shift 2
fi
if [[ -z "${repo}" ]]; then
  repo="${PWD}"
fi

case "${1:-}" in
  rev-parse)
    if [[ "${2:-}" == "--is-inside-work-tree" ]]; then
      [[ -d "${repo}" ]] || exit 1
      echo "true"
      exit 0
    fi
    if [[ "${2:-}" == "--git-common-dir" ]]; then
      echo "${repo}/.git"
      exit 0
    fi
    ;;
  branch)
    if [[ "${2:-}" == "--show-current" ]]; then
      echo "main"
      exit 0
    fi
    ;;
  diff)
    if [[ "${2:-}" == "--quiet" || ( "${2:-}" == "--cached" && "${3:-}" == "--quiet" ) ]]; then
      exit 0
    fi
    ;;
  fetch|checkout|pull|add|push|commit|show-ref)
    exit 0
    ;;
esac

if [[ "${1:-}" == "diff" && "${2:-}" == "--cached" && "${3:-}" == "--quiet" ]]; then
  exit 0
fi

exit 0
EOF
chmod +x "${FAKE_GIT}"

mkdir -p "${FAKE_REPO}/.beads" "${FAKE_REPO}/.git"

assert_fails "queue-write-main requires explicit actor" "${ORCA_BIN}" queue-write-main -- br update orca-123 --claim --actor agent-1 --json
assert_fails "queue-write-main requires inner br --actor" "${ORCA_BIN}" queue-write-main --actor agent-1 -- br update orca-123 --claim --json
assert_fails "queue-write-main rejects comments --message payload" "${ORCA_BIN}" queue-write-main --actor agent-1 -- br comments add orca-123 --actor agent-1 --message hello --json
assert_fails "queue-write-main fails fast on --lock-helper" "${ORCA_BIN}" queue-write-main --lock-helper /tmp/fake --actor agent-1 -- br update orca-123 --claim --actor agent-1 --json
assert_fails "queue-write-main fails fast on --message" "${ORCA_BIN}" queue-write-main --message "x" --actor agent-1 -- br update orca-123 --claim --actor agent-1 --json
assert_fails "queue-read-main rejects mutation commands" "${ORCA_BIN}" queue-read-main -- br update orca-123 --claim --json
assert_fails "queue-read-main fails fast on --lock-helper" "${ORCA_BIN}" queue-read-main --lock-helper /tmp/fake -- br ready --json
assert_fails "queue-read-main fails fast on --fallback" "${ORCA_BIN}" queue-read-main --fallback worktree -- br ready --json

PATH="${TMP_DIR}:${PATH}" \
ORCA_BR_REAL_BIN="${FAKE_REAL_BR}" \
ORCA_REAL_BR_CAPTURE="${REAL_BR_CAPTURE}" \
"${ORCA_BIN}" queue-write-main \
  --repo "${FAKE_REPO}" \
  --actor agent-1 \
  -- \
  br update orca-123 --claim --actor agent-1 --json >/dev/null

grep -F "sync --import-only" "${REAL_BR_CAPTURE}" >/dev/null
grep -F "update orca-123 --claim --actor agent-1 --json" "${REAL_BR_CAPTURE}" >/dev/null
grep -F "sync --flush-only" "${REAL_BR_CAPTURE}" >/dev/null

ORCA_BIN="${ORCA_BIN}" "${ROOT}/tests/regression_go_loop_cli_parity.sh"
ORCA_BIN="${ORCA_BIN}" "${ROOT}/tests/regression_go_start_assignment_launch_cap.sh"
ORCA_BIN="${ORCA_BIN}" "${ROOT}/tests/regression_go_start_validation_modes.sh"
ORCA_BIN="${ORCA_BIN}" "${ROOT}/tests/regression_go_status_json_contract.sh"
ORCA_BIN="${ORCA_BIN}" "${ROOT}/tests/regression_go_doctor_json_contract.sh"
ORCA_BIN="${ORCA_BIN}" "${ROOT}/tests/regression_go_bootstrap_contract.sh"
ORCA_BIN="${ORCA_BIN}" "${ROOT}/tests/regression_go_remaining_commands.sh"

echo "go-cli subset regression passed"
