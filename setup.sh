#!/usr/bin/env bash
# LUM-MCU1 toolchain setup entry point.
# Full installer (Verilator, Icarus Verilog, cocotb, Yosys) is implemented
# in a subsequent story step. This file establishes the expected path so
# Make and CI can locate the setup entry point without path errors.
set -euo pipefail

echo "setup.sh: repository layout ready; toolchain install pending."
exit 0
