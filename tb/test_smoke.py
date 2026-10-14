"""Minimal cocotb smoke test for rtl/smoke.sv.

Exercises the flop under reset and data capture, dumps waves via cocotb
WAVES=1, and exports exactly one coverage.xml for the functional-coverage gate.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb_coverage.coverage import CoverPoint, coverage_db


@CoverPoint("smoke.d_values", xf=lambda dut: int(dut.d.value), bins=[0, 1])
def _sample_d(dut):
    """Cover both data input polarities."""


@CoverPoint(
    "smoke.q_after_reset",
    xf=lambda dut: int(dut.q.value),
    bins=[0],
)
def _sample_q_reset(dut):
    """Cover reset clearing q."""


async def _reset(dut):
    dut.rst_n.value = 0
    dut.d.value = 0
    await ClockCycles(dut.clk, 2)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_smoke_reset_and_capture(dut):
    """Reset clears q; then d propagates to q on the next clock."""
    dut._log.info("starting smoke test")
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    _sample_q_reset(dut)
    assert int(dut.q.value) == 0, "q must be 0 after reset"

    dut.d.value = 1
    _sample_d(dut)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    assert int(dut.q.value) == 1, "q must follow d=1"

    dut.d.value = 0
    _sample_d(dut)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    assert int(dut.q.value) == 0, "q must follow d=0"

    coverage_db.export_to_xml(filename="coverage.xml")
