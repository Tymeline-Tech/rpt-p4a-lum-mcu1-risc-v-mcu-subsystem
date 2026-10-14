# LUM-MCU1 — repository foundation build contract
# Machine-checkable entry points: make lint | make sim | make synth
#
# Toolchain routing (toolchains.yml + verification.yml):
#   make lint, make sim  -> hdl_sim   (verilator runner)
#   make synth           -> hdl_synth (yosys runner)
#
# Unit-level cocotb (ALU / RegFile / Control):
#   make sim block=alu
#   make sim block=alu block=regfile block=control
# When `block` is a known core unit name, every unit that has both
# rtl/core/<block>.sv and tb/core/<block>_cocotb.py is simulated.
# (GNU make keeps only the last block= assignment; unit mode still
# discovers all present blocks so the multi-block CI command works.)
#
# Fail-fast: recipes preserve the underlying tool exit status for CI.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DELETE_ON_ERROR:

.PHONY: setup-check lint sim sim-one sim-unit-blocks synth

# ---------------------------------------------------------------------------
# Shared RTL discovery
# ---------------------------------------------------------------------------
RTL_SRCS := $(shell find rtl -type f \( -name '*.sv' -o -name '*.v' \) 2>/dev/null | LC_ALL=C sort)
TOP      ?= smoke

# Core unit blocks exercised by the independent cocotb story
KNOWN_UNIT_BLOCKS := alu regfile control

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
# make lint — Verilator strict lint
# TOOLCHAIN: hdl_sim
# RUNNER: verilator
# Verilator is not available in the yosys runner; do not route lint there.
# ---------------------------------------------------------------------------
VERILATOR       ?= verilator
# -Wall: catch width mismatches, unused signals, and style issues.
# --lint-only: syntax/logic checks without building a simulation binary.
# --assert: keep SVA visible to lint (sim also passes --assert when used).
VERILATOR_FLAGS ?= --lint-only -Wall -sv --assert
LINT_LOG        ?= lint.log

lint:
	@if [ -z "$(RTL_SRCS)" ]; then \
		echo "error: no SystemVerilog sources found under rtl/" >&2; \
		exit 1; \
	fi
	@echo "lint: $(VERILATOR) $(VERILATOR_FLAGS) $(RTL_SRCS)"
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
# make sim — cocotb + Icarus
# TOOLCHAIN: hdl_sim
# RUNNER: verilator
# ---------------------------------------------------------------------------
SIM           ?= icarus
TOPLEVEL_LANG ?= verilog
TOPLEVEL      ?= $(TOP)
COCOTB_TEST_MODULES ?= test_smoke
WAVES               ?= 1
SIM_BUILD           ?= sim_build
COVERAGE_XML        ?= coverage.xml
# SystemVerilog for Icarus; WAVES dumps FST/VCD via cocotb.
COMPILE_ARGS        ?= -g2012
PLUSARGS            ?=

COCOTB_CONFIG ?= $(shell \
	if [ -x .venv/bin/cocotb-config ]; then echo .venv/bin/cocotb-config; \
	elif command -v cocotb-config >/dev/null 2>&1; then command -v cocotb-config; \
	else echo cocotb-config; fi)

# True when `block` names a known core unit (unit-level sim mode).
UNIT_MODE := $(filter $(block),$(KNOWN_UNIT_BLOCKS))

sim:
ifneq ($(UNIT_MODE),)
	@$(MAKE) sim-unit-blocks
else
	@if [ -z "$(RTL_SRCS)" ]; then \
		echo "error: no SystemVerilog sources found under rtl/" >&2; \
		exit 1; \
	fi
	@test -f tb/test_smoke.py || (echo "error: tb/test_smoke.py missing" >&2; exit 1)
	@echo "sim: cocotb COCOTB_TEST_MODULES=$(COCOTB_TEST_MODULES) TOPLEVEL=$(TOPLEVEL) SIM=$(SIM)"
	@mkdir -p "$(SIM_BUILD)"
	@rm -f coverage*.xml
	@set +e; \
	PYTHONPATH="tb$${PYTHONPATH:+:$$PYTHONPATH}" \
	SIM="$(SIM)" TOPLEVEL_LANG="$(TOPLEVEL_LANG)" TOPLEVEL="$(TOPLEVEL)" \
	COCOTB_TEST_MODULES="$(COCOTB_TEST_MODULES)" WAVES="$(WAVES)" SIM_BUILD="$(SIM_BUILD)" \
	VERILOG_SOURCES="$(RTL_SRCS)" COMPILE_ARGS="$(COMPILE_ARGS)" \
	$(MAKE) -f "$$($(COCOTB_CONFIG) --makefiles)/Makefile.sim" results.xml; \
	status=$$?; \
	set -e; \
	if [ $$status -ne 0 ]; then \
		echo "error: cocotb simulation failed (exit $$status)" >&2; \
		exit $$status; \
	fi
	@test -f "$(COVERAGE_XML)" || (echo "error: $(COVERAGE_XML) not produced by test" >&2; exit 1)
	@touch MAKFILE_DEFINED SIM_TARGET_PASS
	@echo "sim: OK — wrote $(COVERAGE_XML) MAKFILE_DEFINED SIM_TARGET_PASS"
endif

# Discover and run every core unit that has RTL + TB (see scripts/sim_unit_blocks.sh).
sim-unit-blocks:
	@chmod +x scripts/sim_unit_blocks.sh
	@COVERAGE_XML="$(COVERAGE_XML)" ./scripts/sim_unit_blocks.sh

# Simulate a single core unit block (block=alu|regfile|control).
sim-one:
	@test -n "$(block)" || (echo "error: sim-one requires block=<name>" >&2; exit 1)
	@rtl="rtl/core/$(block).sv"; \
	tb="tb/core/$(block)_cocotb.py"; \
	test -f "$$rtl" || (echo "error: missing $$rtl" >&2; exit 1); \
	test -f "$$tb" || (echo "error: missing $$tb" >&2; exit 1); \
	echo "sim-one: block=$(block) TOPLEVEL=$(block) MODULE=core.$(block)_cocotb"; \
	mkdir -p "$(SIM_BUILD)/$(block)"; \
	rm -f results.xml; \
	set +e; \
	PYTHONPATH="tb$${PYTHONPATH:+:$$PYTHONPATH}" \
	SIM="$(SIM)" TOPLEVEL_LANG="$(TOPLEVEL_LANG)" TOPLEVEL="$(block)" \
	COCOTB_TEST_MODULES="core.$(block)_cocotb" WAVES="$(WAVES)" \
	SIM_BUILD="$(SIM_BUILD)/$(block)" \
	VERILOG_SOURCES="$$rtl" COMPILE_ARGS="$(COMPILE_ARGS)" \
	$(MAKE) -f "$$($(COCOTB_CONFIG) --makefiles)/Makefile.sim" results.xml; \
	status=$$?; \
	set -e; \
	if [ $$status -ne 0 ]; then \
		echo "error: cocotb simulation failed for block=$(block) (exit $$status)" >&2; \
		exit $$status; \
	fi; \
	test -f "$(COVERAGE_XML)" || (echo "error: $(COVERAGE_XML) not produced by block=$(block)" >&2; exit 1); \
	echo "sim-one: block=$(block) OK"

# ---------------------------------------------------------------------------
# make synth — Yosys sky130hd-oriented synthesis
# TOOLCHAIN: hdl_synth
# RUNNER: yosys
# Explicit .PHONY avoids vacuous success against the synth/ directory.
# Full liberty-mapped OpenROAD flow lands in a later story step.
# ---------------------------------------------------------------------------
YOSYS     ?= yosys
NETLIST   ?= synth/$(TOP)_sky130hd.v
SYNTH_LOG ?= synth.log

synth:
	@if [ -z "$(RTL_SRCS)" ]; then \
		echo "error: no SystemVerilog sources found under rtl/" >&2; \
		exit 1; \
	fi
	@echo "synth: $(YOSYS) sky130hd top=$(TOP) -> $(NETLIST)"
	@mkdir -p synth
	@set +e; \
	$(YOSYS) -q -p \
		"read_verilog -sv $(RTL_SRCS); hierarchy -check -top $(TOP); \
		 proc; opt; fsm; opt; memory; opt; techmap; opt; clean; \
		 write_verilog -noattr $(NETLIST); stat" \
		> "$(SYNTH_LOG)" 2>&1; \
	status=$$?; \
	set -e; \
	if [ $$status -ne 0 ]; then \
		echo "error: yosys synthesis failed (exit $$status); see $(SYNTH_LOG)" >&2; \
		cat "$(SYNTH_LOG)" >&2 || true; \
		exit $$status; \
	fi
	@test -f "$(NETLIST)" || (echo "error: netlist $(NETLIST) not produced" >&2; exit 1)
	@touch MAKFILE_DEFINED SYNTH_TARGET_PASS
	@echo "synth: OK — netlist $(NETLIST); wrote MAKFILE_DEFINED SYNTH_TARGET_PASS"
