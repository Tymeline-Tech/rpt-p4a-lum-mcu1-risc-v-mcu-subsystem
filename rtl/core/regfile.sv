// RV32IMC integer register file — black-box unit under independent cocotb.
// Dual combinational read ports, single synchronous write; x0 hard-wired to 0.
// See docs/core_unit_interfaces.md for the protocol contract.
module regfile (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        we,
    input  logic [4:0]  waddr,
    input  logic [31:0] wdata,
    input  logic [4:0]  raddr1,
    input  logic [4:0]  raddr2,
    output logic [31:0] rdata1,
    output logic [31:0] rdata2
);

  // Full 32-entry array; slot 0 is never written and always reads as zero.
  logic [31:0] regs [0:31];

  integer i;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (i = 0; i < 32; i = i + 1) begin
        regs[i] <= 32'h0;
      end
    end else if (we && (waddr != 5'd0)) begin
      regs[waddr] <= wdata;
    end
  end

  // Combinational read; address 0 always returns zero regardless of storage.
  assign rdata1 = (raddr1 == 5'd0) ? 32'h0 : regs[raddr1];
  assign rdata2 = (raddr2 == 5'd0) ? 32'h0 : regs[raddr2];

endmodule
