#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_DIR="$(mktemp -d)"
READY_JSON="${TMP_DIR}/ready.json"
ISSUES_JSONL="${TMP_DIR}/issues.jsonl"
PLAN_ONE="${TMP_DIR}/plan-one.json"
PLAN_TWO="${TMP_DIR}/plan-two.json"
READY_EXCLUSIVE_JSON="${TMP_DIR}/ready-exclusive.json"
ISSUES_EXCLUSIVE_JSONL="${TMP_DIR}/issues-exclusive.jsonl"
PLAN_EXCLUSIVE="${TMP_DIR}/plan-exclusive.json"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

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

"${ROOT}/plan.sh" \
  --slots 3 \
  --ready-json "${READY_JSON}" \
  --issues-jsonl "${ISSUES_JSONL}" > "${PLAN_ONE}"

"${ROOT}/plan.sh" \
  --slots 3 \
  --ready-json "${READY_JSON}" \
  --issues-jsonl "${ISSUES_JSONL}" > "${PLAN_TWO}"

cmp -s "${PLAN_ONE}" "${PLAN_TWO}"

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
' "${PLAN_ONE}" >/dev/null

cat > "${READY_EXCLUSIVE_JSON}" <<'JSON'
[
  { "id": "orca-x", "priority": 1, "created_at": "2026-03-01T00:00:01Z" },
  { "id": "orca-y", "priority": 2, "created_at": "2026-03-01T00:00:02Z" },
  { "id": "orca-z", "priority": 3, "created_at": "2026-03-01T00:00:03Z" }
]
JSON

cat > "${ISSUES_EXCLUSIVE_JSONL}" <<'JSONL'
{"id":"orca-x","title":"x","status":"open","priority":1,"labels":["px:exclusive"]}
{"id":"orca-y","title":"y","status":"open","priority":2,"labels":[]}
{"id":"orca-z","title":"z","status":"open","priority":3,"labels":["ck:queue"]}
JSONL

"${ROOT}/plan.sh" \
  --slots 3 \
  --ready-json "${READY_EXCLUSIVE_JSON}" \
  --issues-jsonl "${ISSUES_EXCLUSIVE_JSONL}" > "${PLAN_EXCLUSIVE}"

jq -e '
  .planner_version == "v1"
  and .input.slots == 3
  and .input.ready_count == 3
  and (.assignments | map(.issue_id) == ["orca-x"])
  and (.held | map(select(.issue_id == "orca-y" and .reason_code == "exclusive-already-selected")) | length == 1)
  and (.held | map(select(.issue_id == "orca-z" and .reason_code == "exclusive-already-selected")) | length == 1)
' "${PLAN_EXCLUSIVE}" >/dev/null

echo "planner v1 regression passed"
