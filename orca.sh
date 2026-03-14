#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE_PREFIX="${ORCA_USAGE_PREFIX:-${SCRIPT_DIR}/orca.sh}"

usage() {
  cat <<USAGE
Usage:
  ${USAGE_PREFIX} <command> [args]

Commands:
  bootstrap [--yes] [--dry-run]
  doctor [--json]
  start [count] [--runs N|--continuous] [--drain|--watch] [--no-work-retries N] [--reasoning-level LEVEL]
  stop
  status [--quick|--full] [--json] [--session-id ID] [--session-prefix PREFIX]
  status --follow [--poll-interval SECONDS] [--max-events N] [--session-id ID] [--session-prefix PREFIX]
  monitor --follow [--poll-interval SECONDS] [--max-events N] [--session-id ID] [--session-prefix PREFIX]
  monitor add --id AGENT_ID --lifecycle LIFECYCLE --tmux-target TARGET [--cwd PATH]
  monitor remove --id AGENT_ID
  monitor list [--json]
  observe start --id AGENT_ID --lifecycle LIFECYCLE --tmux-target TARGET --cwd PATH -- <command...>
  wait [--timeout SECONDS] [--session-id ID] [--session-prefix PREFIX] [--json]
  plan [--slots N] [--output PATH]
  dep-sanity [--issues-jsonl PATH] [--output PATH] [--strict]
  gc-run-branches [--apply] [--base REF]
  setup-worktrees [count]
  with-lock [--scope NAME] [--timeout SECONDS] -- <command> [args...]
  queue-read-main [options] -- <queue-read-command> [args...]
  queue-write-main [options] -- <queue-command> [args...]
  queue-mutate [options] <mutation> [args...]
  merge-main [--source BRANCH] [options]
USAGE
}

subcommand="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "${subcommand}" in
  start)
    exec "${SCRIPT_DIR}/start.sh" "$@"
    ;;
  doctor)
    exec "${SCRIPT_DIR}/doctor.sh" "$@"
    ;;
  bootstrap)
    exec "${SCRIPT_DIR}/bootstrap.sh" "$@"
    ;;
  stop)
    exec "${SCRIPT_DIR}/stop.sh" "$@"
    ;;
  status)
    exec "${SCRIPT_DIR}/status.sh" "$@"
    ;;
  monitor)
    exec "${SCRIPT_DIR}/monitor.sh" "$@"
    ;;
  observe)
    exec "${SCRIPT_DIR}/observe.sh" "$@"
    ;;
  wait)
    exec "${SCRIPT_DIR}/wait.sh" "$@"
    ;;
  plan)
    exec "${SCRIPT_DIR}/plan.sh" "$@"
    ;;
  dep-sanity)
    exec "${SCRIPT_DIR}/dep-sanity.sh" "$@"
    ;;
  gc-run-branches|gc)
    exec "${SCRIPT_DIR}/gc-run-branches.sh" "$@"
    ;;
  setup-worktrees|setup)
    exec "${SCRIPT_DIR}/setup-worktrees.sh" "$@"
    ;;
  with-lock|lock)
    exec "${SCRIPT_DIR}/with-lock.sh" "$@"
    ;;
  queue-write-main|queue-write)
    exec "${SCRIPT_DIR}/queue-write-main.sh" "$@"
    ;;
  queue-read-main|queue-read)
    exec "${SCRIPT_DIR}/queue-read-main.sh" "$@"
    ;;
  queue-mutate|queue)
    exec "${SCRIPT_DIR}/queue-mutate.sh" "$@"
    ;;
  merge-main|merge)
    exec "${SCRIPT_DIR}/merge-main.sh" "$@"
    ;;
  help|-h|--help|"")
    usage
    ;;
  *)
    echo "Unknown orca command: ${subcommand}" >&2
    usage >&2
    exit 1
    ;;
esac
