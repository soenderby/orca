#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCA_GO_BIN="${ORCA_GO_BIN:-${SCRIPT_DIR}/orca-go}"
if [[ -x "${ORCA_GO_BIN}" ]]; then
  exec "${ORCA_GO_BIN}" queue-mutate "$@"
fi

usage() {
  cat <<'USAGE'
Usage:
  queue-mutate.sh [common-options] <mutation> [args]

Mutations:
  claim <issue-id>
  comment <issue-id> (--file <path> | --stdin)
  close <issue-id> [--reason <text>]
  dep-add <issue-id> <depends-on-id> [--type <dep-type>]

Common options:
  --actor <name>               Required actor for helper and br audit fields
  --queue-write-helper <path>  queue-write-main helper path (default: ORCA_QUEUE_WRITE_MAIN_PATH or ./queue-write-main.sh)
  --repo <path>                Passed through to queue-write-main.sh
  --lock-helper <path>         Passed through to queue-write-main.sh
  --scope <name>               Passed through to queue-write-main.sh
  --timeout <seconds>          Passed through to queue-write-main.sh
  --no-json                    Disable --json on inner br command
USAGE
}

ACTOR=""
QUEUE_WRITE_HELPER_PATH="${ORCA_QUEUE_WRITE_MAIN_PATH:-${SCRIPT_DIR}/queue-write-main.sh}"
PRIMARY_REPO=""
LOCK_HELPER_PATH=""
LOCK_SCOPE=""
LOCK_TIMEOUT_SECONDS=""
INCLUDE_JSON=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --actor)
      if [[ $# -lt 2 ]]; then
        echo "[queue-mutate] --actor requires an argument" >&2
        exit 1
      fi
      ACTOR="$2"
      shift 2
      ;;
    --queue-write-helper)
      if [[ $# -lt 2 ]]; then
        echo "[queue-mutate] --queue-write-helper requires an argument" >&2
        exit 1
      fi
      QUEUE_WRITE_HELPER_PATH="$2"
      shift 2
      ;;
    --repo)
      if [[ $# -lt 2 ]]; then
        echo "[queue-mutate] --repo requires an argument" >&2
        exit 1
      fi
      PRIMARY_REPO="$2"
      shift 2
      ;;
    --lock-helper)
      if [[ $# -lt 2 ]]; then
        echo "[queue-mutate] --lock-helper requires an argument" >&2
        exit 1
      fi
      LOCK_HELPER_PATH="$2"
      shift 2
      ;;
    --scope)
      if [[ $# -lt 2 ]]; then
        echo "[queue-mutate] --scope requires an argument" >&2
        exit 1
      fi
      LOCK_SCOPE="$2"
      shift 2
      ;;
    --timeout|--lock-timeout)
      if [[ $# -lt 2 ]]; then
        echo "[queue-mutate] --timeout requires an argument" >&2
        exit 1
      fi
      LOCK_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --no-json)
      INCLUDE_JSON=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

if [[ -z "${ACTOR}" ]]; then
  echo "[queue-mutate] --actor is required" >&2
  exit 1
fi

if [[ ! -x "${QUEUE_WRITE_HELPER_PATH}" ]]; then
  echo "[queue-mutate] queue-write helper is not executable: ${QUEUE_WRITE_HELPER_PATH}" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  echo "[queue-mutate] mutation command is required" >&2
  usage >&2
  exit 1
fi

mutation="$1"
shift

queue_write_args=()
if [[ -n "${PRIMARY_REPO}" ]]; then
  queue_write_args+=(--repo "${PRIMARY_REPO}")
fi
if [[ -n "${LOCK_HELPER_PATH}" ]]; then
  queue_write_args+=(--lock-helper "${LOCK_HELPER_PATH}")
fi
if [[ -n "${LOCK_SCOPE}" ]]; then
  queue_write_args+=(--scope "${LOCK_SCOPE}")
fi
if [[ -n "${LOCK_TIMEOUT_SECONDS}" ]]; then
  queue_write_args+=(--timeout "${LOCK_TIMEOUT_SECONDS}")
fi

json_args=()
if [[ "${INCLUDE_JSON}" -eq 1 ]]; then
  json_args+=(--json)
fi

run_mutation() {
  local commit_message="$1"
  shift

  "${QUEUE_WRITE_HELPER_PATH}" \
    "${queue_write_args[@]}" \
    --actor "${ACTOR}" \
    --message "${commit_message}" \
    -- \
    "$@"
}

case "${mutation}" in
  claim)
    if [[ $# -ne 1 ]]; then
      echo "[queue-mutate] claim requires: claim <issue-id>" >&2
      exit 1
    fi
    issue_id="$1"
    run_mutation \
      "queue: claim ${issue_id} by ${ACTOR}" \
      br update "${issue_id}" --claim --actor "${ACTOR}" "${json_args[@]}"
    ;;
  comment)
    if [[ $# -lt 2 ]]; then
      echo "[queue-mutate] comment requires: comment <issue-id> (--file <path> | --stdin)" >&2
      exit 1
    fi

    issue_id="$1"
    shift
    comment_file=""
    read_stdin=0

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --file)
          if [[ $# -lt 2 ]]; then
            echo "[queue-mutate] --file requires an argument" >&2
            exit 1
          fi
          comment_file="$2"
          shift 2
          ;;
        --stdin)
          read_stdin=1
          shift
          ;;
        *)
          echo "[queue-mutate] unsupported comment option: $1" >&2
          exit 1
          ;;
      esac
    done

    if [[ -n "${comment_file}" && "${read_stdin}" -eq 1 ]]; then
      echo "[queue-mutate] choose exactly one of --file or --stdin" >&2
      exit 1
    fi

    temp_comment_file=""
    if [[ "${read_stdin}" -eq 1 ]]; then
      temp_comment_file="$(mktemp)"
      cat > "${temp_comment_file}"
      comment_file="${temp_comment_file}"
    fi

    if [[ -z "${comment_file}" ]]; then
      echo "[queue-mutate] comment payload is required via --file or --stdin" >&2
      exit 1
    fi

    if [[ ! -f "${comment_file}" ]]; then
      echo "[queue-mutate] comment file not found: ${comment_file}" >&2
      exit 1
    fi

    cleanup_comment_file() {
      if [[ -n "${temp_comment_file}" ]]; then
        rm -f "${temp_comment_file}"
      fi
    }
    trap cleanup_comment_file EXIT

    run_mutation \
      "queue: comment ${issue_id} by ${ACTOR}" \
      br comments add "${issue_id}" --file "${comment_file}" --author "${ACTOR}" --actor "${ACTOR}" "${json_args[@]}"

    trap - EXIT
    cleanup_comment_file
    ;;
  close)
    if [[ $# -lt 1 ]]; then
      echo "[queue-mutate] close requires: close <issue-id> [--reason <text>]" >&2
      exit 1
    fi

    issue_id="$1"
    shift
    close_reason=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --reason)
          if [[ $# -lt 2 ]]; then
            echo "[queue-mutate] --reason requires an argument" >&2
            exit 1
          fi
          close_reason="$2"
          shift 2
          ;;
        *)
          echo "[queue-mutate] unsupported close option: $1" >&2
          exit 1
          ;;
      esac
    done

    close_args=(br close "${issue_id}" --actor "${ACTOR}" "${json_args[@]}")
    if [[ -n "${close_reason}" ]]; then
      close_args+=(--reason "${close_reason}")
    fi

    run_mutation "queue: close ${issue_id} by ${ACTOR}" "${close_args[@]}"
    ;;
  dep-add)
    if [[ $# -lt 2 ]]; then
      echo "[queue-mutate] dep-add requires: dep-add <issue-id> <depends-on-id> [--type <dep-type>]" >&2
      exit 1
    fi

    issue_id="$1"
    depends_on="$2"
    shift 2
    dep_type="blocks"

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --type)
          if [[ $# -lt 2 ]]; then
            echo "[queue-mutate] --type requires an argument" >&2
            exit 1
          fi
          dep_type="$2"
          shift 2
          ;;
        *)
          echo "[queue-mutate] unsupported dep-add option: $1" >&2
          exit 1
          ;;
      esac
    done

    run_mutation \
      "queue: dep-add ${issue_id} -> ${depends_on} by ${ACTOR}" \
      br dep add "${issue_id}" "${depends_on}" --type "${dep_type}" --actor "${ACTOR}" "${json_args[@]}"
    ;;
  *)
    echo "[queue-mutate] unsupported mutation form: ${mutation}" >&2
    usage >&2
    exit 1
    ;;
esac
