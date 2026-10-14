#==============================================================================
# LUM-MCU1 top-level Makefile
#==============================================================================
# Usage:
#   make sim block=uart
#   make sim block=gpio
#==============================================================================

BLOCK       ?= uart
SIM         ?= icarus
REPO_ROOT   := $(abspath $(CURDIR))

UART_TB_DIR := $(REPO_ROOT)/tb/peripherals/uart
GPIO_TB_DIR := $(REPO_ROOT)/tb/peripherals/gpio

COVERAGE_DIR := $(REPO_ROOT)/reports/coverage

.PHONY: sim sim-uart sim-gpio clean help

help:
	@echo "Targets:"
	@echo "  make sim block=uart   - Run UART cocotb suite (icarus)"
	@echo "  make sim block=gpio   - Run GPIO cocotb suite (icarus)"

# Dispatch simulation by block=
sim:
ifeq ($(block),uart)
	$(MAKE) sim-uart
else ifeq ($(block),gpio)
	$(MAKE) sim-gpio
else ifeq ($(BLOCK),uart)
	$(MAKE) sim-uart
else ifeq ($(BLOCK),gpio)
	$(MAKE) sim-gpio
else
	$(error Unknown block '$(block)$(BLOCK)'. Use block=uart or block=gpio)
endif

sim-uart:
	@mkdir -p $(COVERAGE_DIR)
	@mkdir -p $(UART_TB_DIR)/sim_build
	$(MAKE) -C $(UART_TB_DIR) SIM=$(SIM) \
		COVERAGE_XML=$(UART_TB_DIR)/coverage.xml \
		COVERAGE_HTML=$(COVERAGE_DIR)/uart_cov.html
	@test -f $(COVERAGE_DIR)/uart_cov.html || \
		(echo "ERROR: expected artifact $(COVERAGE_DIR)/uart_cov.html missing"; exit 1)
	@test -f $(UART_TB_DIR)/coverage.xml || \
		(echo "ERROR: expected coverage.xml missing"; exit 1)
	@echo "UART simulation PASSED; coverage -> $(COVERAGE_DIR)/uart_cov.html"

sim-gpio:
	@mkdir -p $(COVERAGE_DIR)
	@mkdir -p $(GPIO_TB_DIR)/sim_build
	$(MAKE) -C $(GPIO_TB_DIR) SIM=$(SIM) \
		COVERAGE_XML=$(GPIO_TB_DIR)/coverage.xml \
		COVERAGE_HTML=$(COVERAGE_DIR)/gpio_cov.html
	@test -f $(COVERAGE_DIR)/gpio_cov.html || \
		(echo "ERROR: expected artifact $(COVERAGE_DIR)/gpio_cov.html missing"; exit 1)
	@test -f $(GPIO_TB_DIR)/coverage.xml || \
		(echo "ERROR: expected coverage.xml missing"; exit 1)
	@echo "GPIO simulation PASSED; coverage -> $(COVERAGE_DIR)/gpio_cov.html"

clean:
	$(MAKE) -C $(UART_TB_DIR) clean || true
	$(MAKE) -C $(GPIO_TB_DIR) clean || true
	rm -f $(UART_TB_DIR)/coverage.xml $(GPIO_TB_DIR)/coverage.xml
	rm -f $(COVERAGE_DIR)/uart_cov.html $(COVERAGE_DIR)/gpio_cov.html
