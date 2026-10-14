"""Directed cocotb suite for RV32I base integer instruction execution.

Exercises Loads (LW), Stores (SW), Branches (BNE, BLE), and jumps (JAL,
JALR) on ``instruction_isa_core`` over an APB3 master / pseudo-memory path.
Functional coverage is exported to ``coverage.xml``.
"""

from __future__ import annotations

import os
from typing import Dict, Iterable

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb_coverage.coverage import CoverPoint, coverage_db


MASK32 = 0xFFFF_FFFF

OPC_LOAD = 0b0000011
OPC_OP_IMM = 0b0010011
OPC_STORE = 0b0100011
OPC_BRANCH = 0b1100011
OPC_JALR = 0b1100111
OPC_JAL = 0b1101111

F3_LW = 0b010
F3_SW = 0b010
F3_ADDI = 0b000
F3_BNE = 0b001
F3_BGE = 0b101
F3_JALR = 0b000

EBREAK = 0x00100073


def encode_i(imm12: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    return (
        ((imm12 & 0xFFF) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def encode_s(imm12: int, rs2: int, rs1: int, funct3: int, opcode: int) -> int:
    imm = imm12 & 0xFFF
    return (
        ((imm >> 5) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((imm & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def encode_b(imm_bytes: int, rs2: int, rs1: int, funct3: int) -> int:
    """Encode a B-type branch. ``imm_bytes`` is the byte offset from PC."""
    imm = imm_bytes & 0x1FFF
    return (
        (((imm >> 12) & 1) << 31)
        | (((imm >> 5) & 0x3F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | (((imm >> 1) & 0xF) << 8)
        | (((imm >> 11) & 1) << 7)
        | OPC_BRANCH
    )


def encode_j(imm_bytes: int, rd: int) -> int:
    imm = imm_bytes & 0x1FFFFF
    return (
        (((imm >> 20) & 1) << 31)
        | (((imm >> 1) & 0x3FF) << 21)
        | (((imm >> 11) & 1) << 20)
        | (((imm >> 12) & 0xFF) << 12)
        | ((rd & 0x1F) << 7)
        | OPC_JAL
    )


def addi(rd: int, rs1: int, imm: int) -> int:
    return encode_i(imm, rs1, F3_ADDI, rd, OPC_OP_IMM)


def lw(rd: int, rs1: int, imm: int) -> int:
    return encode_i(imm, rs1, F3_LW, rd, OPC_LOAD)


def sw(rs2: int, rs1: int, imm: int) -> int:
    return encode_s(imm, rs2, rs1, F3_SW, OPC_STORE)


def bne(rs1: int, rs2: int, imm_bytes: int) -> int:
    return encode_b(imm_bytes, rs2, rs1, F3_BNE)


def ble(rs1: int, rs2: int, imm_bytes: int) -> int:
    """BLE pseudo-op: branch if rs1 <= rs2  ==>  BGE rs2, rs1."""
    return encode_b(imm_bytes, rs1, rs2, F3_BGE)


def jal(rd: int, imm_bytes: int) -> int:
    return encode_j(imm_bytes, rd)


def jalr(rd: int, rs1: int, imm: int = 0) -> int:
    return encode_i(imm, rs1, F3_JALR, rd, OPC_JALR)


class PseudoMemory:
    """Word-oriented memory / cache bank backing the APB slave model."""

    def __init__(self) -> None:
        self._words: Dict[int, int] = {}

    def write_word(self, addr: int, data: int) -> None:
        """Direct (backdoor) write into the memory bank — word-aligned."""
        if addr & 0x3:
            raise ValueError(f"unaligned word write @ 0x{addr:08x}")
        self._words[addr & MASK32] = data & MASK32

    def read_word(self, addr: int) -> int:
        if addr & 0x3:
            raise ValueError(f"unaligned word read @ 0x{addr:08x}")
        return self._words.get(addr & MASK32, 0)

    def load_program(self, base: int, words: Iterable[int]) -> None:
        for i, w in enumerate(words):
            self.write_word((base + 4 * i) & MASK32, w & MASK32)


async def apb_memory_slave(dut, mem: PseudoMemory) -> None:
    """APB3 slave for the core master: always-ready; PRDATA from pseudo-mem."""
    dut.PREADY.value = 1
    dut.PRDATA.value = 0
    while True:
        await RisingEdge(dut.clk)
        psel = int(dut.PSEL.value)
        penable = int(dut.PENABLE.value)
        pwrite = int(dut.PWRITE.value)
        addr = int(dut.PADDR.value) & MASK32
        # Present read data in SETUP so ACCESS samples a stable PRDATA.
        if psel and not pwrite:
            dut.PRDATA.value = mem.read_word(addr)
        if psel and penable and pwrite:
            mem.write_word(addr, int(dut.PWDATA.value) & MASK32)
        dut.PREADY.value = 1


@CoverPoint(
    "isa_i.opcode_class",
    xf=lambda kind, *_: kind,
    bins=["lw", "sw", "bne", "ble", "jal", "jalr"],
)
def _cover_kind(kind: str, *args) -> None:
    del args


@CoverPoint(
    "isa_i.branch_taken",
    xf=lambda _kind, taken, *_: int(taken),
    bins=[0, 1],
)
def _cover_branch(kind: str, taken: int, *args) -> None:
    del kind, args


def _export_coverage() -> None:
    coverage_db.export_to_xml(filename="coverage.xml")
    assert os.path.isfile("coverage.xml"), "coverage.xml was not written"


async def _reset(dut) -> None:
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.entry_pc.value = 0
    dut.step_limit.value = 64
    dut.peek_raddr.value = 0
    dut.PRDATA.value = 0
    dut.PREADY.value = 1
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def _run_program(
    dut,
    entry: int = 0,
    step_limit: int = 128,
    timeout_cycles: int = 2000,
) -> None:
    dut.entry_pc.value = entry
    dut.step_limit.value = step_limit
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.done.value) == 1:
            return
    raise TimeoutError("core did not reach done within timeout")


async def _peek_reg(dut, reg: int) -> int:
    dut.peek_raddr.value = reg & 0x1F
    await RisingEdge(dut.clk)
    return int(dut.peek_rdata.value) & MASK32


async def _start_bench(dut) -> PseudoMemory:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    mem = PseudoMemory()
    cocotb.start_soon(apb_memory_slave(dut, mem))
    await _reset(dut)
    return mem


@cocotb.test()
async def test_lw_fetches_from_pseudo_memory(dut):
    """Backdoor-write a word, execute LW, compare fetched_data."""
    mem = await _start_bench(dut)

    data_addr = 0x00000100
    payload = 0xA5A55A5A
    mem.write_word(data_addr, payload)

    prog = [
        addi(1, 0, data_addr),
        lw(2, 1, 0),
        EBREAK,
    ]
    mem.load_program(0x00000000, prog)

    await _run_program(dut, entry=0, step_limit=16)
    fetched = int(dut.fetched_data.value) & MASK32
    _cover_kind("lw")
    assert fetched == payload, f"fetched_data=0x{fetched:08x} want 0x{payload:08x}"
    x2 = await _peek_reg(dut, 2)
    assert x2 == payload, f"x2=0x{x2:08x} want 0x{payload:08x}"
    _export_coverage()


@cocotb.test()
async def test_sw_writes_memory_bank(dut):
    """Store path: SW commits a register value into the pseudo-memory bank."""
    mem = await _start_bench(dut)

    dst = 0x00000200
    value = 0x00000421
    prog = [
        addi(1, 0, dst),
        addi(2, 0, value),
        sw(2, 1, 0),
        EBREAK,
    ]
    mem.load_program(0, prog)
    await _run_program(dut, entry=0, step_limit=16)
    got = mem.read_word(dst)
    _cover_kind("sw")
    assert got == value, f"mem[0x{dst:x}]=0x{got:08x} want 0x{value:08x}"
    _export_coverage()


@cocotb.test()
async def test_bne_branch_loop(dut):
    """BNE countdown loop: x3 starts at 3 and exits when equal to x0."""
    mem = await _start_bench(dut)

    # 0: addi x3, x0, 3
    # 4: addi x3, x3, -1
    # 8: bne  x3, x0, -4
    # C: ebreak
    prog = [
        addi(3, 0, 3),
        addi(3, 3, (-1) & 0xFFF),
        bne(3, 0, -4),
        EBREAK,
    ]
    mem.load_program(0, prog)
    await _run_program(dut, entry=0, step_limit=64)
    x3 = await _peek_reg(dut, 3)
    _cover_kind("bne")
    _cover_branch("bne", 1)
    assert x3 == 0, f"loop exit x3={x3} want 0"
    assert int(dut.trap_illegal.value) == 0
    assert int(dut.instr_count.value) >= 5
    _export_coverage()


@cocotb.test()
async def test_ble_branch_loop(dut):
    """BLE pseudo-loop: increment x4 while x4 <= x5, then fall through."""
    mem = await _start_bench(dut)

    # 0: addi x4, x0, 0
    # 4: addi x5, x0, 2
    # 8: addi x4, x4, 1
    # C: ble  x4, x5, -4
    #10: ebreak
    prog = [
        addi(4, 0, 0),
        addi(5, 0, 2),
        addi(4, 4, 1),
        ble(4, 5, -4),
        EBREAK,
    ]
    mem.load_program(0, prog)
    await _run_program(dut, entry=0, step_limit=64)
    x4 = await _peek_reg(dut, 4)
    _cover_kind("ble")
    _cover_branch("ble", 1)
    assert x4 == 3, f"BLE loop exit x4={x4} want 3"
    _export_coverage()


@cocotb.test()
async def test_jal_and_jalr_control_transfer(dut):
    """JAL links return address; JALR returns; SW captures the link word."""
    mem = await _start_bench(dut)

    link_slot = 0x00000300
    # 0x00: addi x10, x0, link_slot
    # 0x04: jal  x1, +0x14      -> 0x18, x1=0x08
    # 0x08: addi x6, x0, 0x55   (after return)
    # 0x0C: sw   x1, 0(x10)
    # 0x10: ebreak
    # 0x14: pad
    # 0x18: addi x7, x0, 0x77
    # 0x1C: jalr x0, 0(x1)
    prog = [
        addi(10, 0, link_slot),
        jal(1, 0x14),
        addi(6, 0, 0x55),
        sw(1, 10, 0),
        EBREAK,
        addi(0, 0, 0),
        addi(7, 0, 0x77),
        jalr(0, 1, 0),
    ]
    mem.load_program(0, prog)
    await _run_program(dut, entry=0, step_limit=64)

    x6 = await _peek_reg(dut, 6)
    x7 = await _peek_reg(dut, 7)
    link = mem.read_word(link_slot)
    _cover_kind("jal")
    _cover_kind("jalr")
    assert x7 == 0x77, f"jal target did not run, x7={x7}"
    assert x6 == 0x55, f"return path did not run, x6={x6}"
    assert link == 0x08, f"link register stored 0x{link:08x} want 0x08"
    assert int(dut.trap_illegal.value) == 0
    _export_coverage()


@cocotb.test()
async def test_lw_sw_roundtrip_over_apb(dut):
    """End-to-end APB flow: SW then LW; fetched_data matches stored word."""
    mem = await _start_bench(dut)

    addr = 0x00000400
    value = 0x123
    prog = [
        addi(1, 0, addr),
        addi(2, 0, value),
        sw(2, 1, 0),
        addi(3, 0, 0),
        lw(3, 1, 0),
        EBREAK,
    ]
    mem.load_program(0, prog)
    await _run_program(dut, entry=0, step_limit=32)
    fetched = int(dut.fetched_data.value) & MASK32
    _cover_kind("lw")
    _cover_kind("sw")
    assert fetched == value, f"fetched_data=0x{fetched:08x} want 0x{value:08x}"
    assert mem.read_word(addr) == value
    x3 = await _peek_reg(dut, 3)
    assert x3 == value
    _export_coverage()
