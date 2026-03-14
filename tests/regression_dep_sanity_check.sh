#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
ISSUES_JSONL="${TMP_DIR}/issues.jsonl"
REPORT_JSON="${TMP_DIR}/report.json"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

cat > "${ISSUES_JSONL}" <<'JSONL'
{"id":"orca-a","title":"a","status":"open","dependencies":[{"issue_id":"orca-a","depends_on_id":"orca-a","type":"blocks"}]}
{"id":"orca-b","title":"b","status":"open","dependencies":[{"issue_id":"orca-b","depends_on_id":"orca-c","type":"blocks"}]}
{"id":"orca-c","title":"c","status":"in_progress","dependencies":[{"issue_id":"orca-c","depends_on_id":"orca-b","type":"blocks"}]}
{"id":"orca-d","title":"d","status":"open","dependencies":[{"issue_id":"orca-d","depends_on_id":"orca-e","type":"parent-child"},{"issue_id":"orca-d","depends_on_id":"orca-e","type":"blocks"}]}
{"id":"orca-e","title":"e","status":"open","dependencies":[]}
{"id":"orca-f","title":"f","status":"closed","dependencies":[{"issue_id":"orca-f","depends_on_id":"orca-f","type":"blocks"}]}
JSONL

if "${ROOT}/dep-sanity.sh" --issues-jsonl "${ISSUES_JSONL}" --output "${REPORT_JSON}" --strict >/dev/null 2>&1; then
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
  and ([.hazards[] | select(.code == "self-dependency-active" and .details.issue_id == "orca-a")] | length == 1)
  and ([.hazards[] | select(.code == "mutual-blocks-active" and .details.issue_a == "orca-b" and .details.issue_b == "orca-c")] | length == 1)
  and ([.hazards[] | select(.code == "active-dependency-cycle" and (.details.cycle_nodes | index("orca-b") != null) and (.details.cycle_nodes | index("orca-c") != null))] | length == 1)
  and ([.hazards[] | select(.code == "mixed-parent-child-blocks" and .details.issue_a == "orca-d" and .details.issue_b == "orca-e")] | length == 1)
' "${REPORT_JSON}" >/dev/null

echo "dependency sanity regression passed"
