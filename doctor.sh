#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE_PREFIX="${ORCA_USAGE_PREFIX:-${SCRIPT_DIR}/orca.sh}"
JSON_MODE=0

usage() {
  cat <<USAGE
Usage:
  ${USAGE_PREFIX} doctor [--json]

Options:
  --json    Emit machine-readable JSON output.
  -h, --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[doctor] unexpected argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

declare -a CHECK_IDS=()
declare -a CHECK_TITLES=()
declare -a CHECK_STATUS=()
declare -a CHECK_SEVERITY=()
declare -a CHECK_HARD=()
declare -a CHECK_CATEGORY=()
declare -a CHECK_MESSAGE=()
declare -a CHECK_REMEDIATION_SUMMARY=()
declare -a CHECK_REMEDIATION_COMMANDS=()

pass_count=0
fail_count=0
warning_count=0
hard_fail_count=0

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

add_check() {
  local id="$1"
  local title="$2"
  local status="$3"
  local severity="$4"
  local hard="$5"
  local category="$6"
  local message="$7"
  local remediation_summary="$8"
  local remediation_commands="${9:-}"
  local normalized_commands="${remediation_commands//\\n/$'\n'}"

  CHECK_IDS+=("${id}")
  CHECK_TITLES+=("${title}")
  CHECK_STATUS+=("${status}")
  CHECK_SEVERITY+=("${severity}")
  CHECK_HARD+=("${hard}")
  CHECK_CATEGORY+=("${category}")
  CHECK_MESSAGE+=("${message}")
  CHECK_REMEDIATION_SUMMARY+=("${remediation_summary}")
  CHECK_REMEDIATION_COMMANDS+=("${normalized_commands}")

  case "${status}" in
    pass)
      ((pass_count += 1))
      ;;
    fail)
      ((fail_count += 1))
      if [[ "${hard}" == "true" ]]; then
        ((hard_fail_count += 1))
      fi
      ;;
    warn)
      ((warning_count += 1))
      ;;
  esac
}

emit_commands_json() {
  local commands="$1"
  local first=1
  local line

  printf '['
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    if [[ ${first} -eq 0 ]]; then
      printf ','
    fi
    first=0
    printf '"%s"' "$(json_escape "${line}")"
  done <<< "${commands}"
  printf ']'
}

print_human() {
  local i
  local total="${#CHECK_IDS[@]}"
  local label

  echo "Orca Doctor"
  echo "==========="

  for ((i = 0; i < total; i++)); do
    case "${CHECK_STATUS[i]}" in
      pass) label="PASS" ;;
      fail) label="FAIL" ;;
      warn) label="WARN" ;;
      *) label="INFO" ;;
    esac

    printf '[%s] %s (%s)\n' "${label}" "${CHECK_IDS[i]}" "${CHECK_TITLES[i]}"
    printf '  %s\n' "${CHECK_MESSAGE[i]}"

    if [[ -n "${CHECK_REMEDIATION_SUMMARY[i]}" ]]; then
      printf '  Fix: %s\n' "${CHECK_REMEDIATION_SUMMARY[i]}"
    fi

    if [[ -n "${CHECK_REMEDIATION_COMMANDS[i]}" ]]; then
      while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        printf '  Run: %s\n' "${line}"
      done <<< "${CHECK_REMEDIATION_COMMANDS[i]}"
    fi
  done

  echo
  printf 'Summary: pass=%d fail=%d warn=%d hard_fail=%d\n' "${pass_count}" "${fail_count}" "${warning_count}" "${hard_fail_count}"
  if [[ "${hard_fail_count}" -eq 0 ]]; then
    echo "Result: ready"
  else
    echo "Result: not ready"
  fi
}

print_json() {
  local i
  local total="${#CHECK_IDS[@]}"
  local first=1
  local failed_first=1

  printf '{'
  printf '"schema_version":1,'
  if [[ "${hard_fail_count}" -eq 0 ]]; then
    printf '"ok":true,'
  else
    printf '"ok":false,'
  fi
  printf '"summary":{"pass":%d,"fail":%d,"warn":%d,"hard_fail":%d},' "${pass_count}" "${fail_count}" "${warning_count}" "${hard_fail_count}"

  printf '"failed_check_ids":['
  for ((i = 0; i < total; i++)); do
    if [[ "${CHECK_STATUS[i]}" != "fail" ]]; then
      continue
    fi
    if [[ ${failed_first} -eq 0 ]]; then
      printf ','
    fi
    failed_first=0
    printf '"%s"' "$(json_escape "${CHECK_IDS[i]}")"
  done
  printf '],'

  printf '"checks":['
  for ((i = 0; i < total; i++)); do
    if [[ ${first} -eq 0 ]]; then
      printf ','
    fi
    first=0

    printf '{'
    printf '"id":"%s",' "$(json_escape "${CHECK_IDS[i]}")"
    printf '"title":"%s",' "$(json_escape "${CHECK_TITLES[i]}")"
    printf '"category":"%s",' "$(json_escape "${CHECK_CATEGORY[i]}")"
    printf '"status":"%s",' "$(json_escape "${CHECK_STATUS[i]}")"
    printf '"severity":"%s",' "$(json_escape "${CHECK_SEVERITY[i]}")"
    printf '"hard_requirement":%s,' "${CHECK_HARD[i]}"
    printf '"message":"%s",' "$(json_escape "${CHECK_MESSAGE[i]}")"
    printf '"remediation":{"summary":"%s","commands":' "$(json_escape "${CHECK_REMEDIATION_SUMMARY[i]}")"
    emit_commands_json "${CHECK_REMEDIATION_COMMANDS[i]}"
    printf '}'
    printf '}'
  done
  printf ']'
  printf '}\n'
}

is_wsl=0
if [[ -n "${WSL_INTEROP:-}" ]]; then
  is_wsl=1
elif [[ -r /proc/sys/kernel/osrelease ]] && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease; then
  is_wsl=1
elif [[ -r /proc/version ]] && grep -qi microsoft /proc/version; then
  is_wsl=1
fi

os_id=""
os_like=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  os_id="${ID:-}"
  os_like="${ID_LIKE:-}"
fi

is_ubuntu=0
if [[ "${os_id}" == "ubuntu" || " ${os_like} " == *" ubuntu "* ]]; then
  is_ubuntu=1
fi

if [[ "${is_wsl}" -eq 1 && "${is_ubuntu}" -eq 1 ]]; then
  add_check "platform.wsl_ubuntu" "Platform is Ubuntu on WSL" "pass" "info" "false" "platform" \
    "Detected Ubuntu on WSL." \
    ""
elif [[ "${is_wsl}" -eq 1 ]]; then
  add_check "platform.wsl_ubuntu" "Platform is Ubuntu on WSL" "warn" "warn" "false" "platform" \
    "WSL detected but distro is not Ubuntu (ID=${os_id:-unknown})." \
    "Use Ubuntu on WSL for supported onboarding behavior." \
    "cat /etc/os-release\nwsl --list --verbose"
elif [[ "${is_ubuntu}" -eq 1 ]]; then
  add_check "platform.wsl_ubuntu" "Platform is Ubuntu on WSL" "warn" "warn" "false" "platform" \
    "Ubuntu detected, but WSL was not detected." \
    "Run Orca from Ubuntu on WSL to match the supported target platform." \
    "uname -a\ncat /proc/version"
else
  add_check "platform.wsl_ubuntu" "Platform is Ubuntu on WSL" "warn" "warn" "false" "platform" \
    "Unsupported platform for the default onboarding flow (expected Ubuntu on WSL)." \
    "Use Ubuntu on WSL for supported onboarding behavior." \
    "cat /etc/os-release\nuname -a"
fi

add_binary_check() {
  local cmd="$1"
  local check_id="$2"
  local remediation_summary="$3"
  local remediation_commands="$4"

  if command -v "${cmd}" >/dev/null 2>&1; then
    add_check "${check_id}" "Required binary present: ${cmd}" "pass" "info" "true" "dependency" \
      "Found ${cmd} at $(command -v "${cmd}")." \
      ""
  else
    add_check "${check_id}" "Required binary present: ${cmd}" "fail" "error" "true" "dependency" \
      "${cmd} is not available on PATH." \
      "${remediation_summary}" \
      "${remediation_commands}"
  fi
}

add_binary_check "git" "dep.git.present" "Install git and verify it is available." "sudo apt-get update\nsudo apt-get install -y git\ngit --version"
add_binary_check "tmux" "dep.tmux.present" "Install tmux and verify it is available." "sudo apt-get update\nsudo apt-get install -y tmux\ntmux -V"
add_binary_check "jq" "dep.jq.present" "Install jq and verify it is available." "sudo apt-get update\nsudo apt-get install -y jq\njq --version"
add_binary_check "flock" "dep.flock.present" "Install util-linux (provides flock) and verify it is available." "sudo apt-get update\nsudo apt-get install -y util-linux\nflock --version"
add_binary_check "br" "dep.br.present" "Install/configure br and ensure it is on PATH." "command -v br\nbr --version"
add_binary_check "codex" "dep.codex.present" "Install/configure codex CLI and ensure it is on PATH." "command -v codex\ncodex --version"

if command -v br >/dev/null 2>&1; then
  if br --version >/dev/null 2>&1; then
    add_check "dep.br.executable" "br executable sanity" "pass" "info" "true" "dependency" \
      "br --version succeeded." \
      ""
  else
    add_check "dep.br.executable" "br executable sanity" "fail" "error" "true" "dependency" \
      "br is present but not executable." \
      "Reinstall br or fix runtime dependencies until br --version succeeds." \
      "br --version"
  fi
else
  add_check "dep.br.executable" "br executable sanity" "fail" "error" "true" "dependency" \
    "Skipping executable check because br is missing." \
    "Install/configure br and ensure it is on PATH." \
    "command -v br\nbr --version"
fi

repo_root="${SCRIPT_DIR}"
in_git_worktree=0
if repo_root_detected="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  in_git_worktree=1
  repo_root="${repo_root_detected}"
  add_check "repo.git_worktree" "Repository context is a git worktree" "pass" "info" "true" "repo" \
    "Detected git worktree root: ${repo_root}." \
    ""
else
  add_check "repo.git_worktree" "Repository context is a git worktree" "fail" "error" "true" "repo" \
    "Current working directory is not inside a git worktree." \
    "Run doctor from inside the Orca repository checkout." \
    "cd /path/to/orca\n${SCRIPT_DIR}/orca.sh doctor"
fi

if [[ "${in_git_worktree}" -eq 1 ]]; then
  if origin_url="$(git remote get-url origin 2>/dev/null)"; then
    add_check "repo.origin_present" "origin remote is configured" "pass" "info" "true" "repo" \
      "origin points to ${origin_url}." \
      ""

    ls_remote_cmd=(git ls-remote --exit-code origin HEAD)
    if command -v timeout >/dev/null 2>&1; then
      ls_remote_cmd=(timeout 10 git ls-remote --exit-code origin HEAD)
    fi

    if GIT_TERMINAL_PROMPT=0 "${ls_remote_cmd[@]}" >/dev/null 2>&1; then
      add_check "repo.origin_reachable" "origin remote reachability" "pass" "info" "false" "repo" \
        "origin is reachable (HEAD resolved)." \
        ""
    else
      add_check "repo.origin_reachable" "origin remote reachability" "warn" "warn" "false" "repo" \
        "origin is configured but remote reachability/auth failed." \
        "Verify network access and authentication to origin before running long loops." \
        "git remote -v\nGIT_TERMINAL_PROMPT=1 git ls-remote --exit-code origin HEAD"
    fi
  else
    add_check "repo.origin_present" "origin remote is configured" "fail" "error" "true" "repo" \
      "No origin remote configured." \
      "Add origin so queue/merge helpers can sync and push." \
      "git remote add origin <repo-url>\ngit remote -v"
    add_check "repo.origin_reachable" "origin remote reachability" "warn" "warn" "false" "repo" \
      "Skipping reachability check because origin is missing." \
      "Configure origin first." \
      "git remote add origin <repo-url>"
  fi

  local_user_name="$(git config --local --get user.name 2>/dev/null || true)"
  if [[ -n "${local_user_name}" ]]; then
    add_check "git.user_name_local" "Local git user.name configured" "pass" "info" "true" "git" \
      "Local user.name is set." \
      ""
  else
    add_check "git.user_name_local" "Local git user.name configured" "fail" "error" "true" "git" \
      "Local git user.name is not configured." \
      "Set a local identity in this repository." \
      "git config --local user.name \"Your Name\""
  fi

  local_user_email="$(git config --local --get user.email 2>/dev/null || true)"
  if [[ -n "${local_user_email}" ]]; then
    add_check "git.user_email_local" "Local git user.email configured" "pass" "info" "true" "git" \
      "Local user.email is set." \
      ""
  else
    add_check "git.user_email_local" "Local git user.email configured" "fail" "error" "true" "git" \
      "Local git user.email is not configured." \
      "Set a local identity in this repository." \
      "git config --local user.email \"you@example.com\""
  fi
else
  add_check "repo.origin_present" "origin remote is configured" "fail" "error" "true" "repo" \
    "Skipping origin check because repository context is invalid." \
    "Run doctor from inside the Orca repository checkout." \
    "cd /path/to/orca"
  add_check "repo.origin_reachable" "origin remote reachability" "warn" "warn" "false" "repo" \
    "Skipping remote reachability check because repository context is invalid." \
    "Run doctor from inside the Orca repository checkout." \
    "cd /path/to/orca"
  add_check "git.user_name_local" "Local git user.name configured" "fail" "error" "true" "git" \
    "Skipping local identity check because repository context is invalid." \
    "Run doctor from inside the Orca repository checkout." \
    "cd /path/to/orca"
  add_check "git.user_email_local" "Local git user.email configured" "fail" "error" "true" "git" \
    "Skipping local identity check because repository context is invalid." \
    "Run doctor from inside the Orca repository checkout." \
    "cd /path/to/orca"
fi

if [[ -d "${repo_root}/.beads" ]]; then
  add_check "queue.workspace_dir" "Queue workspace directory exists" "pass" "info" "true" "queue" \
    "Found ${repo_root}/.beads." \
    ""
else
  add_check "queue.workspace_dir" "Queue workspace directory exists" "fail" "error" "true" "queue" \
    "Missing ${repo_root}/.beads queue workspace directory." \
    "Initialize queue workspace for this repository." \
    "cd ${repo_root}\nbr init"
fi

if command -v br >/dev/null 2>&1; then
  if br_doctor_output="$(cd "${repo_root}" && br doctor 2>&1)"; then
    add_check "queue.br_doctor" "Queue workspace health (br doctor)" "pass" "info" "true" "queue" \
      "br doctor succeeded." \
      ""
  else
    add_check "queue.br_doctor" "Queue workspace health (br doctor)" "fail" "error" "true" "queue" \
      "br doctor failed: ${br_doctor_output}" \
      "Repair the queue workspace and re-run doctor." \
      "cd ${repo_root}\nbr doctor"
  fi
else
  add_check "queue.br_doctor" "Queue workspace health (br doctor)" "fail" "error" "true" "queue" \
    "Skipping br doctor because br is missing." \
    "Install/configure br and re-run doctor." \
    "command -v br\nbr --version"
fi

if command -v br >/dev/null 2>&1; then
  id_prefix="$(cd "${repo_root}" && br config get id.prefix 2>/dev/null || true)"
  if [[ -n "${id_prefix}" ]]; then
    add_check "queue.id_prefix" "Queue id prefix configured" "pass" "info" "true" "queue" \
      "Configured id.prefix=${id_prefix}." \
      ""
  else
    add_check "queue.id_prefix" "Queue id prefix configured" "fail" "error" "true" "queue" \
      "Queue id.prefix is missing." \
      "Set an id prefix for queue issue identifiers." \
      "cd ${repo_root}\nbr config set id.prefix orca"
  fi
else
  add_check "queue.id_prefix" "Queue id prefix configured" "fail" "error" "true" "queue" \
    "Skipping id prefix check because br is missing." \
    "Install/configure br and re-run doctor." \
    "command -v br\nbr --version"
fi

check_helper_script() {
  local path="$1"
  local id="$2"
  local title="$3"

  if [[ ! -e "${path}" ]]; then
    add_check "${id}" "${title}" "fail" "error" "true" "helper" \
      "Missing helper script: ${path}" \
      "Restore the helper script at the expected path." \
      "ls -l ${repo_root}"
    return
  fi

  if [[ -x "${path}" ]]; then
    add_check "${id}" "${title}" "pass" "info" "true" "helper" \
      "Helper is present and executable: ${path}" \
      ""
  else
    add_check "${id}" "${title}" "fail" "error" "true" "helper" \
      "Helper exists but is not executable: ${path}" \
      "Mark helper as executable." \
      "chmod +x ${path}"
  fi
}

check_helper_script "${repo_root}/with-lock.sh" "helper.with_lock_executable" "with-lock helper is executable"
check_helper_script "${repo_root}/queue-write-main.sh" "helper.queue_write_main_executable" "queue-write-main helper is executable"
check_helper_script "${repo_root}/merge-main.sh" "helper.merge_main_executable" "merge-main helper is executable"

if [[ "${JSON_MODE}" -eq 1 ]]; then
  print_json
else
  print_human
fi

if [[ "${hard_fail_count}" -eq 0 ]]; then
  exit 0
fi

exit 1
