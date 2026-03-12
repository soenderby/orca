#!/usr/bin/env bash

# Classify br commands for run-time guardrails.
#
# Return values:
# - read_only: safe to run directly from agent worktree context
# - mutation: queue/workspace mutation path; route via queue helper
# - invalid: no command arguments supplied
orca_br_classify_command() {
  local -a args=("$@")
  local primary=""
  local secondary=""
  local token=""
  local has_sync_status=0
  local idx

  if [[ ${#args[@]} -eq 0 ]]; then
    printf '%s\n' "invalid"
    return 0
  fi

  primary="${args[0]}"
  if [[ ${#args[@]} -ge 2 ]]; then
    secondary="${args[1]}"
  fi

  case "${primary}" in
    -h|--help|help|--version|version)
      printf '%s\n' "read_only"
      return 0
      ;;
    ready|list|show|doctor)
      printf '%s\n' "read_only"
      return 0
      ;;
    dep)
      if [[ "${secondary}" == "list" ]]; then
        printf '%s\n' "read_only"
      else
        printf '%s\n' "mutation"
      fi
      return 0
      ;;
    comments)
      if [[ "${secondary}" == "list" ]]; then
        printf '%s\n' "read_only"
      else
        printf '%s\n' "mutation"
      fi
      return 0
      ;;
    config)
      if [[ "${secondary}" == "get" ]]; then
        printf '%s\n' "read_only"
      else
        printf '%s\n' "mutation"
      fi
      return 0
      ;;
    sync)
      for ((idx=1; idx<${#args[@]}; idx++)); do
        token="${args[$idx]}"
        if [[ "${token}" == "--status" ]]; then
          has_sync_status=1
          break
        fi
      done
      if [[ "${has_sync_status}" -eq 1 ]]; then
        printf '%s\n' "read_only"
      else
        printf '%s\n' "mutation"
      fi
      return 0
      ;;
    *)
      printf '%s\n' "mutation"
      return 0
      ;;
  esac
}

