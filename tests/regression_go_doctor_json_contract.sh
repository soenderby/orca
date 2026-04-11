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

OUTPUT_JSON="${TMP_DIR}/doctor.json"
if (cd "${ROOT}" && "${ORCA_BIN}" doctor --json > "${OUTPUT_JSON}"); then
  doctor_exit=0
else
  doctor_exit=$?
fi

if [[ "${doctor_exit}" -ne 0 && "${doctor_exit}" -ne 1 ]]; then
  echo "unexpected doctor exit code in repo context: ${doctor_exit}" >&2
  exit 1
fi

jq -e '
  .schema_version == 1
  and (.ok | type == "boolean")
  and (.summary | type == "object")
  and (.checks | type == "array")
  and (.checks | length > 0)
  and ([.checks[].id] | index("platform.wsl_ubuntu") != null)
  and ([.checks[].id] | index("dep.git.present") != null)
  and ([.checks[].id] | index("dep.tmux.present") != null)
  and ([.checks[].id] | index("dep.jq.present") != null)
  and ([.checks[].id] | index("dep.flock.present") != null)
  and ([.checks[].id] | index("dep.br.present") != null)
  and ([.checks[].id] | index("dep.codex.present") != null)
  and ([.checks[].id] | index("repo.git_worktree") != null)
  and ([.checks[].id] | index("repo.origin_present") != null)
  and ([.checks[].id] | index("git.user_name_local") != null)
  and ([.checks[].id] | index("git.user_email_local") != null)
  and ([.checks[].id] | index("queue.workspace_dir") != null)
  and ([.checks[].id] | index("queue.br_doctor") != null)
  and ([.checks[].id] | index("queue.id_prefix") != null)
  and ([.checks[].id] | index("helper.with_lock_executable") != null)
  and ([.checks[].id] | index("helper.queue_read_main_executable") != null)
  and ([.checks[].id] | index("helper.queue_write_main_executable") != null)
  and ([.checks[].id] | index("helper.merge_main_executable") != null)
  and ([.checks[] | (.remediation.commands | type == "array")] | all)
' "${OUTPUT_JSON}" >/dev/null

NON_REPO_JSON="${TMP_DIR}/doctor-non-repo.json"
if (cd "${TMP_DIR}" && "${ORCA_BIN}" doctor --json > "${NON_REPO_JSON}"); then
  echo "doctor should fail outside a git worktree" >&2
  exit 1
else
  non_repo_exit=$?
fi

if [[ "${non_repo_exit}" -ne 1 ]]; then
  echo "doctor should exit 1 when hard-fail checks are present (got ${non_repo_exit})" >&2
  exit 1
fi

jq -e '
  .ok == false
  and .summary.hard_fail > 0
  and ([.checks[] | select(.id == "repo.git_worktree")][0].status == "fail")
  and ([.checks[] | select(.id == "repo.git_worktree")][0].hard_requirement == true)
  and ([.checks[] | select(.id == "repo.git_worktree")][0].remediation.summary | length > 0)
  and (([.checks[] | select(.id == "repo.git_worktree")][0].remediation.commands | index("cd /path/to/orca")) != null)
  and (([.checks[] | select(.id == "repo.git_worktree")][0].remediation.commands | map(test("orca\\.sh doctor")) | any))
' "${NON_REPO_JSON}" >/dev/null

echo "go doctor json contract regression passed"
