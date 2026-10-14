// Minimal synthesizable smoke module for toolchain / lint pipeline validation.
// Intentionally tiny: proves Verilator lint and later sim/synth entry points
// can process real SystemVerilog from a clean tree.
module smoke (
    input  logic clk,
    input  logic rst_n,
    input  logic d,
    output logic q
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q <= 1'b0;
    end else begin
      q <= d;
    end
  end
endmodule
