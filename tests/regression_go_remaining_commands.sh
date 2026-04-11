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

# --- queue-mutate passthrough helper contract ---
CAPTURE="${TMP_DIR}/queue-mutate-capture.txt"
FAKE_HELPER="${TMP_DIR}/fake-queue-write.sh"
cat > "${FAKE_HELPER}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
capture="${CAPTURE_PATH:?CAPTURE_PATH required}"
: > "${capture}"
for arg in "$@"; do
  printf '%s\n' "${arg}" >> "${capture}"
done
EOF
chmod +x "${FAKE_HELPER}"

printf 'line one\nline two\n' | CAPTURE_PATH="${CAPTURE}" \
  "${ORCA_BIN}" queue-mutate \
  --actor agent-1 \
  --queue-write-helper "${FAKE_HELPER}" \
  comment orca-123 --stdin >/dev/null

grep -F -- "--actor" "${CAPTURE}" >/dev/null
grep -F -- "agent-1" "${CAPTURE}" >/dev/null
grep -F -- "--message" "${CAPTURE}" >/dev/null
grep -F -- "queue: comment orca-123 by agent-1" "${CAPTURE}" >/dev/null
grep -F -- "comments" "${CAPTURE}" >/dev/null
grep -F -- "--file" "${CAPTURE}" >/dev/null
grep -F -- "--author" "${CAPTURE}" >/dev/null

assert_fails "queue-mutate lock-helper unsupported without explicit helper" \
  "${ORCA_BIN}" queue-mutate --actor agent-1 --lock-helper /tmp/fake claim orca-1

# --- stop command ---
TMUX_BIN_DIR="${TMP_DIR}/tmux-bin"
TMUX_STATE="${TMP_DIR}/tmux-sessions.txt"
mkdir -p "${TMUX_BIN_DIR}"
cat > "${TMUX_STATE}" <<'EOF'
orca-agent-1
orca-agent-2
other-1
EOF

cat > "${TMUX_BIN_DIR}/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_file="${ORCA_TEST_TMUX_STATE:?ORCA_TEST_TMUX_STATE required}"

case "${1:-}" in
  list-sessions|ls)
    while IFS= read -r session; do
      [[ -z "${session}" ]] && continue
      echo "${session}"
    done < "${state_file}"
    exit 0
    ;;
  kill-session)
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
    grep -Fxv -- "${session}" "${state_file}" > "${state_file}.tmp"
    mv "${state_file}.tmp" "${state_file}"
    exit 0
    ;;
esac

exit 1
EOF
chmod +x "${TMUX_BIN_DIR}/tmux"

stop_output="$(
  ORCA_TEST_TMUX_STATE="${TMUX_STATE}" \
  PATH="${TMUX_BIN_DIR}:$(dirname "$(command -v git)"):/usr/bin:/bin" \
  SESSION_PREFIX="orca-agent" \
  "${ORCA_BIN}" stop
)"

printf '%s\n' "${stop_output}" | grep -F "[stop] killing orca-agent-1" >/dev/null
printf '%s\n' "${stop_output}" | grep -F "[stop] killing orca-agent-2" >/dev/null
printf '%s\n' "${stop_output}" | grep -F "[stop] done" >/dev/null

grep -Fx "other-1" "${TMUX_STATE}" >/dev/null
if grep -E '^orca-agent-' "${TMUX_STATE}" >/dev/null; then
  echo "expected orca-agent sessions to be removed" >&2
  cat "${TMUX_STATE}" >&2
  exit 1
fi

# --- gc-run-branches command ---
REPO="${TMP_DIR}/gc-repo"
mkdir -p "${REPO}"
git -C "${REPO}" init -q
git -C "${REPO}" config user.email test@example.com
git -C "${REPO}" config user.name test
cat > "${REPO}/README.md" <<'EOF'
# gc test
EOF
git -C "${REPO}" add README.md
git -C "${REPO}" commit -q -m init
git -C "${REPO}" branch -M main

# merged/prunable branch
git -C "${REPO}" branch "swarm/agent-1-run-prunable"
# unmerged branch
git -C "${REPO}" checkout -q -b "swarm/agent-2-run-unmerged"
echo "unmerged" >> "${REPO}/README.md"
git -C "${REPO}" add README.md
git -C "${REPO}" commit -q -m unmerged
git -C "${REPO}" checkout -q main
# worktree-protected branch
git -C "${REPO}" branch "swarm/agent-3-run-worktree"
mkdir -p "${REPO}/worktrees"
git -C "${REPO}" worktree add -q "${REPO}/worktrees/agent-3" "swarm/agent-3-run-worktree"
# active tmux-protected branch
git -C "${REPO}" branch "swarm/agent-4-run-active"

GC_TMUX_STATE="${TMP_DIR}/gc-tmux-sessions.txt"
echo "orca-agent-4" > "${GC_TMUX_STATE}"
cat > "${TMUX_BIN_DIR}/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_file="${ORCA_TEST_TMUX_STATE:?ORCA_TEST_TMUX_STATE required}"

case "${1:-}" in
  ls)
    while IFS= read -r session; do
      [[ -z "${session}" ]] && continue
      echo "${session}"
    done < "${state_file}"
    exit 0
    ;;
  show-environment)
    # no ORCA_SESSION_ID exported in this harness
    exit 1
    ;;
esac

exit 1
EOF
chmod +x "${TMUX_BIN_DIR}/tmux"

gc_output="$(
  ORCA_TEST_TMUX_STATE="${GC_TMUX_STATE}" \
  PATH="${TMUX_BIN_DIR}:$(dirname "$(command -v git)"):/usr/bin:/bin" \
  SESSION_PREFIX="orca-agent" \
  "${ORCA_BIN}" gc-run-branches --repo "${REPO}" --base main
)"

printf '%s\n' "${gc_output}" | grep -F "[gc-run-branches] scanned: 4" >/dev/null
printf '%s\n' "${gc_output}" | grep -F "[gc-run-branches] prunable: 1" >/dev/null
printf '%s\n' "${gc_output}" | grep -F "[gc-run-branches] protected: 2" >/dev/null
printf '%s\n' "${gc_output}" | grep -F "[gc-run-branches] unmerged: 1" >/dev/null
printf '%s\n' "${gc_output}" | grep -F "swarm/agent-1-run-prunable" >/dev/null

# apply mode deletes only prunable branch
(
  ORCA_TEST_TMUX_STATE="${GC_TMUX_STATE}" \
  PATH="${TMUX_BIN_DIR}:$(dirname "$(command -v git)"):/usr/bin:/bin" \
  SESSION_PREFIX="orca-agent" \
  "${ORCA_BIN}" gc-run-branches --apply --repo "${REPO}" --base main >/dev/null
)

if git -C "${REPO}" show-ref --verify --quiet "refs/heads/swarm/agent-1-run-prunable"; then
  echo "expected prunable branch to be deleted" >&2
  exit 1
fi

git -C "${REPO}" show-ref --verify --quiet "refs/heads/swarm/agent-2-run-unmerged"
git -C "${REPO}" show-ref --verify --quiet "refs/heads/swarm/agent-3-run-worktree"
git -C "${REPO}" show-ref --verify --quiet "refs/heads/swarm/agent-4-run-active"

echo "go remaining commands regression passed"
