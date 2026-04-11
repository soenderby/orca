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
TEST_BIN="${TMP_DIR}/bin"
STATE_FILE="${TMP_DIR}/tmux_sessions"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${TEST_BIN}"
touch "${STATE_FILE}"

assert_fails() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "expected failure: ${description}" >&2
    exit 1
  fi
}

make_repo() {
  local repo="$1"
  local remote_repo="${repo}-remote.git"
  local seed_repo="${repo}-seed"

  git init --bare -q "${remote_repo}"

  git init -q "${seed_repo}"
  git -C "${seed_repo}" config user.email test@example.com
  git -C "${seed_repo}" config user.name test
  cat > "${seed_repo}/README.md" <<'EOF'
# seed
EOF
  git -C "${seed_repo}" add README.md
  git -C "${seed_repo}" commit -q -m init
  git -C "${seed_repo}" branch -M main
  git -C "${seed_repo}" remote add origin "${remote_repo}"
  git -C "${seed_repo}" push -q -u origin main

  git clone -q --branch main "${remote_repo}" "${repo}"
  git -C "${repo}" config user.email test@example.com
  git -C "${repo}" config user.name test

  mkdir -p "${repo}/.beads"
  cat > "${repo}/ORCA_PROMPT.md" <<'EOF'
test prompt
EOF

  for helper in with-lock.sh queue-read-main.sh queue-write-main.sh merge-main.sh br-guard.sh; do
    cat > "${repo}/${helper}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
    chmod +x "${repo}/${helper}"
  done
}

cat > "${TEST_BIN}/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_file="${ORCA_TEST_TMUX_FILE:?ORCA_TEST_TMUX_FILE required}"
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

exit 1
EOF
chmod +x "${TEST_BIN}/tmux"

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
      if [[ -n "${ORCA_TEST_READY_JSON:-}" && -f "${ORCA_TEST_READY_JSON}" ]]; then
        cat "${ORCA_TEST_READY_JSON}"
      else
        echo "[]"
      fi
      exit 0
    fi
    ;;
esac

echo "unexpected br invocation: $*" >&2
exit 1
EOF
chmod +x "${TEST_BIN}/br"

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

# --- Case 1: dirty worktree blocks start ---
DIRTY_REPO="${TMP_DIR}/dirty-repo"
make_repo "${DIRTY_REPO}"
mkdir -p "${DIRTY_REPO}/worktrees"
git -C "${DIRTY_REPO}" worktree add -q -B swarm/agent-1 "${DIRTY_REPO}/worktrees/agent-1" main
echo "dirty" >> "${DIRTY_REPO}/worktrees/agent-1/README.md"

set +e
dirty_output="$(
  ORCA_TEST_TMUX_FILE="${STATE_FILE}" \
  PATH="${TEST_BIN}:$(dirname "$(command -v git)"):/usr/bin:/bin" \
  ORCA_HOME="${DIRTY_REPO}" \
  ORCA_PRIMARY_REPO="${DIRTY_REPO}" \
  AGENT_COMMAND="true" \
  ORCA_ASSIGNMENT_MODE="self-select" \
  "${ORCA_BIN}" start 1 --runs 1 2>&1
)"
dirty_rc=$?
set -e

if [[ "${dirty_rc}" -eq 0 ]]; then
  echo "expected dirty worktree to block launch" >&2
  exit 1
fi
printf '%s\n' "${dirty_output}" | grep -F "worktree is not clean and cannot safely create run branches" >/dev/null

# --- Case 2: dep-sanity modes enforce/warn/off ---
MODES_REPO="${TMP_DIR}/modes-repo"
make_repo "${MODES_REPO}"
cat > "${MODES_REPO}/.beads/issues.jsonl" <<'JSONL'
{"id":"orca-a","title":"a","status":"open","dependencies":[{"issue_id":"orca-a","depends_on_id":"orca-a","type":"blocks"}]}
JSONL
cat > "${TMP_DIR}/ready-empty.json" <<'JSON'
[]
JSON

set +e
enforce_output="$(
  ORCA_TEST_TMUX_FILE="${STATE_FILE}" \
  PATH="${TEST_BIN}:$(dirname "$(command -v git)"):/usr/bin:/bin" \
  ORCA_HOME="${MODES_REPO}" \
  ORCA_PRIMARY_REPO="${MODES_REPO}" \
  ORCA_TEST_READY_JSON="${TMP_DIR}/ready-empty.json" \
  AGENT_COMMAND="true" \
  ORCA_ASSIGNMENT_MODE="self-select" \
  ORCA_DEP_SANITY_MODE="enforce" \
  "${ORCA_BIN}" start 1 --runs 1 2>&1
)"
enforce_rc=$?
set -e
if [[ "${enforce_rc}" -eq 0 ]]; then
  echo "expected enforce mode to fail on hazards" >&2
  exit 1
fi
printf '%s\n' "${enforce_output}" | grep -F "refusing to launch: dependency graph hazards detected" >/dev/null

warn_output="$(
  ORCA_TEST_TMUX_FILE="${STATE_FILE}" \
  PATH="${TEST_BIN}:$(dirname "$(command -v git)"):/usr/bin:/bin" \
  ORCA_HOME="${MODES_REPO}" \
  ORCA_PRIMARY_REPO="${MODES_REPO}" \
  ORCA_TEST_READY_JSON="${TMP_DIR}/ready-empty.json" \
  AGENT_COMMAND="true" \
  ORCA_ASSIGNMENT_MODE="self-select" \
  ORCA_DEP_SANITY_MODE="warn" \
  "${ORCA_BIN}" start 1 --runs 1 2>&1
)"
printf '%s\n' "${warn_output}" | grep -F "[start] dependency sanity: artifact=" >/dev/null
printf '%s\n' "${warn_output}" | grep -F "hazards=1 mode=warn" >/dev/null

off_output="$(
  ORCA_TEST_TMUX_FILE="${STATE_FILE}" \
  PATH="${TEST_BIN}:$(dirname "$(command -v git)"):/usr/bin:/bin" \
  ORCA_HOME="${MODES_REPO}" \
  ORCA_PRIMARY_REPO="${MODES_REPO}" \
  ORCA_TEST_READY_JSON="${TMP_DIR}/ready-empty.json" \
  AGENT_COMMAND="true" \
  ORCA_ASSIGNMENT_MODE="self-select" \
  ORCA_DEP_SANITY_MODE="off" \
  "${ORCA_BIN}" start 1 --runs 1 2>&1
)"
printf '%s\n' "${off_output}" | grep -F "[start] dependency sanity check: skipped (mode=off)" >/dev/null

# --- Case 3: prerequisite failure includes missing jq ---
NO_JQ_BIN="${TMP_DIR}/bin-no-jq"
mkdir -p "${NO_JQ_BIN}"
cp "${TEST_BIN}/tmux" "${NO_JQ_BIN}/tmux"
cp "${TEST_BIN}/br" "${NO_JQ_BIN}/br"
cp "${TEST_BIN}/flock" "${NO_JQ_BIN}/flock"

ln -s "$(command -v git)" "${NO_JQ_BIN}/git"

set +e
prereq_output="$(
  ORCA_TEST_TMUX_FILE="${STATE_FILE}" \
  PATH="${NO_JQ_BIN}" \
  ORCA_HOME="${MODES_REPO}" \
  ORCA_PRIMARY_REPO="${MODES_REPO}" \
  AGENT_COMMAND="/bin/true" \
  ORCA_ASSIGNMENT_MODE="self-select" \
  ORCA_DEP_SANITY_MODE="off" \
  "${ORCA_BIN}" start 1 --runs 1 2>&1
)"
prereq_rc=$?
set -e
if [[ "${prereq_rc}" -eq 0 ]]; then
  echo "expected missing jq prerequisite failure" >&2
  exit 1
fi
printf '%s\n' "${prereq_output}" | grep -F "missing prerequisites" >/dev/null
printf '%s\n' "${prereq_output}" | grep -F "jq" >/dev/null

echo "go start validation and dep-sanity mode regression passed"
