// RV32IMC control unit — black-box decode for independent cocotb verification.
// Protocol ports: inst, phase -> ctrl_out (combinational).
// See docs/core_unit_interfaces.md for the ctrl_out bit map and stall rules.
module control (
    // rd/rs1/rs2 in inst[31:7] are intentionally unused by this decoder.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] inst,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [1:0]  phase,
    output logic [11:0] ctrl_out
);

  // Instruction phases
  localparam logic [1:0] PHASE_DEC = 2'd0;
  localparam logic [1:0] PHASE_EX  = 2'd1;
  localparam logic [1:0] PHASE_MEM = 2'd2;
  localparam logic [1:0] PHASE_WB  = 2'd3;

  // ALU op encoding (matches rtl/core/alu.sv)
  localparam logic [3:0] ALU_ADD = 4'h0;
  localparam logic [3:0] ALU_SUB = 4'h1;
  localparam logic [3:0] ALU_AND = 4'h2;
  localparam logic [3:0] ALU_OR  = 4'h3;
  localparam logic [3:0] ALU_XOR = 4'h4;
  localparam logic [3:0] ALU_SLL = 4'h5;
  localparam logic [3:0] ALU_SRL = 4'h6;
  localparam logic [3:0] ALU_SRA = 4'h7;

  // Major opcodes
  localparam logic [6:0] OPC_LOAD    = 7'b0000011;
  localparam logic [6:0] OPC_MISC    = 7'b0001111;
  localparam logic [6:0] OPC_OP_IMM  = 7'b0010011;
  localparam logic [6:0] OPC_AUIPC   = 7'b0010111;
  localparam logic [6:0] OPC_STORE   = 7'b0100011;
  localparam logic [6:0] OPC_OP      = 7'b0110011;
  localparam logic [6:0] OPC_LUI     = 7'b0110111;
  localparam logic [6:0] OPC_BRANCH  = 7'b1100011;
  localparam logic [6:0] OPC_JALR    = 7'b1100111;
  localparam logic [6:0] OPC_JAL     = 7'b1101111;
  localparam logic [6:0] OPC_SYSTEM  = 7'b1110011;

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;
  logic       is_compressed;
  logic       is_m_op;

  logic       reg_write;
  logic       mem_write;
  logic       mem_read;
  logic [3:0] alu_op;
  logic       alu_src_imm;
  logic       branch;
  logic       jump;
  logic       stall;
  logic       illegal;

  assign opcode        = inst[6:0];
  assign funct3        = inst[14:12];
  assign funct7        = inst[31:25];
  assign is_compressed = (inst[1:0] != 2'b11);
  assign is_m_op       = (opcode == OPC_OP) && (funct7 == 7'b0000001);

  // Decode ALU op for OP / OP-IMM base integer encodings.
  function automatic logic [3:0] decode_alu_op(
      input logic [2:0] f3,
      input logic [6:0] f7,
      input logic       is_imm
  );
    begin
      unique case (f3)
        3'b000: begin
          if (!is_imm && f7 == 7'b0100000)
            decode_alu_op = ALU_SUB;
          else
            decode_alu_op = ALU_ADD;
        end
        3'b001: decode_alu_op = ALU_SLL;
        3'b100: decode_alu_op = ALU_XOR;
        3'b101: begin
          if (f7 == 7'b0100000)
            decode_alu_op = ALU_SRA;
          else
            decode_alu_op = ALU_SRL;
        end
        3'b110: decode_alu_op = ALU_OR;
        3'b111: decode_alu_op = ALU_AND;
        // SLT / SLTU: compare path uses ADD as the unit-level placeholder.
        default: decode_alu_op = ALU_ADD;
      endcase
    end
  endfunction

  always_comb begin
    reg_write   = 1'b0;
    mem_write   = 1'b0;
    mem_read    = 1'b0;
    alu_op      = ALU_ADD;
    alu_src_imm = 1'b0;
    branch      = 1'b0;
    jump        = 1'b0;
    stall       = 1'b0;
    illegal     = 1'b0;

    if (is_compressed) begin
      illegal = 1'b1;
    end else begin
      unique case (opcode)
        OPC_OP: begin
          reg_write = 1'b1;
          if (is_m_op) begin
            alu_op = ALU_ADD;
            stall  = (phase == PHASE_EX);
          end else if (funct7 == 7'b0000000 || funct7 == 7'b0100000) begin
            alu_op = decode_alu_op(funct3, funct7, 1'b0);
          end else begin
            illegal   = 1'b1;
            reg_write = 1'b0;
          end
        end

        OPC_OP_IMM: begin
          reg_write   = 1'b1;
          alu_src_imm = 1'b1;
          // Shift immediates reuse funct7-style encoding in imm[11:5].
          alu_op = decode_alu_op(funct3, funct7, 1'b1);
        end

        OPC_LOAD: begin
          reg_write   = 1'b1;
          mem_read    = 1'b1;
          alu_src_imm = 1'b1;
          alu_op      = ALU_ADD;
          stall       = (phase == PHASE_MEM);
        end

        OPC_STORE: begin
          mem_write   = 1'b1;
          alu_src_imm = 1'b1;
          alu_op      = ALU_ADD;
          stall       = (phase == PHASE_MEM);
        end

        OPC_BRANCH: begin
          branch = 1'b1;
          // EQ/NE compare via SUB; remaining branch compares use ADD path.
          if (funct3 == 3'b000 || funct3 == 3'b001)
            alu_op = ALU_SUB;
          else
            alu_op = ALU_ADD;
        end

        OPC_LUI: begin
          reg_write   = 1'b1;
          alu_src_imm = 1'b1;
          alu_op      = ALU_ADD;
        end

        OPC_AUIPC: begin
          reg_write   = 1'b1;
          alu_src_imm = 1'b1;
          alu_op      = ALU_ADD;
        end

        OPC_JAL: begin
          reg_write = 1'b1;
          jump      = 1'b1;
          alu_op    = ALU_ADD;
        end

        OPC_JALR: begin
          reg_write   = 1'b1;
          jump        = 1'b1;
          alu_src_imm = 1'b1;
          alu_op      = ALU_ADD;
        end

        OPC_MISC, OPC_SYSTEM: begin
          // Recognized but no datapath enables at this unit boundary.
        end

        default: begin
          illegal = 1'b1;
        end
      endcase
    end

    // DEC/WB never stall; illegal encodings never assert stall.
    if (illegal || phase == PHASE_DEC || phase == PHASE_WB)
      stall = 1'b0;

    ctrl_out = {illegal, stall, jump, branch, alu_src_imm, alu_op,
                mem_read, mem_write, reg_write};
  end

endmodule
