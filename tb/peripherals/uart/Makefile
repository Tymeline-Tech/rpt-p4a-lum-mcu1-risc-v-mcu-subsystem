# Cocotb simulation Makefile for UART
SIM             ?= icarus
TOPLEVEL_LANG   ?= verilog
WAVES           ?= 1

REPO_ROOT       := $(abspath $(CURDIR)/../../..)
RTL             := $(REPO_ROOT)/rtl/peripherals/uart/uart.sv

VERILOG_SOURCES := $(RTL)
TOPLEVEL        := uart
MODULE          := test_uart
COCOTB_TOPLEVEL := $(TOPLEVEL)
COCOTB_TEST_MODULES := $(MODULE)

# Prefer --assert when using Verilator (contract requirement)
ifeq ($(SIM),verilator)
  COMPILE_ARGS += --assert --trace
endif

ifeq ($(SIM),icarus)
  COMPILE_ARGS += -g2012
  COCOTB_PLUSARGS += -fst
endif

export COVERAGE_XML  ?= $(CURDIR)/coverage.xml
export COVERAGE_HTML ?= $(REPO_ROOT)/reports/coverage/uart_cov.html

# Ensure cocotb-config is discoverable (user or system install)
export PATH := $(HOME)/.local/bin:$(PATH)

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: coverage_report
coverage_report:
	@test -f $(COVERAGE_XML) || (echo "missing $(COVERAGE_XML)"; exit 1)
	@mkdir -p $(dir $(COVERAGE_HTML))
	@test -f $(COVERAGE_HTML) || (echo "missing $(COVERAGE_HTML) — test must export HTML"; exit 1)
