"""Control-unit unit-level cocotb suite for the RV32IMC core.

Black-box only: drives ``inst`` / ``phase`` and polls ``ctrl_out``. Golden
decode lives in Python so the suite stays independent of RTL internals.
Covers R-type / I-type opcode fields, stall-vs-phase rules, and binary
enable-state vectors. Functional coverage is exported to ``coverage.xml``.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from enum import IntEnum
from typing import Iterable, Sequence

import cocotb
from cocotb.triggers import Timer
from cocotb_coverage.coverage import CoverPoint, coverage_db


# ---------------------------------------------------------------------------
# ISA / interface constants (mirror docs/core_unit_interfaces.md)
# ---------------------------------------------------------------------------
class Phase(IntEnum):
    DEC = 0
    EX = 1
    MEM = 2
    WB = 3


class AluOp(IntEnum):
    ADD = 0x0
    SUB = 0x1
    AND = 0x2
    OR = 0x3
    XOR = 0x4
    SLL = 0x5
    SRL = 0x6
    SRA = 0x7


OPC_LOAD = 0b0000011
OPC_MISC = 0b0001111
OPC_OP_IMM = 0b0010011
OPC_AUIPC = 0b0010111
OPC_STORE = 0b0100011
OPC_OP = 0b0110011
OPC_LUI = 0b0110111
OPC_BRANCH = 0b1100011
OPC_JALR = 0b1100111
OPC_JAL = 0b1101111
OPC_SYSTEM = 0b1110011

PHASES: tuple[Phase, ...] = tuple(Phase)


@dataclass(frozen=True)
class CtrlOut:
    """Unpacked ``ctrl_out[11:0]`` view."""

    reg_write: int
    mem_write: int
    mem_read: int
    alu_op: int
    alu_src_imm: int
    branch: int
    jump: int
    stall: int
    illegal: int

    @classmethod
    def from_int(cls, value: int) -> "CtrlOut":
        v = int(value) & 0xFFF
        return cls(
            reg_write=(v >> 0) & 1,
            mem_write=(v >> 1) & 1,
            mem_read=(v >> 2) & 1,
            alu_op=(v >> 3) & 0xF,
            alu_src_imm=(v >> 7) & 1,
            branch=(v >> 8) & 1,
            jump=(v >> 9) & 1,
            stall=(v >> 10) & 1,
            illegal=(v >> 11) & 1,
        )

    @property
    def enable_vector(self) -> int:
        """Binary enable state: {mem_read, mem_write, reg_write}."""
        return (self.mem_read << 2) | (self.mem_write << 1) | self.reg_write

    def to_int(self) -> int:
        return (
            ((self.illegal & 1) << 11)
            | ((self.stall & 1) << 10)
            | ((self.jump & 1) << 9)
            | ((self.branch & 1) << 8)
            | ((self.alu_src_imm & 1) << 7)
            | ((self.alu_op & 0xF) << 3)
            | ((self.mem_read & 1) << 2)
            | ((self.mem_write & 1) << 1)
            | (self.reg_write & 1)
        )


# ---------------------------------------------------------------------------
# Instruction builders (assemble mock opcode fields)
# ---------------------------------------------------------------------------
def encode_r(funct7: int, rs2: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    return (
        ((funct7 & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


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


def encode_b(imm12: int, rs2: int, rs1: int, funct3: int) -> int:
    # imm[12|10:5|4:1|11] packing; imm is byte offset >> 1 conceptually
    imm = imm12 & 0x1FFF
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


def encode_u(imm20: int, rd: int, opcode: int) -> int:
    return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def encode_j(imm21: int, rd: int) -> int:
    imm = imm21 & 0x1FFFFF
    return (
        (((imm >> 20) & 1) << 31)
        | (((imm >> 1) & 0x3FF) << 21)
        | (((imm >> 11) & 1) << 20)
        | (((imm >> 12) & 0xFF) << 12)
        | ((rd & 0x1F) << 7)
        | OPC_JAL
    )


def _decode_alu_op(funct3: int, funct7: int, is_imm: bool) -> int:
    if funct3 == 0b000:
        if (not is_imm) and funct7 == 0b0100000:
            return int(AluOp.SUB)
        return int(AluOp.ADD)
    if funct3 == 0b001:
        return int(AluOp.SLL)
    if funct3 == 0b100:
        return int(AluOp.XOR)
    if funct3 == 0b101:
        if funct7 == 0b0100000:
            return int(AluOp.SRA)
        return int(AluOp.SRL)
    if funct3 == 0b110:
        return int(AluOp.OR)
    if funct3 == 0b111:
        return int(AluOp.AND)
    return int(AluOp.ADD)


def expect_ctrl(inst: int, phase: Phase) -> CtrlOut:
    """Python golden model for ``ctrl_out`` (black-box contract)."""
    opcode = inst & 0x7F
    funct3 = (inst >> 12) & 0x7
    funct7 = (inst >> 25) & 0x7F
    is_compressed = (inst & 0x3) != 0x3

    reg_write = 0
    mem_write = 0
    mem_read = 0
    alu_op = int(AluOp.ADD)
    alu_src_imm = 0
    branch = 0
    jump = 0
    stall = 0
    illegal = 0

    if is_compressed:
        illegal = 1
    elif opcode == OPC_OP:
        reg_write = 1
        if funct7 == 0b0000001:
            alu_op = int(AluOp.ADD)
            stall = int(phase == Phase.EX)
        elif funct7 in (0b0000000, 0b0100000):
            alu_op = _decode_alu_op(funct3, funct7, is_imm=False)
        else:
            illegal = 1
            reg_write = 0
    elif opcode == OPC_OP_IMM:
        reg_write = 1
        alu_src_imm = 1
        alu_op = _decode_alu_op(funct3, funct7, is_imm=True)
    elif opcode == OPC_LOAD:
        reg_write = 1
        mem_read = 1
        alu_src_imm = 1
        alu_op = int(AluOp.ADD)
        stall = int(phase == Phase.MEM)
    elif opcode == OPC_STORE:
        mem_write = 1
        alu_src_imm = 1
        alu_op = int(AluOp.ADD)
        stall = int(phase == Phase.MEM)
    elif opcode == OPC_BRANCH:
        branch = 1
        alu_op = int(AluOp.SUB) if funct3 in (0b000, 0b001) else int(AluOp.ADD)
    elif opcode in (OPC_LUI, OPC_AUIPC):
        reg_write = 1
        alu_src_imm = 1
        alu_op = int(AluOp.ADD)
    elif opcode == OPC_JAL:
        reg_write = 1
        jump = 1
        alu_op = int(AluOp.ADD)
    elif opcode == OPC_JALR:
        reg_write = 1
        jump = 1
        alu_src_imm = 1
        alu_op = int(AluOp.ADD)
    elif opcode in (OPC_MISC, OPC_SYSTEM):
        pass
    else:
        illegal = 1

    if illegal or phase in (Phase.DEC, Phase.WB):
        stall = 0

    return CtrlOut(
        reg_write=reg_write,
        mem_write=mem_write,
        mem_read=mem_read,
        alu_op=alu_op,
        alu_src_imm=alu_src_imm,
        branch=branch,
        jump=jump,
        stall=stall,
        illegal=illegal,
    )


# ---------------------------------------------------------------------------
# Functional coverage
# ---------------------------------------------------------------------------
@CoverPoint(
    "control.opcode",
    xf=lambda inst, _phase, _ctrl: int(inst) & 0x7F,
    bins=[
        OPC_LOAD,
        OPC_OP_IMM,
        OPC_STORE,
        OPC_OP,
        OPC_LUI,
        OPC_AUIPC,
        OPC_BRANCH,
        OPC_JAL,
        OPC_JALR,
        OPC_SYSTEM,
    ],
)
def _cover_opcode(inst: int, phase: Phase, ctrl: CtrlOut) -> None:
    del phase, ctrl


@CoverPoint(
    "control.phase",
    xf=lambda _inst, phase, _ctrl: int(phase),
    bins=[0, 1, 2, 3],
)
def _cover_phase(inst: int, phase: Phase, ctrl: CtrlOut) -> None:
    del inst, ctrl


@CoverPoint(
    "control.alu_op",
    xf=lambda _inst, _phase, ctrl: int(ctrl.alu_op),
    bins=list(range(8)),
)
def _cover_alu_op(inst: int, phase: Phase, ctrl: CtrlOut) -> None:
    del inst, phase


# Legal datapath enable vectors only (illegal combos tracked via _SEEN set).
_LEGAL_ENABLE_BINS = [0b000, 0b001, 0b010, 0b101]


@CoverPoint(
    "control.enable_vector",
    xf=lambda _inst, _phase, ctrl: int(ctrl.enable_vector),
    bins=_LEGAL_ENABLE_BINS,
)
def _cover_enable_vector(inst: int, phase: Phase, ctrl: CtrlOut) -> None:
    """Track {mem_read, mem_write, reg_write} binary enable combinations."""
    del inst, phase


@CoverPoint(
    "control.stall",
    xf=lambda _inst, _phase, ctrl: int(ctrl.stall),
    bins=[0, 1],
)
def _cover_stall(inst: int, phase: Phase, ctrl: CtrlOut) -> None:
    del inst, phase


@CoverPoint(
    "control.illegal",
    xf=lambda _inst, _phase, ctrl: int(ctrl.illegal),
    bins=[0, 1],
)
def _cover_illegal(inst: int, phase: Phase, ctrl: CtrlOut) -> None:
    del inst, phase


# Hit-set for enable vectors — surfaces missing combinations at export time.
_SEEN_ENABLE_VECTORS: set[int] = set()


def _sample_coverage(inst: int, phase: Phase, ctrl: CtrlOut) -> None:
    _cover_opcode(inst, phase, ctrl)
    _cover_phase(inst, phase, ctrl)
    _cover_alu_op(inst, phase, ctrl)
    _cover_enable_vector(inst, phase, ctrl)
    _cover_stall(inst, phase, ctrl)
    _cover_illegal(inst, phase, ctrl)
    _SEEN_ENABLE_VECTORS.add(ctrl.enable_vector)


def _export_coverage() -> None:
    missing_legal = sorted(set(_LEGAL_ENABLE_BINS) - _SEEN_ENABLE_VECTORS)
    all_missing = sorted(set(range(8)) - _SEEN_ENABLE_VECTORS)
    cocotb.log.info(
        "control enable-vectors seen=%s; missing_legal=%s; other_unseen=%s",
        sorted(_SEEN_ENABLE_VECTORS),
        missing_legal,
        sorted(set(all_missing) - set(missing_legal)),
    )
    coverage_db.export_to_xml(filename="coverage.xml")


# ---------------------------------------------------------------------------
# DUT helpers
# ---------------------------------------------------------------------------
async def poll_ctrl_out(dut, inst: int, phase: Phase) -> CtrlOut:
    dut.inst.value = int(inst) & 0xFFFF_FFFF
    dut.phase.value = int(phase) & 0x3
    await Timer(1, unit="ns")
    raw = dut.ctrl_out.value
    assert raw.is_resolvable, f"ctrl_out unresolved for inst={inst:#010x} phase={phase}"
    return CtrlOut.from_int(int(raw))


async def check_vector(dut, inst: int, phase: Phase) -> CtrlOut:
    actual = await poll_ctrl_out(dut, inst, phase)
    expected = expect_ctrl(inst, phase)
    assert actual == expected, (
        f"ctrl_out mismatch inst={inst:#010x} phase={phase.name}: "
        f"expected={expected} (0x{expected.to_int():03x}) "
        f"actual={actual} (0x{actual.to_int():03x})"
    )
    _sample_coverage(inst, phase, actual)
    return actual


# ---------------------------------------------------------------------------
# Directed instruction tables
# ---------------------------------------------------------------------------
RTYPE_CASES: Sequence[tuple[str, int]] = (
    ("ADD", encode_r(0b0000000, 2, 1, 0b000, 3, OPC_OP)),
    ("SUB", encode_r(0b0100000, 2, 1, 0b000, 3, OPC_OP)),
    ("AND", encode_r(0b0000000, 2, 1, 0b111, 3, OPC_OP)),
    ("OR", encode_r(0b0000000, 2, 1, 0b110, 3, OPC_OP)),
    ("XOR", encode_r(0b0000000, 2, 1, 0b100, 3, OPC_OP)),
    ("SLL", encode_r(0b0000000, 2, 1, 0b001, 3, OPC_OP)),
    ("SRL", encode_r(0b0000000, 2, 1, 0b101, 3, OPC_OP)),
    ("SRA", encode_r(0b0100000, 2, 1, 0b101, 3, OPC_OP)),
    ("SLT", encode_r(0b0000000, 2, 1, 0b010, 3, OPC_OP)),
    ("MUL", encode_r(0b0000001, 2, 1, 0b000, 3, OPC_OP)),
    ("DIV", encode_r(0b0000001, 2, 1, 0b100, 3, OPC_OP)),
    ("REM", encode_r(0b0000001, 2, 1, 0b110, 3, OPC_OP)),
)

ITYPE_CASES: Sequence[tuple[str, int]] = (
    ("ADDI", encode_i(0x001, 1, 0b000, 3, OPC_OP_IMM)),
    ("ANDI", encode_i(0x0FF, 1, 0b111, 3, OPC_OP_IMM)),
    ("ORI", encode_i(0x0F0, 1, 0b110, 3, OPC_OP_IMM)),
    ("XORI", encode_i(0x00F, 1, 0b100, 3, OPC_OP_IMM)),
    ("SLLI", encode_i(0x004, 1, 0b001, 3, OPC_OP_IMM)),
    ("SRLI", encode_i(0x004, 1, 0b101, 3, OPC_OP_IMM)),
    ("SRAI", encode_i(0x404, 1, 0b101, 3, OPC_OP_IMM)),  # imm[11:5]=0100000
    ("SLTI", encode_i(0x010, 1, 0b010, 3, OPC_OP_IMM)),
    ("LW", encode_i(0x008, 1, 0b010, 3, OPC_LOAD)),
    ("LH", encode_i(0x002, 1, 0b001, 3, OPC_LOAD)),
    ("LB", encode_i(0x000, 1, 0b000, 3, OPC_LOAD)),
    ("JALR", encode_i(0x000, 1, 0b000, 3, OPC_JALR)),
)

OTHER_CASES: Sequence[tuple[str, int]] = (
    ("SW", encode_s(0x00C, 2, 1, 0b010, OPC_STORE)),
    ("SH", encode_s(0x002, 2, 1, 0b001, OPC_STORE)),
    ("BEQ", encode_b(0x008, 2, 1, 0b000)),
    ("BNE", encode_b(0x008, 2, 1, 0b001)),
    ("BLT", encode_b(0x010, 2, 1, 0b100)),
    ("LUI", encode_u(0x12345, 5, OPC_LUI)),
    ("AUIPC", encode_u(0x10000, 5, OPC_AUIPC)),
    ("JAL", encode_j(0x100, 1)),
    ("FENCE", encode_i(0x0, 0, 0b000, 0, OPC_MISC)),
    ("ECALL", encode_i(0x0, 0, 0b000, 0, OPC_SYSTEM)),
)

ILLEGAL_CASES: Sequence[tuple[str, int]] = (
    ("COMPRESSED_C0", 0x0000_0000),  # inst[1:0]=00
    ("COMPRESSED_C1", 0x0000_0001),  # inst[1:0]=01
    ("COMPRESSED_C2", 0x0000_0002),  # inst[1:0]=10
    ("BAD_OPCODE", 0x0000_001F),  # opcode 0011111, still 32-bit aligned
    ("BAD_R_FUNCT7", encode_r(0b1010101, 2, 1, 0b000, 3, OPC_OP)),
)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
@cocotb.test(name="control_rtype_decode")
@cocotb.parametrize(
    name_inst=[(n, i) for n, i in RTYPE_CASES],
    phase=list(PHASES),
)
async def test_rtype_decode(dut, name_inst: tuple[str, int], phase: Phase) -> None:
    """R-type mock opcodes: inspect reg_write / alu_op / mem_write in ctrl_out."""
    name, inst = name_inst
    ctrl = await check_vector(dut, inst, phase)
    if not ctrl.illegal:
        assert ctrl.mem_write == 0, f"{name}: R-type must not assert mem_write"
        if ((inst >> 25) & 0x7F) != 0b0000001:
            # Base integer R-type always writes a register.
            assert ctrl.reg_write == 1, f"{name}: expected reg_write"


@cocotb.test(name="control_itype_decode")
@cocotb.parametrize(
    name_inst=[(n, i) for n, i in ITYPE_CASES],
    phase=list(PHASES),
)
async def test_itype_decode(dut, name_inst: tuple[str, int], phase: Phase) -> None:
    """I-type mock opcodes (OP-IMM / LOAD / JALR): analyze ctrl_out enables."""
    name, inst = name_inst
    ctrl = await check_vector(dut, inst, phase)
    opcode = inst & 0x7F
    if opcode == OPC_OP_IMM:
        assert ctrl.reg_write == 1 and ctrl.alu_src_imm == 1, f"{name}: OP-IMM enables"
        assert ctrl.mem_write == 0 and ctrl.mem_read == 0
    elif opcode == OPC_LOAD:
        assert ctrl.reg_write == 1 and ctrl.mem_read == 1 and ctrl.alu_src_imm == 1
        assert ctrl.mem_write == 0


@cocotb.test(name="control_other_primary_modes")
@cocotb.parametrize(
    name_inst=[(n, i) for n, i in OTHER_CASES],
    phase=list(PHASES),
)
async def test_other_primary_modes(dut, name_inst: tuple[str, int], phase: Phase) -> None:
    """STORE / BRANCH / U-type / JAL / SYSTEM primary decode modes."""
    _name, inst = name_inst
    await check_vector(dut, inst, phase)


@cocotb.test(name="control_stall_phase_rules")
async def test_stall_phase_rules(dut) -> None:
    """Stall must match ISA phase rules for load / store / M-extension."""
    lw = encode_i(0x0, 1, 0b010, 2, OPC_LOAD)
    sw = encode_s(0x0, 2, 1, 0b010, OPC_STORE)
    mul = encode_r(0b0000001, 2, 1, 0b000, 3, OPC_OP)
    add = encode_r(0b0000000, 2, 1, 0b000, 3, OPC_OP)
    addi = encode_i(1, 1, 0b000, 2, OPC_OP_IMM)

    # LOAD / STORE: stall only in MEM
    for phase in PHASES:
        ctrl = await check_vector(dut, lw, phase)
        assert ctrl.stall == int(phase == Phase.MEM), f"LW stall @ {phase}"
        ctrl = await check_vector(dut, sw, phase)
        assert ctrl.stall == int(phase == Phase.MEM), f"SW stall @ {phase}"

    # M-extension: stall only in EX
    for phase in PHASES:
        ctrl = await check_vector(dut, mul, phase)
        assert ctrl.stall == int(phase == Phase.EX), f"MUL stall @ {phase}"

    # Single-cycle ALU never stalls
    for phase in PHASES:
        assert (await check_vector(dut, add, phase)).stall == 0
        assert (await check_vector(dut, addi, phase)).stall == 0

    # DEC / WB never stall even for multi-cycle classes (re-check explicit)
    for inst in (lw, sw, mul):
        assert (await check_vector(dut, inst, Phase.DEC)).stall == 0
        assert (await check_vector(dut, inst, Phase.WB)).stall == 0


@cocotb.test(name="control_illegal_and_enable_vectors")
async def test_illegal_and_enable_vectors(dut) -> None:
    """Illegal encodings + sweep enable-state vectors across legal classes."""
    for name, inst in ILLEGAL_CASES:
        for phase in PHASES:
            ctrl = await check_vector(dut, inst, phase)
            assert ctrl.illegal == 1, f"{name} must be illegal"
            assert ctrl.stall == 0
            assert ctrl.enable_vector == 0, f"{name}: enables must clear"

    # Directed legal vectors chosen to hit distinct enable combinations.
    enable_targets: Iterable[tuple[str, int, int]] = (
        ("ADD", encode_r(0b0000000, 2, 1, 0b000, 3, OPC_OP), 0b001),  # reg_write
        ("SW", encode_s(0x0, 2, 1, 0b010, OPC_STORE), 0b010),  # mem_write
        ("LW", encode_i(0x0, 1, 0b010, 2, OPC_LOAD), 0b101),  # mem_read|reg_write
        ("BEQ", encode_b(0x8, 2, 1, 0b000), 0b000),  # none
        ("ECALL", encode_i(0x0, 0, 0b000, 0, OPC_SYSTEM), 0b000),
    )
    for name, inst, en in enable_targets:
        ctrl = await check_vector(dut, inst, Phase.EX)
        assert ctrl.enable_vector == en, f"{name}: enable_vector={ctrl.enable_vector:#03b}"


@cocotb.test(name="control_export_coverage")
async def test_export_coverage(dut) -> None:
    """Final gate: write exactly one coverage.xml for CI."""
    del dut
    _export_coverage()
    assert os.path.isfile("coverage.xml"), "coverage.xml was not written"
