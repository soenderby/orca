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
  status [--quick|--full]
  plan [--slots N] [--output PATH]
  gc-run-branches [--apply] [--base REF]
  setup-worktrees [count]
  with-lock [--scope NAME] [--timeout SECONDS] -- <command> [args...]
  queue-write-main [options] -- <queue-command> [args...]
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
  plan)
    exec "${SCRIPT_DIR}/plan.sh" "$@"
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
