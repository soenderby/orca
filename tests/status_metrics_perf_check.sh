#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
WORKTREE_DIR="${TMP_DIR}/worktree"
ROW_COUNT="${ROW_COUNT:-25000}"

cleanup() {
  git -C "${ROOT}" worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

git -C "${ROOT}" worktree add --detach "${WORKTREE_DIR}" HEAD >/dev/null
mkdir -p "${WORKTREE_DIR}/agent-logs"

awk -v rows="${ROW_COUNT}" 'BEGIN {
  for (i = 1; i <= rows; i++) {
    minute = int((i % 3600) / 60)
    second = i % 60
    printf("{\"timestamp\":\"2026-03-11T07:%02d:%02dZ\",\"agent_name\":\"agent-%d\",\"result\":\"completed\",\"issue_id\":\"orca-%d\",\"durations_seconds\":{\"iteration_total\":%d},\"tokens_used\":%d}\n", minute, second, (i % 8), i, ((i % 300) + 1), (i * 3))
  }
}' > "${WORKTREE_DIR}/agent-logs/metrics.jsonl"

run_status_ms() {
  local start_ns="0"
  local end_ns="0"
  start_ns="$(date +%s%N)"
  (cd "${WORKTREE_DIR}" && PATH="/usr/bin:/bin" bash ./status.sh --full >/dev/null)
  end_ns="$(date +%s%N)"
  echo $(((end_ns - start_ns) / 1000000))
}

cold_ms="$(run_status_ms)"
warm_1_ms="$(run_status_ms)"
warm_2_ms="$(run_status_ms)"
warm_3_ms="$(run_status_ms)"

warm_median_ms="$(printf '%s\n' "${warm_1_ms}" "${warm_2_ms}" "${warm_3_ms}" | sort -n | sed -n '2p')"

full_output="$(cd "${WORKTREE_DIR}" && PATH="/usr/bin:/bin" bash ./status.sh --full)"

if ! printf '%s\n' "${full_output}" | grep -F "metrics rows: ${ROW_COUNT} (completed=${ROW_COUNT}, blocked=0, failed=0, no_work=0)" >/dev/null; then
  echo "status output missing expected metrics summary" >&2
  exit 1
fi

if (( warm_median_ms >= cold_ms )); then
  echo "expected warm-cache median to be faster than cold run: cold=${cold_ms}ms warm_median=${warm_median_ms}ms (warm runs: ${warm_1_ms},${warm_2_ms},${warm_3_ms})" >&2
  exit 1
fi

echo "status metrics perf check passed (cold=${cold_ms}ms warm_median=${warm_median_ms}ms rows=${ROW_COUNT})"
