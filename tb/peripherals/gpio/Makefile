# Cocotb simulation Makefile for GPIO
SIM             ?= icarus
TOPLEVEL_LANG   ?= verilog

REPO_ROOT       := $(abspath $(CURDIR)/../../..)
RTL             := $(REPO_ROOT)/rtl/peripherals/gpio/gpio.sv

VERILOG_SOURCES := $(RTL)
TOPLEVEL        := gpio
MODULE          := test_gpio
COCOTB_TOPLEVEL := $(TOPLEVEL)
COCOTB_TEST_MODULES := $(MODULE)

ifeq ($(SIM),verilator)
  COMPILE_ARGS += --assert --trace
endif

ifeq ($(SIM),icarus)
  COMPILE_ARGS += -g2012
  COCOTB_PLUSARGS += -fst
endif

export COVERAGE_XML  ?= $(CURDIR)/coverage.xml
export COVERAGE_HTML ?= $(REPO_ROOT)/reports/coverage/gpio_cov.html
export PATH := $(HOME)/.local/bin:$(PATH)

include $(shell cocotb-config --makefiles)/Makefile.sim
