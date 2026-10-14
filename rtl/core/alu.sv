// RV32IMC integer ALU — black-box unit under independent cocotb verification.
// Protocol ports only: in1, in2, control -> alu_out (combinational).
// See docs/core_unit_interfaces.md for the control encoding contract.
module alu (
    input  logic [31:0] in1,
    input  logic [31:0] in2,
    input  logic [3:0]  control,
    output logic [31:0] alu_out
);

  localparam logic [3:0] ALU_ADD = 4'h0;
  localparam logic [3:0] ALU_SUB = 4'h1;
  localparam logic [3:0] ALU_AND = 4'h2;
  localparam logic [3:0] ALU_OR  = 4'h3;
  localparam logic [3:0] ALU_XOR = 4'h4;
  localparam logic [3:0] ALU_SLL = 4'h5;
  localparam logic [3:0] ALU_SRL = 4'h6;
  localparam logic [3:0] ALU_SRA = 4'h7;

  logic [4:0] shamt;
  assign shamt = in2[4:0];

  always_comb begin
    case (control)
      ALU_ADD: alu_out = in1 + in2;
      ALU_SUB: alu_out = in1 - in2;
      ALU_AND: alu_out = in1 & in2;
      ALU_OR:  alu_out = in1 | in2;
      ALU_XOR: alu_out = in1 ^ in2;
      ALU_SLL: alu_out = in1 << shamt;
      ALU_SRL: alu_out = in1 >> shamt;
      ALU_SRA: alu_out = $unsigned($signed(in1) >>> shamt);
      default: alu_out = 32'h0;
    endcase
  end

endmodule
