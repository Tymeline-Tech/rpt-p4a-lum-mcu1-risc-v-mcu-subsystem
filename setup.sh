#!/usr/bin/env bash
# LUM-MCU1 open-source EDA toolchain installer.
#
# Installs Verilator, Icarus Verilog, Yosys, and Python cocotb so that a
# subsequent Makefile can locate these binaries on PATH without path errors.
# Isolates setup from build logic for a reproducible development environment.
#
# Usage:
#   ./setup.sh              # install missing tools (requires sudo on Ubuntu)
#   ./setup.sh --check-only # report versions of already-installed tools
#
# Environment:
#   LUM_MCU1_VENV   Path for the project Python virtualenv (default: .venv)
#   DEBIAN_FRONTEND Preserved/forced to noninteractive during apt installs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

VENV_DIR="${LUM_MCU1_VENV:-${SCRIPT_DIR}/.venv}"
CHECK_ONLY=0

usage() {
  cat <<'EOF'
Usage: ./setup.sh [--check-only] [-h|--help]

  Install (or verify) the LUM-MCU1 open-source EDA stack:
    - Yosys
    - Verilator
    - Icarus Verilog (iverilog / vvp)
    - Python cocotb (inside a project virtualenv)

  --check-only   Skip installs; print version summary for tools already present.
  -h, --help     Show this help and exit.
EOF
}

log()  { printf 'setup.sh: %s\n' "$*"; }
err()  { printf 'setup.sh: error: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# OS detection — Linux/Ubuntu required
# ---------------------------------------------------------------------------
detect_os() {
  local uname_s
  uname_s="$(uname -s 2>/dev/null || true)"
  if [[ "${uname_s}" != "Linux" ]]; then
    die "unsupported OS '${uname_s}'; Linux/Ubuntu is required"
  fi

  if [[ ! -r /etc/os-release ]]; then
    die "/etc/os-release not found; cannot confirm Ubuntu"
  fi

  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    ubuntu) ;;
    debian)
      log "warning: detected Debian (${VERSION_ID:-unknown}); Ubuntu is the supported target"
      ;;
    *)
      die "unsupported distribution '${ID:-unknown}'; Ubuntu is required"
      ;;
  esac

  log "detected ${PRETTY_NAME:-${ID} ${VERSION_ID}}"
}

# ---------------------------------------------------------------------------
# Privilege helper
# ---------------------------------------------------------------------------
run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    env DEBIAN_FRONTEND=noninteractive "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive "$@"
  else
    die "root privileges required to install packages (sudo not available)"
  fi
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Apt package install (Yosys, Verilator, Icarus Verilog, Python build deps)
# ---------------------------------------------------------------------------
apt_install_eda() {
  local packages=(
    build-essential
    git
    python3
    python3-pip
    python3-venv
    python3-dev
    yosys
    verilator
    iverilog
  )
  local missing=()
  local pkg

  for pkg in "${packages[@]}"; do
    if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
      missing+=("${pkg}")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log "apt packages already installed: ${packages[*]}"
    return 0
  fi

  log "installing apt packages: ${missing[*]}"
  run_root apt-get update -y
  run_root apt-get install -y --no-install-recommends "${missing[@]}"
}

# ---------------------------------------------------------------------------
# Python virtualenv + cocotb
# ---------------------------------------------------------------------------
ensure_venv_and_cocotb() {
  if ! have_cmd python3; then
    die "python3 is required but was not found after package install"
  fi

  if [[ ! -d "${VENV_DIR}" ]]; then
    log "creating Python virtualenv at ${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
  else
    log "reusing Python virtualenv at ${VENV_DIR}"
  fi

  # shellcheck disable=SC1091
  . "${VENV_DIR}/bin/activate"

  log "upgrading pip inside virtualenv"
  python -m pip install --upgrade pip setuptools wheel

  if python -c "import cocotb" >/dev/null 2>&1; then
    log "cocotb already present in virtualenv"
  else
    log "installing cocotb into virtualenv"
    python -m pip install cocotb
  fi
}

# ---------------------------------------------------------------------------
# Version reporting helpers
# ---------------------------------------------------------------------------
tool_version_line() {
  local name="$1"
  local cmd="$2"
  shift 2
  if have_cmd "${cmd}"; then
    # Capture first meaningful version line; tolerate tools that write to stderr.
    local out
    out="$("${cmd}" "$@" 2>&1 | head -n 1 | tr -d '\r')"
    printf '  %-14s %s\n' "${name}:" "${out}"
  else
    printf '  %-14s %s\n' "${name}:" "NOT FOUND"
  fi
}

cocotb_version_line() {
  local py="${VENV_DIR}/bin/python"
  if [[ -x "${py}" ]] && "${py}" -c "import cocotb" >/dev/null 2>&1; then
    local ver
    ver="$("${py}" -c "import cocotb; print(cocotb.__version__)" 2>/dev/null || echo "unknown")"
    printf '  %-14s %s\n' "cocotb:" "${ver} (venv: ${VENV_DIR})"
  elif python3 -c "import cocotb" >/dev/null 2>&1; then
    local ver
    ver="$(python3 -c "import cocotb; print(cocotb.__version__)" 2>/dev/null || echo "unknown")"
    printf '  %-14s %s\n' "cocotb:" "${ver} (system python3)"
  else
    printf '  %-14s %s\n' "cocotb:" "NOT FOUND"
  fi
}

print_version_summary() {
  echo
  echo "========================================"
  echo " LUM-MCU1 toolchain version summary"
  echo "========================================"
  tool_version_line "yosys"      yosys      -V
  tool_version_line "verilator"  verilator  --version
  tool_version_line "iverilog"   iverilog   -V
  tool_version_line "vvp"        vvp        -V
  cocotb_version_line
  tool_version_line "python3"    python3    --version
  echo "========================================"
}

# Ensure required tools are present after install (or in check-only mode).
verify_tools_present() {
  local missing=()
  have_cmd yosys     || missing+=("yosys")
  have_cmd verilator || missing+=("verilator")
  have_cmd iverilog  || missing+=("iverilog")
  have_cmd vvp       || missing+=("vvp")

  local py="${VENV_DIR}/bin/python"
  if [[ -x "${py}" ]]; then
    "${py}" -c "import cocotb" >/dev/null 2>&1 || missing+=("cocotb")
  else
    python3 -c "import cocotb" >/dev/null 2>&1 || missing+=("cocotb")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "required tool(s) missing: ${missing[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  detect_os

  if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    log "check-only mode: skipping installs"
  else
    apt_install_eda
    ensure_venv_and_cocotb
  fi

  verify_tools_present
  print_version_summary
  log "toolchain setup complete"
}

main "$@"
