#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
# shellcheck source=/dev/null
source "${ROOT}/lib/follow-render.sh"

managed_fixture='{"schema_version":"orca.monitor.v2","observed_at":"2026-03-14T12:00:00Z","event_type":"run_started","event_id":"run_started:managed-1:run-0001","session_id":"managed-1","mode":"managed","tmux_target":"orca-agent-1","run":{"run_id":"run-0001","state":"running","result":null,"issue_status":null,"summary_path":null}}'
observed_fixture='{"schema_version":"orca.monitor.v2","observed_at":"2026-03-14T12:00:10Z","event_type":"session_down","event_id":"session_down:observed-1","session_id":"observed-1","mode":"observed","lifecycle":"persistent","tmux_target":"obs","session":{"session_id":"observed-1","tmux_target":"obs","lifecycle":"persistent","active":false}}'

managed_expected='2026-03-14T12:00:00Z mode=managed event_type=run_started session_id=managed-1 run_id=run-0001 target=orca-agent-1'
observed_expected='2026-03-14T12:00:10Z mode=observed event_type=session_down session_id=observed-1 target=obs'

managed_actual="$(orca_follow_render_line "${managed_fixture}" structured)"
observed_actual="$(orca_follow_render_line "${observed_fixture}" structured)"

if [[ "${managed_actual}" != "${managed_expected}" ]]; then
  echo "managed structured render drifted" >&2
  echo "expected: ${managed_expected}" >&2
  echo "actual:   ${managed_actual}" >&2
  exit 1
fi

if [[ "${observed_actual}" != "${observed_expected}" ]]; then
  echo "observed structured render drifted" >&2
  echo "expected: ${observed_expected}" >&2
  echo "actual:   ${observed_actual}" >&2
  exit 1
fi

if [[ "$(orca_follow_render_line "${managed_fixture}" jsonl)" != "${managed_fixture}" ]]; then
  echo "jsonl render mode must be passthrough" >&2
  exit 1
fi

echo "follow structured renderer regression checks passed"
