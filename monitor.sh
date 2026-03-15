#!/usr/bin/env bash
set -euo pipefail

EXIT_INVALID=4

usage() {
  cat <<'USAGE'
Usage:
  ./orca.sh follow [--poll-interval SECONDS] [--max-events N]
  ./orca.sh observe add --id AGENT_ID --lifecycle LIFECYCLE --tmux-target TARGET [--cwd PATH]
  ./orca.sh observe remove --id AGENT_ID
  ./orca.sh observe list [--json]
  ./orca.sh observe start --id AGENT_ID --lifecycle LIFECYCLE --tmux-target TARGET --cwd PATH -- <command...>

Notes:
  `monitor` has been removed.
  - Use `orca follow` for merged managed+observed live events.
  - Use `orca observe {add|remove|list|start}` for observed target lifecycle.
USAGE
}

invalid() {
  echo "monitor: $*" >&2
  exit "${EXIT_INVALID}"
}

subcommand="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "${subcommand}" in
  -h|--help|"")
    usage
    ;;
  --follow|follow)
    invalid "monitor --follow has been removed; use orca follow"
    ;;
  add|remove|list|start)
    invalid "monitor ${subcommand} has moved; use orca observe ${subcommand}"
    ;;
  *)
    invalid "unknown monitor command: ${subcommand}"
    ;;
esac
