#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE_PREFIX="${ORCA_USAGE_PREFIX:-${SCRIPT_DIR}/orca.sh}"

YES=0
DRY_RUN=0
BR_INSTALL_URL="https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh"
BR_EXPECTED_DIR="${HOME}/.local/bin"
BR_EXPECTED_BIN="${BR_EXPECTED_DIR}/br"

usage() {
  cat <<USAGE
Usage:
  ${USAGE_PREFIX} bootstrap [--yes] [--dry-run]

Options:
  --yes       Non-interactive mode for package/install prompts.
  --dry-run   Print planned actions without mutating system or repository.
  -h, --help
USAGE
}

log() {
  printf '[bootstrap] %s\n' "$*"
}

warn() {
  printf '[bootstrap] warn: %s\n' "$*" >&2
}

die() {
  printf '[bootstrap] error: %s\n' "$*" >&2
  exit 1
}

run_cmd() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '[bootstrap] dry-run: '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

run_shell() {
  local command="$1"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '[bootstrap] dry-run: %s\n' "${command}"
    return 0
  fi
  bash -lc "${command}"
}

confirm_or_die() {
  local prompt="$1"
  if [[ "${YES}" -eq 1 ]]; then
    return 0
  fi
  local answer
  read -r -p "${prompt} [y/N]: " answer
  case "${answer}" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      die "aborted by user"
      ;;
  esac
}

ensure_sudo_prefix() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    SUDO_PREFIX="sudo"
    return 0
  fi

  if [[ "${EUID}" -eq 0 ]]; then
    SUDO_PREFIX=""
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    SUDO_PREFIX="sudo"
    return 0
  fi

  die "sudo is required for apt package installation. Re-run as root or install sudo."
}

step_detect_platform() {
  local is_wsl=0
  local os_id=""
  local os_like=""

  if [[ -n "${WSL_INTEROP:-}" ]]; then
    is_wsl=1
  elif [[ -r /proc/sys/kernel/osrelease ]] && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease; then
    is_wsl=1
  elif [[ -r /proc/version ]] && grep -qi microsoft /proc/version; then
    is_wsl=1
  fi

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    os_id="${ID:-}"
    os_like="${ID_LIKE:-}"
  fi

  if [[ "${os_id}" != "ubuntu" && " ${os_like} " != *" ubuntu "* ]]; then
    die "unsupported distro (ID=${os_id:-unknown}). Orca bootstrap currently supports Ubuntu (WSL preferred)."
  fi

  if [[ "${is_wsl}" -ne 1 ]]; then
    warn "WSL was not detected. Continuing on Ubuntu, but this path is optimized for Ubuntu on WSL."
  fi

  if [[ "${is_wsl}" -eq 1 ]]; then
    log "platform detected: Ubuntu on WSL"
  else
    log "platform detected: Ubuntu"
  fi
}

step_install_apt_dependencies() {
  local -a missing_packages=()
  command -v git >/dev/null 2>&1 || missing_packages+=(git)
  command -v tmux >/dev/null 2>&1 || missing_packages+=(tmux)
  command -v jq >/dev/null 2>&1 || missing_packages+=(jq)
  command -v flock >/dev/null 2>&1 || missing_packages+=(util-linux)
  command -v curl >/dev/null 2>&1 || missing_packages+=(curl)
  command -v python3 >/dev/null 2>&1 || missing_packages+=(python3)

  if [[ "${#missing_packages[@]}" -eq 0 ]]; then
    log "ubuntu package prerequisites already installed"
    return
  fi

  confirm_or_die "Install missing apt packages: ${missing_packages[*]}?"
  ensure_sudo_prefix

  if [[ -n "${SUDO_PREFIX}" ]]; then
    run_cmd ${SUDO_PREFIX} apt-get update
    run_cmd ${SUDO_PREFIX} apt-get install ${YES:+-y} "${missing_packages[@]}"
  else
    run_cmd apt-get update
    run_cmd apt-get install ${YES:+-y} "${missing_packages[@]}"
  fi
}

step_ensure_python_alias() {
  if command -v python >/dev/null 2>&1; then
    log "python command already available"
    return
  fi

  confirm_or_die "Install python-is-python3 to provide the python command?"
  ensure_sudo_prefix

  if [[ -n "${SUDO_PREFIX}" ]]; then
    run_cmd ${SUDO_PREFIX} apt-get install ${YES:+-y} python-is-python3
  else
    run_cmd apt-get install ${YES:+-y} python-is-python3
  fi

  if [[ "${DRY_RUN}" -eq 0 ]] && ! command -v python >/dev/null 2>&1; then
    die "python command is still unavailable after installing python-is-python3"
  fi
}

step_install_br() {
  mkdir -p "${BR_EXPECTED_DIR}"

  if [[ ! -x "${BR_EXPECTED_BIN}" ]]; then
    confirm_or_die "Install br into ${BR_EXPECTED_DIR} using the upstream installer?"
    run_shell "curl -fsSL \"${BR_INSTALL_URL}?$(date +%s)\" | bash -s -- --dest \"${BR_EXPECTED_DIR}\" --verify"
  else
    log "found br at expected destination: ${BR_EXPECTED_BIN}"
  fi

  case ":${PATH}:" in
    *":${BR_EXPECTED_DIR}:"*)
      ;;
    *)
      export PATH="${BR_EXPECTED_DIR}:${PATH}"
      ;;
  esac
  hash -r 2>/dev/null || true

  if [[ "${DRY_RUN}" -eq 0 ]] && [[ ! -x "${BR_EXPECTED_BIN}" ]]; then
    die "expected br binary missing at ${BR_EXPECTED_BIN}. Install may have failed (proxy/offline issue)."
  fi

  local active_br
  active_br="$(command -v br || true)"
  if [[ -z "${active_br}" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      warn "dry-run: unable to verify active br path"
      return
    fi
    die "br is not on PATH after installation. Add ${BR_EXPECTED_DIR} to PATH and restart your shell."
  fi

  if [[ "${active_br}" != "${BR_EXPECTED_BIN}" ]]; then
    die "br path mismatch: active=${active_br}, expected=${BR_EXPECTED_BIN}. Ensure ${BR_EXPECTED_DIR} precedes ~/.cargo/bin in PATH and restart shell."
  fi

  run_cmd br --version
}

step_init_queue_workspace() {
  if [[ -d "${REPO_ROOT}/.beads" ]]; then
    log "queue workspace already initialized"
    return
  fi

  run_shell "cd \"${REPO_ROOT}\" && br init"
}

step_ensure_queue_prefix() {
  local id_prefix
  id_prefix="$(cd "${REPO_ROOT}" && br config get id.prefix 2>/dev/null || true)"
  if [[ -n "${id_prefix}" ]]; then
    log "queue id.prefix already set to ${id_prefix}"
    return
  fi

  run_shell "cd \"${REPO_ROOT}\" && br config set id.prefix orca"
}

step_configure_git_identity() {
  local local_name local_email global_name global_email
  local_name="$(git -C "${REPO_ROOT}" config --local --get user.name 2>/dev/null || true)"
  local_email="$(git -C "${REPO_ROOT}" config --local --get user.email 2>/dev/null || true)"

  if [[ -n "${local_name}" && -n "${local_email}" ]]; then
    log "local git identity already configured"
    return
  fi

  global_name="$(git config --global --get user.name 2>/dev/null || true)"
  global_email="$(git config --global --get user.email 2>/dev/null || true)"

  if [[ "${YES}" -eq 1 ]]; then
    if [[ -z "${local_name}" && -n "${global_name}" ]]; then
      run_cmd git -C "${REPO_ROOT}" config --local user.name "${global_name}"
    fi
    if [[ -z "${local_email}" && -n "${global_email}" ]]; then
      run_cmd git -C "${REPO_ROOT}" config --local user.email "${global_email}"
    fi

    if [[ "${DRY_RUN}" -eq 0 ]]; then
      local_name="$(git -C "${REPO_ROOT}" config --local --get user.name 2>/dev/null || true)"
      local_email="$(git -C "${REPO_ROOT}" config --local --get user.email 2>/dev/null || true)"
      if [[ -z "${local_name}" || -z "${local_email}" ]]; then
        die "local git identity is missing. Set it with: git -C ${REPO_ROOT} config --local user.name \"Your Name\" && git -C ${REPO_ROOT} config --local user.email \"you@example.com\""
      fi
    fi

    return
  fi

  local prompt_name prompt_email
  prompt_name="${local_name:-${global_name:-}}"
  prompt_email="${local_email:-${global_email:-}}"

  if [[ -z "${local_name}" ]]; then
    read -r -p "Local git user.name [${prompt_name:-Your Name}]: " local_name
    local_name="${local_name:-${prompt_name:-}}"
  fi
  if [[ -z "${local_email}" ]]; then
    read -r -p "Local git user.email [${prompt_email:-you@example.com}]: " local_email
    local_email="${local_email:-${prompt_email:-}}"
  fi

  [[ -n "${local_name}" ]] || die "git user.name is required"
  [[ -n "${local_email}" ]] || die "git user.email is required"

  run_cmd git -C "${REPO_ROOT}" config --local user.name "${local_name}"
  run_cmd git -C "${REPO_ROOT}" config --local user.email "${local_email}"
}

step_check_codex_auth() {
  if ! command -v codex >/dev/null 2>&1; then
    die "codex CLI is not on PATH. Install/configure codex, then run: codex login && codex login status"
  fi

  local status_output
  if status_output="$(codex login status 2>&1)"; then
    log "codex auth check passed: ${status_output}"
    return
  fi

  printf '%s\n' "${status_output}" >&2
  die "codex authentication is required before Orca can run. Remediation: 1) codex login 2) codex login status 3) ${SCRIPT_DIR}/orca.sh bootstrap --yes"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      YES=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  die "run bootstrap from inside the Orca git repository"
fi

log "starting Orca bootstrap"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "dry-run mode enabled; no mutations will be applied"
fi

steps=(
  "Detect Ubuntu/WSL platform"
  "Install missing Ubuntu dependencies via apt"
  "Ensure python command availability"
  "Install/verify br via upstream installer"
  "Initialize queue workspace"
  "Ensure queue id prefix"
  "Configure local git identity"
  "Check Codex availability/auth (fail-hard)"
)

for i in "${!steps[@]}"; do
  idx=$((i + 1))
  log "step ${idx}/${#steps[@]}: ${steps[i]}"
  case "${idx}" in
    1) step_detect_platform ;;
    2) step_install_apt_dependencies ;;
    3) step_ensure_python_alias ;;
    4) step_install_br ;;
    5) step_init_queue_workspace ;;
    6) step_ensure_queue_prefix ;;
    7) step_configure_git_identity ;;
    8) step_check_codex_auth ;;
  esac
done

if [[ "${DRY_RUN}" -eq 0 ]]; then
  log "running final verification: ${SCRIPT_DIR}/doctor.sh"
  if "${SCRIPT_DIR}/doctor.sh"; then
    log "bootstrap complete: local prerequisites are ready"
  else
    die "bootstrap completed with remaining hard-fail checks. Resolve doctor failures and re-run."
  fi
else
  log "bootstrap dry-run complete"
fi
