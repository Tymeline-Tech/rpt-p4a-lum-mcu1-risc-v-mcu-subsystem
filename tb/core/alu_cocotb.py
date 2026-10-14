"""ALU unit-level cocotb suite for the RV32IMC core.

Black-box only: drives ``in1``, ``in2``, ``control`` and polls ``alu_out``.
Reference model lives entirely in Python so the suite stays independent of
RTL internals. Functional coverage is exported to ``coverage.xml``.
"""

from __future__ import annotations

import os
from enum import IntEnum
from typing import Iterable, Sequence

import cocotb
from cocotb.triggers import Timer
from cocotb_coverage.coverage import CoverPoint, coverage_db


class AluOp(IntEnum):
    """Registered standard ALU operations (matches docs/core_unit_interfaces.md)."""

    ADD = 0x0
    SUB = 0x1
    AND = 0x2
    OR = 0x3
    XOR = 0x4
    SLL = 0x5
    SRL = 0x6
    SRA = 0x7


ALU_OPS: tuple[AluOp, ...] = tuple(AluOp)

MASK32 = 0xFFFF_FFFF


def expect_alu(op: AluOp, a: int, b: int) -> int:
    """Golden model for integer ALU results (wrap at 32 bits)."""
    a &= MASK32
    b &= MASK32
    shamt = b & 0x1F
    if op is AluOp.ADD:
        return (a + b) & MASK32
    if op is AluOp.SUB:
        return (a - b) & MASK32
    if op is AluOp.AND:
        return a & b
    if op is AluOp.OR:
        return a | b
    if op is AluOp.XOR:
        return a ^ b
    if op is AluOp.SLL:
        return (a << shamt) & MASK32
    if op is AluOp.SRL:
        return (a >> shamt) & MASK32
    if op is AluOp.SRA:
        if a & 0x8000_0000:
            # Sign-extend then arithmetic shift within 32-bit result.
            signed = a - (1 << 32)
            return (signed >> shamt) & MASK32
        return (a >> shamt) & MASK32
    raise ValueError(f"unsupported ALU op {op!r}")


# ---------------------------------------------------------------------------
# Functional coverage (opcodes + operand edge bins)
# ---------------------------------------------------------------------------
@CoverPoint(
    "alu.opcode",
    xf=lambda op, _a, _b, _out: int(op),
    bins=list(range(8)),
)
def _cover_opcode(op: AluOp, a: int, b: int, out: int) -> None:
    del a, b, out


@CoverPoint(
    "alu.op_a_edges",
    xf=lambda _op, a, _b, _out: a,
    bins=[0x0, 0x1, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF],
)
def _cover_op_a(op: AluOp, a: int, b: int, out: int) -> None:
    del op, b, out


@CoverPoint(
    "alu.op_b_ialu_edges",
    xf=lambda _op, _a, b, _out: b,
    bins=[0x0, 0x1, 0x1F, 0x20, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF],
)
def _cover_op_b(op: AluOp, a: int, b: int, out: int) -> None:
    del op, a, out


def _sample_coverage(op: AluOp, a: int, b: int, out: int) -> None:
    _cover_opcode(op, a, b, out)
    _cover_op_a(op, a, b, out)
    _cover_op_b(op, a, b, out)


async def poll_alu_out(dut, op: AluOp, in1: int, in2: int) -> int:
    """Drive protocol ports and deterministically poll ``alu_out``."""
    dut.in1.value = in1 & MASK32
    dut.in2.value = in2 & MASK32
    dut.control.value = int(op)
    # Combinational settle; one timestep is enough for Icarus.
    await Timer(1, unit="ns")
    raw = dut.alu_out.value
    assert raw.is_resolvable, f"alu_out unresolved for op={op.name} in1={in1:#x} in2={in2:#x}"
    return int(raw) & MASK32


async def check_vector(dut, op: AluOp, in1: int, in2: int) -> None:
    actual = await poll_alu_out(dut, op, in1, in2)
    expected = expect_alu(op, in1, in2)
    assert actual == expected, (
        f"ALU mismatch op={op.name} in1={in1:#010x} in2={in2:#010x}: "
        f"expected={expected:#010x} actual={actual:#010x}"
    )
    _sample_coverage(op, in1 & MASK32, in2 & MASK32, actual)


def _export_coverage() -> None:
    # Exactly one coverage*.xml for the verification gate.
    coverage_db.export_to_xml(filename="coverage.xml")


# ---------------------------------------------------------------------------
# Operand scenario tables
# ---------------------------------------------------------------------------
OP_A_VALUES: Sequence[int] = (
    0x0000_0000,
    0x0000_0001,
    0x0000_0002,
    0x7FFF_FFFF,
    0x8000_0000,
    0xFFFF_FFFE,
    0xFFFF_FFFF,
    0x1234_5678,
    0xA5A5_A5A5,
)

OP_B_IALU_VALUES: Sequence[int] = (
    0x0000_0000,
    0x0000_0001,
    0x0000_000F,
    0x0000_001F,  # max legal shift
    0x0000_0020,  # shift wraps to 0 via [4:0]
    0x0000_00FF,
    0x7FFF_FFFF,
    0x8000_0000,
    0xFFFF_FFFF,
    0x8765_4321,
)

# Fixed partners so op_a / op_b_ialu sweeps stay directed and tractable.
_FIXED_B_FOR_OP_A = 0x0000_0003
_FIXED_A_FOR_OP_B = 0xF0F0_F0F0


class AluOpATests:
    """Parametrized scenarios that sweep ``op_a`` (``in1``) across opcodes."""

    VALUES = OP_A_VALUES


class AluOpBIaluTests:
    """Parametrized scenarios that sweep ``op_b_ialu`` (``in2``) across opcodes."""

    VALUES = OP_B_IALU_VALUES


@cocotb.test(name="alu_op_a_directed")
@cocotb.parametrize(
    op=list(ALU_OPS),
    op_a=list(AluOpATests.VALUES),
)
async def test_op_a_scenarios(dut, op: AluOp, op_a: int) -> None:
    """Directed ``op_a`` vectors for every registered ALU opcode."""
    await check_vector(dut, op, op_a, _FIXED_B_FOR_OP_A)


@cocotb.test(name="alu_op_b_ialu_directed")
@cocotb.parametrize(
    op=list(ALU_OPS),
    op_b=list(AluOpBIaluTests.VALUES),
)
async def test_op_b_ialu_scenarios(dut, op: AluOp, op_b: int) -> None:
    """Directed ``op_b_ialu`` vectors for every registered ALU opcode."""
    await check_vector(dut, op, _FIXED_A_FOR_OP_B, op_b)


@cocotb.test(name="alu_opcode_smoke")
@cocotb.parametrize(op=list(ALU_OPS))
async def test_opcode_smoke(dut, op: AluOp) -> None:
    """One canonical vector per opcode (incl. shift-by-zero / identity cases)."""
    pairs: dict[AluOp, tuple[int, int]] = {
        AluOp.ADD: (0x0000_0001, 0x0000_0001),
        AluOp.SUB: (0x0000_0010, 0x0000_0001),
        AluOp.AND: (0xFFFF_0000, 0x0F0F_0F0F),
        AluOp.OR: (0x00FF_0000, 0x0000_00FF),
        AluOp.XOR: (0xAAAA_AAAA, 0x5555_5555),
        AluOp.SLL: (0x0000_0001, 0x0000_0004),
        AluOp.SRL: (0x8000_0000, 0x0000_0004),
        AluOp.SRA: (0x8000_0000, 0x0000_0004),
    }
    a, b = pairs[op]
    await check_vector(dut, op, a, b)


@cocotb.test(name="alu_shift_edge_cases")
async def test_shift_edge_cases(dut) -> None:
    """Corner cases for SLL/SRL/SRA (max shamt, sign bit, zero)."""
    cases: Iterable[tuple[AluOp, int, int]] = (
        (AluOp.SLL, 0x0000_0001, 31),
        (AluOp.SLL, 0xFFFF_FFFF, 0),
        (AluOp.SRL, 0x8000_0000, 31),
        (AluOp.SRL, 0xFFFF_FFFF, 16),
        (AluOp.SRA, 0x8000_0000, 31),
        (AluOp.SRA, 0xFFFF_FFFF, 1),
        (AluOp.SRA, 0x7FFF_FFFF, 1),
        # shamt taken from in2[4:0] only
        (AluOp.SLL, 0x0000_0001, 0x100),  # -> 0
        (AluOp.SRA, 0x8000_0000, 0x3F),  # -> 31
    )
    for op, a, b in cases:
        await check_vector(dut, op, a, b)


@cocotb.test(name="alu_export_coverage")
async def test_export_coverage(dut) -> None:
    """Final gate: write exactly one coverage.xml for CI."""
    del dut
    _export_coverage()
    assert os.path.isfile("coverage.xml"), "coverage.xml was not written"