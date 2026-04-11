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
  start [count] [--runs N|--continuous(self-select only)] [--drain|--watch] [--no-work-retries N] [--reasoning-level LEVEL]
  stop
  status [--json]
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

ORCA_BIN_CANDIDATE="${ORCA_BIN:-${ORCA_GO_BIN:-}}"
if [[ -z "${ORCA_BIN_CANDIDATE}" ]]; then
  if [[ -x "${SCRIPT_DIR}/orca" ]]; then
    ORCA_BIN_CANDIDATE="${SCRIPT_DIR}/orca"
  else
    ORCA_BIN_CANDIDATE="${SCRIPT_DIR}/orca-go"
  fi
fi
if [[ -x "${ORCA_BIN_CANDIDATE}" ]]; then
  if [[ -z "${subcommand}" ]]; then
    exec "${ORCA_BIN_CANDIDATE}"
  fi
  case "${subcommand}" in
    bootstrap|doctor|start|stop|status|plan|dep-sanity|gc-run-branches|gc|setup-worktrees|setup|with-lock|lock|queue-read-main|queue-read|queue-write-main|queue-write|queue-mutate|queue|merge-main|merge|loop-run|version|help|-h|--help)
      exec "${ORCA_BIN_CANDIDATE}" "${subcommand}" "$@"
      ;;
  esac
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
