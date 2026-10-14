# LUM-MCU1 — repository foundation build contract
# Core targets: lint (this stage); sim / synth added in later stages.

.PHONY: setup-check lint

# ---------------------------------------------------------------------------
# Verilator lint — strict checks on all SystemVerilog under rtl/
# ---------------------------------------------------------------------------
VERILATOR       ?= verilator
# -Wall enables style/lint warnings; Verilator treats warnings as fatal unless
# -Wno-fatal is set, so CI fails fast without a bare -Werror (unsupported here).
VERILATOR_FLAGS ?= --lint-only -Wall -sv
LINT_LOG        ?= lint.log
# Glob every .sv under rtl/ (recursive) so new modules are picked up automatically.
RTL_SRCS        := $(shell find rtl -type f -name '*.sv' 2>/dev/null | LC_ALL=C sort)

# Verify foundational layout and emit gate artifacts at the repository root.
# Artifacts are produced by this run (never committed as placeholders).
setup-check:
	@test -d rtl || (echo "error: rtl/ directory missing" >&2; exit 1)
	@test -d tb || (echo "error: tb/ directory missing" >&2; exit 1)
	@test -d synth || (echo "error: synth/ directory missing" >&2; exit 1)
	@test -d docs || (echo "error: docs/ directory missing" >&2; exit 1)
	@test -f setup.sh || (echo "error: setup.sh missing" >&2; exit 1)
	@touch RTL_DIR_EXISTS
	@touch TB_DIR_EXISTS
	@touch SYNTH_DIR_EXISTS
	@touch DOCS_DIR_EXISTS
	@touch SETUP_SCRIPT_EXISTS
	@echo "setup-check: rtl/ tb/ synth/ docs/ and setup.sh present"

# Catch syntax errors, width mismatches, and immediate logic issues before simulation.
# Output is captured in $(LINT_LOG); the Verilator exit status is preserved for CI.
lint:
	@if [ -z "$(RTL_SRCS)" ]; then \
		echo "error: no SystemVerilog sources found under rtl/" >&2; \
		exit 1; \
	fi
	@echo "lint: verilator $(VERILATOR_FLAGS) $(RTL_SRCS)"
	@$(VERILATOR) $(VERILATOR_FLAGS) $(RTL_SRCS) > "$(LINT_LOG)" 2>&1; \
	status=$$?; \
	if [ $$status -ne 0 ]; then \
		echo "error: verilator lint failed (exit $$status); see $(LINT_LOG)" >&2; \
		cat "$(LINT_LOG)" >&2 || true; \
		exit $$status; \
	fi
	@touch MAKFILE_DEFINED LINT_TARGET_PASS
	@echo "lint: OK — log $(LINT_LOG); wrote MAKFILE_DEFINED LINT_TARGET_PASS"
