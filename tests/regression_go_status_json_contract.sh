#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
ORCA_BIN="${ORCA_BIN:-${ROOT}/orca-go}"
if [[ "${ORCA_BIN}" != /* ]]; then
  ORCA_BIN="$(cd "$(dirname "${ORCA_BIN}")" && pwd)/$(basename "${ORCA_BIN}")"
fi

if [[ ! -x "${ORCA_BIN}" ]]; then
  echo "orca binary not found or not executable: ${ORCA_BIN}" >&2
  echo "build it first: go build -o orca-go ./cmd/orca/" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
REPO="${TMP_DIR}/repo"
BIN_DIR="${TMP_DIR}/bin"
TMUX_STATE="${TMP_DIR}/tmux_sessions"
OUTPUT_JSON="${TMP_DIR}/status.json"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${REPO}" "${BIN_DIR}" "${REPO}/.beads"

# minimal git repo context required by status
(
  cd "${REPO}"
  git init -q
  git config user.email test@example.com
  git config user.name test
  cat > README.md <<'EOF'
# status test repo
EOF
  git add README.md
  git commit -q -m init
)

mkdir -p "${REPO}/agent-logs/sessions/2026/04/07/orca-agent-1-20260407T120000Z/runs/0001-20260407T120001000000000Z"
cat > "${REPO}/agent-logs/sessions/2026/04/07/orca-agent-1-20260407T120000Z/runs/0001-20260407T120001000000000Z/summary.json" <<'JSON'
{"issue_id":"orca-123","result":"completed","issue_status":"closed","merged":true,"loop_action":"continue","loop_action_reason":"","notes":"ok"}
JSON

mkdir -p "${REPO}/agent-logs"
cat > "${REPO}/agent-logs/metrics.jsonl" <<'JSONL'
{"timestamp":"2026-04-07T12:00:00Z","agent_name":"agent-1","result":"completed","issue_id":"orca-123","durations_seconds":{"iteration_total":7},"tokens_used":42}
JSONL

echo "orca-agent-1" > "${TMUX_STATE}"

cat > "${BIN_DIR}/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_file="${ORCA_TEST_TMUX_STATE:?ORCA_TEST_TMUX_STATE required}"

case "${1:-}" in
  list-sessions)
    while IFS= read -r session; do
      [[ -z "${session}" ]] && continue
      echo "${session}"
    done < "${state_file}"
    exit 0
    ;;
esac

exit 1
EOF
chmod +x "${BIN_DIR}/tmux"

cat > "${BIN_DIR}/br" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --version)
    echo "br-test"
    exit 0
    ;;
  ready)
    if [[ "${2:-}" == "--json" ]]; then
      echo '[{"id":"orca-a"},{"id":"orca-b"}]'
      exit 0
    fi
    ;;
  list)
    if [[ "${2:-}" == "--status" && "${3:-}" == "in_progress" && "${4:-}" == "--json" ]]; then
      echo '[{"id":"orca-c"}]'
      exit 0
    fi
    ;;
esac

echo "unexpected br invocation: $*" >&2
exit 1
EOF
chmod +x "${BIN_DIR}/br"

(
  cd "${REPO}"
  ORCA_TEST_TMUX_STATE="${TMUX_STATE}" \
  PATH="${BIN_DIR}:$(dirname "$(command -v git)"):/usr/bin:/bin" \
  "${ORCA_BIN}" status --json > "${OUTPUT_JSON}"
)

jq -e '
  (.generated_at | type == "string")
  and .active_sessions == 1
  and .queue.ready == 2
  and .queue.in_progress == 1
  and .br.version == "br-test"
  and .br.workspace == true
  and (.sessions | length == 1)
  and .sessions[0].tmux_session == "orca-agent-1"
  and .sessions[0].state == "running"
  and .sessions[0].last_result == "completed"
  and .sessions[0].last_issue == "orca-123"
  and .latest.agent == "agent-1"
  and .latest.result == "completed"
  and .latest.issue == "orca-123"
  and .latest.duration == "7"
  and .latest.tokens == "42"
' "${OUTPUT_JSON}" >/dev/null

echo "go status json contract regression passed"
