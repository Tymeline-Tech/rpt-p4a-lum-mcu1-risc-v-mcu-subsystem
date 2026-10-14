"""Directed cocotb suite for C-extension expansion and illegal-instruction traps.

Exercises ``instruction_isa_core`` over the APB3 master / pseudo-memory path:

1. Malformed / corrupted encodings (esp. illegal R-type ``funct7``) raise
   ``trap_illegal`` and halt the run (interrupted-thread control ports).
2. Raw compressed halfword patterns (``inst[1:0] != 2'b11``) trap the same way —
   this core's 32-bit fetch port has no on-hardware C decompressor.
3. Software-expanded C patterns are loaded as 32-bit RV32I encodings and then
   execute successfully, validating the expansion golden model end-to-end.

Functional coverage is exported to ``coverage.xml``.
"""

from __future__ import annotations

import os
from typing import Iterable, Tuple

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb_coverage.coverage import CoverPoint, coverage_db

from core.instruction_base_i import (
    EBREAK,
    MASK32,
    OPC_OP_IMM,
    PseudoMemory,
    addi,
    apb_memory_slave,
)


OPC_OP = 0b0110011
OPC_CUSTOM0 = 0b0001011  # reserved / unsupported major opcode

F3_ADD = 0b000


# ---------------------------------------------------------------------------
# Encoders / C-extension golden expansion (software reference)
# ---------------------------------------------------------------------------
def encode_r(funct7: int, rs2: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    """Assemble an R-type instruction word (illegal encodings allowed)."""
    return (
        ((funct7 & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def illegal_r_encoding(
    funct7: int = 0b0000010,
    rs2: int = 2,
    rs1: int = 1,
    funct3: int = F3_ADD,
    rd: int = 3,
) -> int:
    """R-notation OP word with a non-base / non-M ``funct7`` (out of RV32IMC)."""
    return encode_r(funct7, rs2, rs1, funct3, rd, OPC_OP)


def corrupt_instruction(base: int, bit_flip_mask: int) -> int:
    """Flip selected bits in an otherwise well-formed word."""
    return (base ^ (bit_flip_mask & MASK32)) & MASK32


def c_nop() -> int:
    """c.nop — quadrant 1, CI-format zero immediate."""
    return 0x0001


def c_addi(rd: int, imm6: int) -> int:
    """Encode c.addi (CI). ``imm6`` is sign-extended 6-bit."""
    imm = imm6 & 0x3F
    return (
        (0b000 << 13)
        | (((imm >> 5) & 1) << 12)
        | ((rd & 0x1F) << 7)
        | ((imm & 0x1F) << 2)
        | 0b01
    )


def c_li(rd: int, imm6: int) -> int:
    """Encode c.li (CI) — load immediate into ``rd`` from x0."""
    imm = imm6 & 0x3F
    return (
        (0b010 << 13)
        | (((imm >> 5) & 1) << 12)
        | ((rd & 0x1F) << 7)
        | ((imm & 0x1F) << 2)
        | 0b01
    )


def c_mv(rd: int, rs2: int) -> int:
    """Encode c.mv (CR) — rd := rs2."""
    return (0b1000 << 12) | ((rd & 0x1F) << 7) | ((rs2 & 0x1F) << 2) | 0b10


def expand_c16(half: int) -> int:
    """Expand a single RV32C halfword to its 32-bit RV32I equivalent.

    Raises ``ValueError`` for encodings this golden model does not cover —
    the trap suite only loads patterns it can expand and then execute on the
    existing I-path datapath (ADDI / ADD).
    """
    h = half & 0xFFFF
    op = h & 0x3
    if op == 0x3:
        raise ValueError(f"not a compressed encoding: 0x{h:04x}")

    funct3 = (h >> 13) & 0x7

    # Quadrant 1 (op == 01)
    if op == 0b01:
        if h == 0x0001:
            return addi(0, 0, 0)  # c.nop
        rd = (h >> 7) & 0x1F
        imm = ((h >> 2) & 0x1F) | (((h >> 12) & 1) << 5)
        if imm & 0x20:
            imm |= ~0x3F  # sign-extend 6-bit
        if funct3 == 0b000 and rd != 0 and imm != 0:
            return addi(rd, rd, imm & 0xFFF)  # c.addi
        if funct3 == 0b010 and rd != 0:
            return addi(rd, 0, imm & 0xFFF)  # c.li
        raise ValueError(f"unsupported quadrant-1 C encoding 0x{h:04x}")

    # Quadrant 2 (op == 10): c.mv
    if op == 0b10:
        rd = (h >> 7) & 0x1F
        rs2 = (h >> 2) & 0x1F
        funct4 = (h >> 12) & 0xF
        if funct4 == 0b1000 and rd != 0 and rs2 != 0:
            # c.mv rd, rs2  =>  add rd, rs2, x0
            return encode_r(0b0000000, 0, rs2, F3_ADD, rd, OPC_OP)
        raise ValueError(f"unsupported quadrant-2 C encoding 0x{h:04x}")

    raise ValueError(f"unsupported compressed encoding 0x{h:04x}")


def pack_c_as_word(half: int) -> int:
    """Present a compressed halfword on the 32-bit fetch port (zero-extended)."""
    return half & 0xFFFF


# ---------------------------------------------------------------------------
# Coverage
# ---------------------------------------------------------------------------
@CoverPoint(
    "isa_trap.kind",
    xf=lambda kind, *_: kind,
    bins=[
        "illegal_r",
        "corrupted",
        "raw_compressed_trap",
        "c_expanded_exec",
        "unknown_opcode",
    ],
)
def _cover_kind(kind: str, *args) -> None:
    del args


@CoverPoint(
    "isa_trap.trap_flag",
    xf=lambda _kind, trapped, *_: int(trapped),
    bins=[0, 1],
)
def _cover_trap(kind: str, trapped: int, *args) -> None:
    del kind, args


def _export_coverage() -> None:
    coverage_db.export_to_xml(filename="coverage.xml")
    assert os.path.isfile("coverage.xml"), "coverage.xml was not written"


# ---------------------------------------------------------------------------
# Bench helpers (APB + run control)
# ---------------------------------------------------------------------------
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


def _assert_interrupted_thread(dut, *, expect_trap: bool = True) -> None:
    """Control-port contract for a halted / trapped run (interrupted thread)."""
    busy = int(dut.busy.value)
    done = int(dut.done.value)
    trap = int(dut.trap_illegal.value)
    assert done == 1, f"done must be 1 after halt, got {done}"
    assert busy == 0, f"busy must clear on halt, got {busy}"
    if expect_trap:
        assert trap == 1, "trap_illegal must flag the illegal / interrupted path"
    else:
        assert trap == 0, "trap_illegal must stay clear on clean halt (ebreak)"


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_illegal_r_encoding_traps(dut):
    """Malformed R-type (bad funct7) asserts trap_illegal and stops the thread."""
    mem = await _start_bench(dut)

    bad = illegal_r_encoding(funct7=0b0000010, rs2=2, rs1=1, rd=3)
    assert (bad & 0x7F) == OPC_OP
    assert ((bad >> 25) & 0x7F) not in (0b0000000, 0b0100000, 0b0000001)

    mem.load_program(0, [bad, EBREAK])
    await _run_program(dut, entry=0, step_limit=16)

    _assert_interrupted_thread(dut, expect_trap=True)
    assert int(dut.instr_count.value) == 0, "illegal must not retire an instruction"
    _cover_kind("illegal_r")
    _cover_trap("illegal_r", 1)
    _export_coverage()


@cocotb.test()
async def test_corrupted_opcode_traps(dut):
    """Bit-flipped / reserved major opcode words trap the same interrupt path."""
    mem = await _start_bench(dut)

    # Corrupt a legal ADDI into an unsupported custom-0 major opcode field.
    legal = addi(1, 0, 0x11)
    corrupted = corrupt_instruction(legal, OPC_OP_IMM ^ OPC_CUSTOM0)
    assert (corrupted & 0x7F) == OPC_CUSTOM0

    # Also emit a fully zeroed / nonsense word (opcode 0).
    nonsense = 0x0000_0000

    mem.load_program(0, [corrupted])
    await _run_program(dut, entry=0, step_limit=8)
    _assert_interrupted_thread(dut, expect_trap=True)
    _cover_kind("corrupted")
    _cover_trap("corrupted", 1)

    # Second program: null encoding after reset.
    await _reset(dut)
    mem.load_program(0, [nonsense, EBREAK])
    await _run_program(dut, entry=0, step_limit=8)
    _assert_interrupted_thread(dut, expect_trap=True)
    _cover_kind("unknown_opcode")
    _cover_trap("unknown_opcode", 1)
    _export_coverage()


@cocotb.test()
async def test_raw_compressed_patterns_trap(dut):
    """Compressed halfwords on the 32-bit fetch port are illegal → trap.

    The ISA harness fetches aligned 32-bit words; without a hardware C
    decompressor, ``inst[1:0] != 2'b11`` must raise ``trap_illegal`` and
    forward the interrupted-thread control state.
    """
    mem = await _start_bench(dut)

    patterns: Tuple[int, ...] = (
        pack_c_as_word(c_nop()),
        pack_c_as_word(c_li(1, 5)),
        pack_c_as_word(c_addi(2, 3)),
        pack_c_as_word(c_mv(3, 1)),
        # Two compressed halves packed into one word (still [1:0] != 11).
        ((c_nop() & 0xFFFF) << 16) | (c_li(1, 1) & 0xFFFF),
    )

    for i, word in enumerate(patterns):
        assert (word & 0x3) != 0x3, f"pattern[{i}] must look compressed"
        await _reset(dut)
        mem.load_program(0, [word & MASK32, EBREAK])
        await _run_program(dut, entry=0, step_limit=8)
        _assert_interrupted_thread(dut, expect_trap=True)
        assert int(dut.pc.value) == 0, "PC must remain on the trapping fetch"
        _cover_kind("raw_compressed_trap")
        _cover_trap("raw_compressed_trap", 1)

    _export_coverage()


@cocotb.test()
async def test_c_patterns_expanded_then_execute(dut):
    """Expand C patterns to 32-bit RV32I, load via APB memory, execute cleanly.

    Validates the software expansion golden model: each compressed pattern is
    expanded *before* execution, then the resulting I/R encoding runs on the
    core without asserting ``trap_illegal``.
    """
    mem = await _start_bench(dut)

    cases: Iterable[Tuple[str, int, int, int]] = (
        # name, compressed half, expected rd, expected value
        ("c.li", c_li(5, 7), 5, 7),
        ("c.addi", c_addi(5, 3), 5, 10),  # after c.li x5,7 then c.addi x5,3
        ("c.mv", c_mv(6, 5), 6, 10),
        ("c.nop", c_nop(), 5, 10),  # nop must not disturb x5
    )

    # Build a single program: expand each C half in order, finish with ebreak.
    expanded: list[int] = []
    for name, half, _rd, _val in cases:
        word32 = expand_c16(half)
        assert (word32 & 0x3) == 0x3, f"{name} expansion must be 32-bit aligned encoding"
        expanded.append(word32)
        _cover_kind("c_expanded_exec")
    expanded.append(EBREAK)

    # Sanity: raw halves are compressed; expansions are distinct full words.
    assert pack_c_as_word(c_li(5, 7)) != expand_c16(c_li(5, 7))
    assert expand_c16(c_nop()) == addi(0, 0, 0)
    assert expand_c16(c_li(5, 7)) == addi(5, 0, 7)
    assert expand_c16(c_addi(5, 3)) == addi(5, 5, 3)
    assert expand_c16(c_mv(6, 5)) == encode_r(0, 0, 5, F3_ADD, 6, OPC_OP)

    mem.load_program(0, expanded)
    await _run_program(dut, entry=0, step_limit=32)

    _assert_interrupted_thread(dut, expect_trap=False)
    x5 = await _peek_reg(dut, 5)
    x6 = await _peek_reg(dut, 6)
    assert x5 == 10, f"after c.li/c.addi expansion x5={x5} want 10"
    assert x6 == 10, f"after c.mv expansion x6={x6} want 10"
    assert int(dut.instr_count.value) >= 4
    _cover_trap("c_expanded_exec", 0)
    _export_coverage()


@cocotb.test()
async def test_trap_then_clean_restart(dut):
    """After an illegal trap, a fresh start can execute a legal program."""
    mem = await _start_bench(dut)

    mem.load_program(0, [illegal_r_encoding(), EBREAK])
    await _run_program(dut, entry=0, step_limit=8)
    _assert_interrupted_thread(dut, expect_trap=True)
    _cover_kind("illegal_r")
    _cover_trap("illegal_r", 1)

    await _reset(dut)
    mem.load_program(0, [addi(1, 0, 0x2A), EBREAK])
    await _run_program(dut, entry=0, step_limit=8)
    _assert_interrupted_thread(dut, expect_trap=False)
    x1 = await _peek_reg(dut, 1)
    assert x1 == 0x2A, f"post-trap restart failed, x1={x1}"
    _cover_trap("illegal_r", 0)
    _export_coverage()
