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
