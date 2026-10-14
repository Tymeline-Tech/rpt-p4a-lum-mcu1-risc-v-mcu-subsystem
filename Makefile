# LUM-MCU1 — repository foundation build contract
# Machine-checkable entry points: make lint | make sim | make synth
#
# Toolchain routing (toolchains.yml + verification.yml):
#   make lint, make sim  -> hdl_sim   (verilator runner)
#   make synth           -> hdl_synth (yosys runner)
#
# Fail-fast: recipes preserve the underlying tool exit status for CI.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DELETE_ON_ERROR:

.PHONY: setup-check lint sim synth

# ---------------------------------------------------------------------------
# Shared RTL discovery
# ---------------------------------------------------------------------------
RTL_SRCS := $(shell find rtl -type f -name '*.sv' 2>/dev/null | LC_ALL=C sort)
TOP      ?= smoke

# ---------------------------------------------------------------------------
# setup-check — foundational layout gate
# ---------------------------------------------------------------------------
setup-check:
	@test -d rtl || (echo "error: rtl/ directory missing" >&2; exit 1)
	@test -d tb || (echo "error: tb/ directory missing" >&2; exit 1)
	@test -d synth || (echo "error: synth/ directory missing" >&2; exit 1)
	@test -d docs || (echo "error: docs/ directory missing" >&2; exit 1)
	@test -f setup.sh || (echo "error: setup.sh missing" >&2; exit 1)
	@touch RTL_DIR_EXISTS TB_DIR_EXISTS SYNTH_DIR_EXISTS DOCS_DIR_EXISTS SETUP_SCRIPT_EXISTS
	@echo "setup-check: rtl/ tb/ synth/ docs/ and setup.sh present"

# ---------------------------------------------------------------------------
# make lint — Verilator strict lint (hdl_sim / verilator runner ONLY)
# TOOLCHAIN: hdl_sim
# RUNNER: verilator
# Must NOT run on the yosys runner: verilator there is a stub (exit 78).
# Declared in toolchains.yml + verification.yml as its own hdl_sim gate.
# ---------------------------------------------------------------------------
VERILATOR       ?= verilator
# --lint-only: syntax / width / logic checks without building a sim binary.
# -Wall:      strict warnings (width mismatches, unused nets, etc.).
# -sv:        treat sources as SystemVerilog.
# --assert:   parse/check SVA (platform sims also require --assert).
VERILATOR_FLAGS ?= --lint-only -Wall -sv --assert
LINT_LOG        ?= lint.log

lint:
	@if [ -z "$(RTL_SRCS)" ]; then \
		echo "error: no SystemVerilog sources found under rtl/" >&2; \
		exit 1; \
	fi
	@echo "lint: $(VERILATOR) $(VERILATOR_FLAGS) $(RTL_SRCS)"
	@rm -f "$(LINT_LOG)"
	@set +e; \
	$(VERILATOR) $(VERILATOR_FLAGS) $(RTL_SRCS) > "$(LINT_LOG)" 2>&1; \
	status=$$?; \
	set -e; \
	if [ $$status -ne 0 ]; then \
		echo "error: verilator lint failed (exit $$status); see $(LINT_LOG)" >&2; \
		cat "$(LINT_LOG)" >&2 || true; \
		exit $$status; \
	fi
	@touch MAKFILE_DEFINED LINT_TARGET_PASS
	@echo "lint: OK — log $(LINT_LOG); wrote MAKFILE_DEFINED LINT_TARGET_PASS"

# ---------------------------------------------------------------------------
# make sim — cocotb + Icarus Verilog (hdl_sim / verilator runner)
# TOOLCHAIN: hdl_sim
# RUNNER: verilator
#
# Orchestrator pattern (cocotb "makefile simulate" template):
#   include $(shell cocotb-config --makefiles)/Makefile.sim
# Invoked via a nested make so lint/synth targets stay independent.
#
# Python-to-Verilog bridge: PATH/PYTHONPATH/PYTHON_BIN point at the cocotb
# install so Makefile.sim resolves VPI libs and imports tb/test_smoke.py.
# ---------------------------------------------------------------------------
SIM                 ?= icarus
TOPLEVEL_LANG       ?= verilog
# Placeholder smoke DUT (rtl/smoke.sv); override with TOP=... when needed.
TOPLEVEL            ?= $(TOP)
COCOTB_TOPLEVEL     ?= $(TOPLEVEL)
# Cocotb 2.x name; MODULE kept for older cocotb Makefile.sim compatibility.
COCOTB_TEST_MODULES ?= test_smoke
MODULE              ?= $(COCOTB_TEST_MODULES)
WAVES               ?= 1
SIM_BUILD           ?= sim_build
COVERAGE_XML        ?= coverage.xml
COCOTB_RESULTS_FILE ?= results.xml

# Prefer project venv (setup.sh), then PATH — CI runners ship system cocotb.
COCOTB_CONFIG ?= $(shell \
	if [ -x .venv/bin/cocotb-config ]; then echo .venv/bin/cocotb-config; \
	elif command -v cocotb-config >/dev/null 2>&1; then command -v cocotb-config; \
	else echo cocotb-config; fi)

sim:
	@if [ -z "$(RTL_SRCS)" ]; then \
		echo "error: no SystemVerilog sources found under rtl/" >&2; \
		exit 1; \
	fi
	@test -f tb/test_smoke.py || (echo "error: tb/test_smoke.py missing" >&2; exit 1)
	@command -v iverilog >/dev/null 2>&1 || { \
		echo "error: iverilog not found on PATH (required for SIM=icarus)" >&2; \
		exit 1; \
	}
	@command -v vvp >/dev/null 2>&1 || { \
		echo "error: vvp not found on PATH (required for SIM=icarus)" >&2; \
		exit 1; \
	}
	@if ! $(COCOTB_CONFIG) --makefiles >/dev/null 2>&1; then \
		echo "error: cocotb-config not usable (COCOTB_CONFIG=$(COCOTB_CONFIG))" >&2; \
		exit 1; \
	fi
	@echo "sim: cocotb SIM=$(SIM) TOPLEVEL=$(TOPLEVEL) MODULE=$(MODULE) WAVES=$(WAVES)"
	@mkdir -p "$(SIM_BUILD)"
	@rm -f "$(COCOTB_RESULTS_FILE)" "$(COVERAGE_XML)"
	@set +e; \
	_cocotb_bin_dir="$$(cd "$$(dirname "$(COCOTB_CONFIG)")" && pwd)"; \
	_python_bin="$$($(COCOTB_CONFIG) --python-bin 2>/dev/null || true)"; \
	if [ -z "$$_python_bin" ]; then _python_bin=python3; fi; \
	_mf="$$($(COCOTB_CONFIG) --makefiles)/Makefile.sim"; \
	echo "sim: using makefile $$_mf (python=$$_python_bin)"; \
	PATH="$$_cocotb_bin_dir:$$PATH" \
	PYTHONPATH="tb$${PYTHONPATH:+:$$PYTHONPATH}" \
	PYTHON="$$_python_bin" \
	SIM="$(SIM)" \
	TOPLEVEL_LANG="$(TOPLEVEL_LANG)" \
	TOPLEVEL="$(TOPLEVEL)" \
	COCOTB_TOPLEVEL="$(COCOTB_TOPLEVEL)" \
	MODULE="$(MODULE)" \
	COCOTB_TEST_MODULES="$(COCOTB_TEST_MODULES)" \
	WAVES="$(WAVES)" \
	SIM_BUILD="$(SIM_BUILD)" \
	COCOTB_RESULTS_FILE="$(COCOTB_RESULTS_FILE)" \
	VERILOG_SOURCES="$(RTL_SRCS)" \
	$(MAKE) -f "$$_mf" sim; \
	status=$$?; \
	set -e; \
	if [ $$status -ne 0 ]; then \
		echo "error: cocotb simulation failed (exit $$status)" >&2; \
		exit $$status; \
	fi
	@test -f "$(COCOTB_RESULTS_FILE)" || (echo "error: $(COCOTB_RESULTS_FILE) not produced" >&2; exit 1)
	@test -f "$(COVERAGE_XML)" || (echo "error: $(COVERAGE_XML) not produced by test" >&2; exit 1)
	@touch MAKFILE_DEFINED SIM_TARGET_PASS
	@echo "sim: OK — wrote $(COVERAGE_XML) $(COCOTB_RESULTS_FILE) MAKFILE_DEFINED SIM_TARGET_PASS"

# ---------------------------------------------------------------------------
# make synth — Yosys sky130hd technology mapping (hdl_synth / yosys runner)
# TOOLCHAIN: hdl_synth
# RUNNER: yosys
#
# Loads sky130hd cells via synth/sky130hd_cells.lib through
# synth/sky130hd_synth.tcl (dfflibmap + abc). Missing techmap/liberty fails
# fast with a non-zero exit for CI. Explicit .PHONY avoids vacuous success
# against the synth/ directory.
# ---------------------------------------------------------------------------
YOSYS          ?= yosys
SYNTH_SCRIPT   ?= synth/sky130hd_synth.tcl
SKY130HD_LIB   ?= synth/sky130hd_cells.lib
NETLIST        ?= synth/$(TOP)_sky130hd.v
SYNTH_LOG      ?= synth.log

synth:
	@if [ -z "$(RTL_SRCS)" ]; then \
		echo "error: no SystemVerilog sources found under rtl/" >&2; \
		exit 1; \
	fi
	@test -f "$(SYNTH_SCRIPT)" || (echo "error: synthesis script missing: $(SYNTH_SCRIPT)" >&2; exit 1)
	@if [ ! -f "$(SKY130HD_LIB)" ]; then \
		echo "error: sky130hd techmap/liberty missing: $(SKY130HD_LIB)" >&2; \
		echo "error: cannot technology-map for process node sky130hd" >&2; \
		exit 1; \
	fi
	@echo "synth: $(YOSYS) -c $(SYNTH_SCRIPT) top=$(TOP) lib=$(SKY130HD_LIB) -> $(NETLIST)"
	@mkdir -p synth
	@rm -f "$(NETLIST)" "$(SYNTH_LOG)"
	@set +e; \
	TOP="$(TOP)" \
	RTL_SRCS="$(RTL_SRCS)" \
	NETLIST="$(NETLIST)" \
	SKY130HD_LIB="$(SKY130HD_LIB)" \
	$(YOSYS) -c "$(SYNTH_SCRIPT)" > "$(SYNTH_LOG)" 2>&1; \
	status=$$?; \
	set -e; \
	if [ $$status -ne 0 ]; then \
		echo "error: yosys sky130hd synthesis failed (exit $$status); see $(SYNTH_LOG)" >&2; \
		cat "$(SYNTH_LOG)" >&2 || true; \
		exit $$status; \
	fi
	@test -f "$(NETLIST)" || (echo "error: netlist $(NETLIST) not produced" >&2; exit 1)
	@touch MAKFILE_DEFINED SYNTH_TARGET_PASS
	@echo "synth: OK — netlist $(NETLIST); wrote MAKFILE_DEFINED SYNTH_TARGET_PASS"
