# RV32IMC Core Unit Black-Box Interfaces

Independent verification targets only these protocol ports. Internal RTL
structure is out of scope for unit-level cocotb suites.

## ALU (`rtl/core/alu.sv`)

| Port      | Dir | Width | Description                                      |
|-----------|-----|-------|--------------------------------------------------|
| `in1`     | in  | 32    | Operand A (`op_a`)                               |
| `in2`     | in  | 32    | Operand B (`op_b_ialu`)                          |
| `control` | in  | 4     | ALU operation select                             |
| `alu_out` | out | 32    | Combinational result                             |

### `control` encoding

| Code | Mnemonic | Operation                                      |
|------|----------|------------------------------------------------|
| 0x0  | ADD      | `in1 + in2` (wrap 32-bit)                      |
| 0x1  | SUB      | `in1 - in2` (wrap 32-bit)                      |
| 0x2  | AND      | `in1 & in2`                                    |
| 0x3  | OR       | `in1 \| in2`                                   |
| 0x4  | XOR      | `in1 ^ in2`                                    |
| 0x5  | SLL      | `in1 << in2[4:0]`                              |
| 0x6  | SRL      | `in1 >> in2[4:0]` (logical)                    |
| 0x7  | SRA      | `$signed(in1) >>> in2[4:0]` (arithmetic)       |

Unused `control` encodings drive `alu_out` to 0.

## Register File (`rtl/core/regfile.sv`)

RV32 integer register file: 32 × 32-bit registers with dual combinational
read ports and one synchronous write port. `x0` is hard-wired to zero.

| Port     | Dir | Width | Description                                         |
|----------|-----|-------|-----------------------------------------------------|
| `clk`    | in  | 1     | Rising-edge clock for writes                        |
| `rst_n`  | in  | 1     | Active-low synchronous reset (clears all registers) |
| `we`     | in  | 1     | Write enable (sampled on rising `clk`)              |
| `waddr`  | in  | 5     | Write address (`rd`, `0`–`31`)                      |
| `wdata`  | in  | 32    | Write data                                          |
| `raddr1` | in  | 5     | Read-port 1 address (`rs1`)                         |
| `raddr2` | in  | 5     | Read-port 2 address (`rs2`)                         |
| `rdata1` | out | 32    | Read-port 1 data (combinational)                    |
| `rdata2` | out | 32    | Read-port 2 data (combinational)                    |

### Behavioral contract

1. **Synchronous write:** On rising `clk`, if `we` is asserted and `waddr != 0`,
   store `wdata` into that register. Writes with `waddr == 0` are ignored.
2. **`x0` hard-wired:** Reading address `0` always returns `32'h0` on either
   read port, including while a write to `x0` (or any other address) is active.
3. **Combinational read:** `rdata1` / `rdata2` reflect stored values in the same
   cycle the corresponding `raddr*` is driven (no extra latency). New written
   data is visible on the read ports **after** the rising edge that commits
   the write (classic sync-write / async-read boundary).
4. **Reset:** While `rst_n` is low on a rising `clk`, all architectural
   registers clear to `0` (so `x1`–`x31` read as zero after reset release).
5. **Retention:** Registers not targeted by a successful write keep their
   previous value across subsequent cycles.

## Control Unit (`rtl/core/control.sv`)

Combinational instruction decoder for the RV32IMC integer/control path.
Drives a packed `ctrl_out` bundle from the instruction word and the current
multi-cycle instruction phase. Unit tests exercise opcode fields
(`inst[6:0]`, `inst[31:7]`) only through this black-box port list.

| Port       | Dir | Width | Description                                              |
|------------|-----|-------|----------------------------------------------------------|
| `inst`     | in  | 32    | Full instruction word (`opcode`=`inst[6:0]`, rest=`[31:7]`) |
| `phase`    | in  | 2     | Instruction phase: `DEC=0`, `EX=1`, `MEM=2`, `WB=3`      |
| `ctrl_out` | out | 12    | Packed control enables / ALU op / stall / illegal        |

### `ctrl_out` bit map

| Bits  | Name         | Meaning                                              |
|-------|--------------|------------------------------------------------------|
| `[0]` | `reg_write`  | Register-file write enable                           |
| `[1]` | `mem_write`  | Data-memory write enable                             |
| `[2]` | `mem_read`   | Data-memory read enable                              |
| `[6:3]` | `alu_op`   | ALU operation select (same encoding as ALU `control`) |
| `[7]` | `alu_src_imm`| ALU operand B comes from the immediate               |
| `[8]` | `branch`     | Conditional branch instruction                       |
| `[9]` | `jump`       | Unconditional jump (`JAL`/`JALR`)                    |
| `[10]`| `stall`      | Stall request for the current `phase`                |
| `[11]`| `illegal`    | Unsupported / illegal encoding                       |

### Decode contract (primary modes)

1. **R-type (`OP`, opcode `0110011`):** `reg_write=1`, `alu_src_imm=0`.
   `funct7`/`funct3` select `alu_op` for base integer ops; M-extension
   (`funct7=0000001`) keeps `alu_op=ADD` and is multi-cycle (see stall).
2. **I-type ALU (`OP-IMM`, opcode `0010011`):** `reg_write=1`,
   `alu_src_imm=1`; `funct3` (and `imm[11:5]` for shifts) select `alu_op`.
3. **LOAD (`0000011`):** `reg_write=1`, `mem_read=1`, `alu_src_imm=1`,
   `alu_op=ADD` (address = `rs1 + imm`).
4. **STORE (`0100011`):** `mem_write=1`, `alu_src_imm=1`, `alu_op=ADD`.
5. **BRANCH (`1100011`):** `branch=1`, `alu_op` from `funct3` compare family
   (EQ/NE use `SUB`; LT/GE use `ADD` as placeholder compare path).
6. **LUI / AUIPC / JAL / JALR:** `reg_write=1`; jumps also set `jump=1`.
7. **Illegal:** unrecognized opcode (incl. compressed `inst[1:0]!=2'b11`
   when presented on this 32-bit port) sets `illegal=1` and clears enables.

### Stall rules (ISA phase expectations)

| Instruction class              | Stall when                         |
|--------------------------------|------------------------------------|
| LOAD                           | `phase == MEM`                     |
| STORE                          | `phase == MEM`                     |
| M-extension R-type (MUL/DIV/…) | `phase == EX`                      |
| All other legal ops            | never (`stall=0`)                  |
| Illegal                        | never (trap path; `stall=0`)       |

`DEC` and `WB` phases never assert `stall` for legal instructions.
