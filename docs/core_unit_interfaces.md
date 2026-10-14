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
