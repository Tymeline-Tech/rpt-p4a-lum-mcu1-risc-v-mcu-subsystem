"""Register-file unit-level cocotb suite for the RV32IMC core.

Black-box only: drives ``clk``, ``rst_n``, write port (``we``/``waddr``/``wdata``)
and dual read addresses, then polls ``rdata1``/``rdata2``. Golden model lives in
Python so the suite stays independent of RTL internals. Functional coverage is
exported to ``coverage.xml``.
"""

from __future__ import annotations

import os
from typing import Sequence

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_coverage.coverage import CoverPoint, coverage_db


MASK32 = 0xFFFF_FFFF
CLK_PERIOD_NS = 10

# Directed addresses: x0 plus several non-zero destinations for decode/retention.
WRITE_ADDRS: Sequence[int] = (0, 1, 2, 5, 15, 16, 31)
WRITE_DATA: Sequence[int] = (
    0x0000_0000,
    0x0000_0001,
    0xDEAD_BEEF,
    0x8000_0000,
    0xFFFF_FFFF,
)

# ---------------------------------------------------------------------------
# Functional coverage
# ---------------------------------------------------------------------------
@CoverPoint(
    "regfile.waddr",
    xf=lambda waddr, _wdata, _we: int(waddr),
    bins=[0, 1, 2, 5, 15, 16, 31],
)
def _cover_waddr(waddr: int, wdata: int, we: int) -> None:
    del wdata, we


@CoverPoint(
    "regfile.raddr1",
    xf=lambda raddr1, _raddr2: int(raddr1),
    bins=[0, 1, 2, 5, 15, 31],
)
def _cover_raddr1(raddr1: int, raddr2: int) -> None:
    del raddr2


@CoverPoint(
    "regfile.raddr2",
    xf=lambda _raddr1, raddr2: int(raddr2),
    bins=[0, 1, 2, 5, 15, 31],
)
def _cover_raddr2(raddr1: int, raddr2: int) -> None:
    del raddr1


@CoverPoint(
    "regfile.we",
    xf=lambda _waddr, _wdata, we: int(we),
    bins=[0, 1],
)
def _cover_we(waddr: int, wdata: int, we: int) -> None:
    del waddr, wdata


@CoverPoint(
    "regfile.wdata_edges",
    xf=lambda _waddr, wdata, _we: int(wdata) & MASK32,
    bins=[0x0, 0x1, 0xDEAD_BEEF, 0x8000_0000, 0xFFFF_FFFF],
)
def _cover_wdata(waddr: int, wdata: int, we: int) -> None:
    del waddr, we


def _sample_write_cov(waddr: int, wdata: int, we: int) -> None:
    _cover_waddr(waddr, wdata, we)
    _cover_we(waddr, wdata, we)
    _cover_wdata(waddr, wdata, we)


def _sample_read_cov(raddr1: int, raddr2: int) -> None:
    _cover_raddr1(raddr1, raddr2)
    _cover_raddr2(raddr1, raddr2)


def _export_coverage() -> None:
    coverage_db.export_to_xml(filename="coverage.xml")


# ---------------------------------------------------------------------------
# Python golden model (mirrors black-box contract; no RTL peeking)
# ---------------------------------------------------------------------------
class RegFileModel:
    """Architectural shadow of the 32-entry RV32 register file."""

    def __init__(self) -> None:
        self.regs = [0] * 32

    def reset(self) -> None:
        self.regs = [0] * 32

    def write(self, we: int, waddr: int, wdata: int) -> None:
        if we and (waddr & 0x1F) != 0:
            self.regs[waddr & 0x1F] = wdata & MASK32

    def read(self, raddr: int) -> int:
        a = raddr & 0x1F
        if a == 0:
            return 0
        return self.regs[a] & MASK32


# ---------------------------------------------------------------------------
# DUT helpers
# ---------------------------------------------------------------------------
async def _start_clock(dut) -> None:
    # cocotb 2.x cancels tasks started in a test when that test ends, so every
    # test must start its own clock (do not share one across tests).
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await Timer(1, unit="ns")


async def _reset(dut, model: RegFileModel) -> None:
    """Assert synchronous reset for two rising edges, then release."""
    dut.rst_n.value = 0
    dut.we.value = 0
    dut.waddr.value = 0
    dut.wdata.value = 0
    dut.raddr1.value = 0
    dut.raddr2.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    model.reset()


async def _drive_idle_write(dut) -> None:
    dut.we.value = 0
    dut.waddr.value = 0
    dut.wdata.value = 0


async def _apply_write(dut, we: int, waddr: int, wdata: int) -> None:
    dut.we.value = int(we)
    dut.waddr.value = int(waddr) & 0x1F
    dut.wdata.value = int(wdata) & MASK32


async def _apply_reads(dut, raddr1: int, raddr2: int) -> None:
    dut.raddr1.value = int(raddr1) & 0x1F
    dut.raddr2.value = int(raddr2) & 0x1F


async def _sample_rdata(dut) -> tuple[int, int]:
    """Settle combinational read paths, then sample both ports."""
    await Timer(1, unit="ns")
    r1 = dut.rdata1.value
    r2 = dut.rdata2.value
    assert r1.is_resolvable, "rdata1 unresolved"
    assert r2.is_resolvable, "rdata2 unresolved"
    return int(r1) & MASK32, int(r2) & MASK32


async def _write_and_commit(
    dut,
    model: RegFileModel,
    we: int,
    waddr: int,
    wdata: int,
    raddr1: int = 0,
    raddr2: int = 0,
) -> tuple[int, int]:
    """Drive write + read addresses, commit on rising edge, return post-edge reads.

    Read ports are observed after the synchronous boundary so new write data
    (when applicable) is visible per the async-read / sync-write contract.
    """
    await _apply_write(dut, we, waddr, wdata)
    await _apply_reads(dut, raddr1, raddr2)
    _sample_write_cov(waddr, wdata, we)
    _sample_read_cov(raddr1, raddr2)
    await RisingEdge(dut.clk)
    model.write(we, waddr, wdata)
    await _drive_idle_write(dut)
    actual = await _sample_rdata(dut)
    return actual


async def _expect_reads(
    dut,
    model: RegFileModel,
    raddr1: int,
    raddr2: int,
) -> None:
    await _apply_reads(dut, raddr1, raddr2)
    _sample_read_cov(raddr1, raddr2)
    actual1, actual2 = await _sample_rdata(dut)
    exp1 = model.read(raddr1)
    exp2 = model.read(raddr2)
    assert actual1 == exp1, (
        f"rdata1 mismatch raddr1={raddr1}: expected={exp1:#010x} actual={actual1:#010x}"
    )
    assert actual2 == exp2, (
        f"rdata2 mismatch raddr2={raddr2}: expected={exp2:#010x} actual={actual2:#010x}"
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
@cocotb.test(name="regfile_x0_concurrent_write")
async def test_x0_read_under_concurrent_write(dut) -> None:
    """Read address X0 under concurrent write-port stimuli; always expect 0."""
    model = RegFileModel()
    await _start_clock(dut)
    await _reset(dut, model)

    # Seed a non-zero register so the file is not vacuously all-zero.
    await _write_and_commit(dut, model, we=1, waddr=5, wdata=0x1111_1111, raddr1=5, raddr2=0)

    cases = (
        # Write to x0 while both ports read x0
        (1, 0, 0xFFFF_FFFF, 0, 0),
        # Write to x1 while port1 reads x0
        (1, 1, 0xA5A5_A5A5, 0, 1),
        # Write to x31 while port2 reads x0
        (1, 31, 0xDEAD_BEEF, 31, 0),
        # we=0 write-port traffic with x0 on both reads
        (0, 7, 0x1234_5678, 0, 0),
        # Simultaneous dual-port x0 read during live write to x2
        (1, 2, 0xCAFE_BABE, 0, 0),
    )

    for we, waddr, wdata, r1, r2 in cases:
        actual1, actual2 = await _write_and_commit(
            dut, model, we=we, waddr=waddr, wdata=wdata, raddr1=r1, raddr2=r2
        )
        if r1 == 0:
            assert actual1 == 0, f"X0 rdata1 nonzero under write waddr={waddr} we={we}"
        else:
            assert actual1 == model.read(r1)
        if r2 == 0:
            assert actual2 == 0, f"X0 rdata2 nonzero under write waddr={waddr} we={we}"
        else:
            assert actual2 == model.read(r2)

    # Explicit post-stimulus: both ports parked on X0 after x0-targeted write.
    await _expect_reads(dut, model, 0, 0)


@cocotb.test(name="regfile_write_decode_retention")
async def test_write_decode_and_retention(dut) -> None:
    """Write-address decode and non-zero register content retention."""
    model = RegFileModel()
    await _start_clock(dut)
    await _reset(dut, model)

    # Program distinct values into several non-zero registers.
    program: list[tuple[int, int]] = [
        (1, 0x0000_0001),
        (2, 0x0000_0002),
        (5, 0x5555_5555),
        (15, 0x0F0F_0F0F),
        (16, 0x1010_1010),
        (31, 0xFFFF_FFFF),
    ]
    for waddr, wdata in program:
        await _write_and_commit(dut, model, we=1, waddr=waddr, wdata=wdata)

    # Dual-port simultaneous read of programmed pairs.
    pairs = ((1, 2), (5, 15), (16, 31), (31, 1), (0, 5))
    for r1, r2 in pairs:
        await _expect_reads(dut, model, r1, r2)

    # Overwrite one register; neighbors must retain prior content.
    await _write_and_commit(dut, model, we=1, waddr=5, wdata=0xABCD_EF01)
    await _expect_reads(dut, model, 5, 15)
    await _expect_reads(dut, model, 1, 2)
    await _expect_reads(dut, model, 16, 31)

    # we=0 must not corrupt any register even with toggling waddr/wdata.
    await _write_and_commit(dut, model, we=0, waddr=15, wdata=0xBAD0_BAD0)
    await _expect_reads(dut, model, 15, 5)

    # Writing x0 must not alter architectural state of any register.
    shadow = list(model.regs)
    await _write_and_commit(dut, model, we=1, waddr=0, wdata=0xFFFF_FFFF)
    assert model.regs == shadow
    for addr in (1, 2, 5, 15, 16, 31):
        await _expect_reads(dut, model, addr, 0)


@cocotb.test(name="regfile_sync_boundary")
async def test_sync_boundary_response_delay(dut) -> None:
    """New write data appears only after the rising-edge commit (sync boundary)."""
    model = RegFileModel()
    await _start_clock(dut)
    await _reset(dut, model)

    # Establish known prior value in x7.
    await _write_and_commit(dut, model, we=1, waddr=7, wdata=0x1111_1111, raddr1=7, raddr2=7)
    await _expect_reads(dut, model, 7, 7)

    # Align to an edge, then drive the next write and sample mid-cycle (pre-commit).
    await RisingEdge(dut.clk)
    await _apply_write(dut, we=1, waddr=7, wdata=0x2222_2222)
    await _apply_reads(dut, 7, 0)
    await Timer(CLK_PERIOD_NS // 2, unit="ns")
    pre1, pre2 = await _sample_rdata(dut)
    assert pre1 == 0x1111_1111, f"pre-edge rdata1 changed early: {pre1:#010x}"
    assert pre2 == 0, f"pre-edge X0 rdata2 nonzero: {pre2:#010x}"

    # Crossing the synchronous boundary commits the write.
    await RisingEdge(dut.clk)
    model.write(1, 7, 0x2222_2222)
    await _drive_idle_write(dut)
    post1, post2 = await _sample_rdata(dut)
    assert post1 == 0x2222_2222, f"post-edge rdata1={post1:#010x}"
    assert post2 == 0, f"post-edge X0 rdata2={post2:#010x}"

    # Dual-port: one port watches the written reg, the other a retained neighbor.
    await _write_and_commit(dut, model, we=1, waddr=8, wdata=0x8888_8888)
    await RisingEdge(dut.clk)
    await _apply_write(dut, we=1, waddr=8, wdata=0x9999_9999)
    await _apply_reads(dut, 8, 7)
    await Timer(CLK_PERIOD_NS // 2, unit="ns")
    mid1, mid2 = await _sample_rdata(dut)
    assert mid1 == 0x8888_8888, "port1 must hold pre-commit value"
    assert mid2 == 0x2222_2222, "port2 must retain neighbor across pending write"
    await RisingEdge(dut.clk)
    model.write(1, 8, 0x9999_9999)
    await _drive_idle_write(dut)
    fin1, fin2 = await _sample_rdata(dut)
    assert fin1 == 0x9999_9999
    assert fin2 == 0x2222_2222


@cocotb.test(name="regfile_directed_sweep")
@cocotb.parametrize(waddr=list(WRITE_ADDRS), wdata=list(WRITE_DATA))
async def test_directed_write_sweep(dut, waddr: int, wdata: int) -> None:
    """Directed write sweep covering decode bins and data edges."""
    model = RegFileModel()
    await _start_clock(dut)
    await _reset(dut, model)

    # Probe both read ports simultaneously while committing the write.
    r1 = 0 if waddr != 0 else 1
    r2 = waddr
    actual1, actual2 = await _write_and_commit(
        dut, model, we=1, waddr=waddr, wdata=wdata, raddr1=r1, raddr2=r2
    )
    assert actual1 == model.read(r1)
    assert actual2 == model.read(r2)
    await _expect_reads(dut, model, waddr, 0)


@cocotb.test(name="regfile_export_coverage")
async def test_export_coverage(dut) -> None:
    """Final gate: write exactly one coverage.xml for CI."""
    del dut
    _export_coverage()
    assert os.path.isfile("coverage.xml"), "coverage.xml was not written"
